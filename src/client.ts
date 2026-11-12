// 调用 napboxd 本地 socket 的客户端，协议见 DESIGN.md 第 4、9 节。
//
// 约定（测试在 test/client.test.ts、test/vm.test.ts）：
// - 每次调用一个连接。一个连接上的请求是排队处理的，up 可能要很久，不能共用。
// - 失败一律抛 NapboxError，code 是 napboxd 给的原样错误码。客户端自己只产生两种：
//   - daemon_unavailable：连不上，或者还没拿到最后结果连接就断了。napboxd 没运行时不会替它启动，它由登录项负责。
//     中途断开时这次操作不一定没做，要用 status 或 environment 查当前状态。
//   - protocol_error：回应看不懂（不是 JSON、字段或取值对不上），一般是客户端和 napboxd 版本差太多。
//     不比较版本号：多出来的字段不管，旧 napboxd 没有的方法它自己报 unknown_method。
// - 不设超时：up 可能在拉镜像，napboxd 自己有 healthcheck 的等待上限。logs、exec、run、subscribe 可以用 signal 取消，
//   取消后 Promise 以 signal.reason 拒绝。其余方法不收 signal：断开连接并不会停下 napboxd 里正在做的事。
// - 回调返回 Promise 时等它完成才读下一条；回调抛错时结束这次调用，Promise 以那个错误拒绝。
import { homedir } from "node:os";
import path from "node:path";
import { createConnection, type Socket } from "node:net";
import type { z } from "zod";
import {
  CreateParams,
  DownResult,
  EmptyResult,
  EnvironmentInfo,
  type EgressMode,
  type EnvironmentEvent,
  type EnvironmentTarget,
  type ErrorCode,
  ExecResult,
  ImageImportResult,
  LogsResult,
  methods,
  type OutputStream,
  Response,
  RunsResult,
  StatusResult,
  type SubscribeParams,
  type RunParams,
  type UpParams,
} from "./protocol.ts";

export class NapboxError extends Error {
  override name = "NapboxError";
  readonly code: ErrorCode | (string & {});

  constructor(code: string, message: string) {
    super(message);
    this.code = code;
  }
}

/** 和 napboxd 的 Paths.supportDirectory 一样：设了 NAPBOX_SUPPORT_DIR 时用它 */
export function supportDirectory(): string {
  return (
    process.env.NAPBOX_SUPPORT_DIR || path.join(homedir(), "Library/Application Support/napbox")
  );
}

export function defaultSocketPath(): string {
  return path.join(supportDirectory(), "napboxd.sock");
}

export interface Output {
  stream: OutputStream;
  /** 原样的字节，可能在多字节字符或一行的中间切开 */
  data: Uint8Array;
}

type OnOutput = (output: Output) => void | Promise<void>;

/** create 里 files、profiles、environment 不写或传 undefined 时是空的。compose 变量要显式给，不会读本进程的环境变量 */
export type CreateOptions = Pick<CreateParams, "name" | "owner" | "directory" | "egress"> &
  Partial<Pick<CreateParams, "files" | "profiles" | "environment">>;

/** up 的 environment 必须给：compose 变量替换用哪些变量由调用方决定（命令行给的是它自己的环境变量） */
export type UpOptions = Pick<UpParams, "cwd" | "environment"> &
  Partial<Pick<UpParams, "files" | "profiles" | "build" | "temp">>;

/** 起一个临时环境，在前台跑其中一个服务，跑完销毁。command 不写就用 compose 里写的 */
export type RunOptions = Pick<RunParams, "cwd" | "environment" | "service"> &
  Partial<Pick<RunParams, "files" | "profiles" | "build" | "egress" | "command" | "noDeps">> & {
    /** 给服务的标准输入，不写时它一读就是结束 */
    stdin?: ExecOptions["stdin"];
    onOutput: OnOutput;
    /** 取消时服务停掉，临时环境照样销毁 */
    signal?: AbortSignal;
  };

export interface LogsOptions {
  target: EnvironmentTarget;
  service: string;
  /** 最后几行，不写是全部（命令行的默认 200 行是命令行自己的） */
  tail?: number;
  /** 输出完继续跟着。环境回收时结果带 ended；napboxd 退出时抛 daemon_unavailable */
  follow?: boolean;
  onOutput: OnOutput;
  signal?: AbortSignal;
}

export interface ExecOptions {
  target: EnvironmentTarget;
  service: string;
  command: string[];
  /** 给命令的标准输入，不写时命令一读就是结束。内容给完才告诉命令输入结束 */
  stdin?: string | Uint8Array | AsyncIterable<Uint8Array | string>;
  onOutput: OnOutput;
  /** 取消时结束容器里的这条命令和它的子进程；自己用 setsid 脱离的进程等环境停止时才结束 */
  signal?: AbortSignal;
}

export interface SubscribeOptions extends SubscribeParams {
  /** 订阅生效了，从这以后的事件都会送到。在这里查 status、runs，中间不会漏（DESIGN.md 第 9 节） */
  onSubscribed?: () => void | Promise<void>;
  onEvent: (event: EnvironmentEvent) => void | Promise<void>;
  /** 不再订阅时用它取消 */
  signal?: AbortSignal;
}

interface Exchange<S extends z.ZodType> {
  method: string;
  params?: unknown;
  result: S;
  onOutput?: OnOutput;
  onSubscribed?: () => void | Promise<void>;
  onEvent?: (event: EnvironmentEvent) => void | Promise<void>;
  /** 发完请求后同时跑：exec、run 用它发标准输入。write 返回 false 表示连接已经没了 */
  afterRequest?: (write: (message: unknown) => Promise<boolean>) => Promise<void>;
  signal?: AbortSignal;
}

const REQUEST_ID = 1;

export class NapboxClient {
  readonly socketPath: string;

  constructor(options: { socketPath?: string } = {}) {
    this.socketPath = options.socketPath ?? defaultSocketPath();
  }

  status(): Promise<StatusResult> {
    return this.exchange({ method: methods.status, result: StatusResult });
  }

  up(options: UpOptions): Promise<EnvironmentInfo> {
    const { cwd, environment, files = [], profiles = [], build = false, temp } = options;
    const params: UpParams = { cwd, files, profiles, environment, build, temp };
    return this.exchange({ method: methods.up, params, result: EnvironmentInfo });
  }

  /** 结果里的 exitCode 是前台那个服务的退出码；它失败不算出错，不抛。环境起不来才抛 */
  run(options: RunOptions): Promise<ExecResult> {
    const { cwd, environment, service, files = [], profiles = [], build = false, egress } = options;
    const { command = [], noDeps = false, stdin, onOutput, signal } = options;
    const params: RunParams = { cwd, files, profiles, environment, build, egress, service, command, noDeps };
    return this.exchange({
      method: methods.run,
      params,
      result: ExecResult,
      onOutput,
      afterRequest: (write) => sendStdin(stdin, write),
      signal,
    });
  }

  create(options: CreateOptions): Promise<EnvironmentInfo> {
    const { name, owner, directory, files = [], profiles = [], environment = {}, egress } = options;
    const params: CreateParams = { name, owner, directory, files, profiles, environment, egress };
    return this.exchange({ method: methods.create, params, result: EnvironmentInfo });
  }

  /** 环境当前的信息，不唤醒 */
  environment(target: EnvironmentTarget): Promise<EnvironmentInfo> {
    return this.exchange({
      method: methods.environment,
      params: { target },
      result: EnvironmentInfo,
    });
  }

  wake(target: EnvironmentTarget): Promise<EnvironmentInfo> {
    return this.exchange({ method: methods.wake, params: { target }, result: EnvironmentInfo });
  }

  sleep(target: EnvironmentTarget): Promise<EnvironmentInfo> {
    return this.exchange({ method: methods.sleep, params: { target }, result: EnvironmentInfo });
  }

  down(target: EnvironmentTarget): Promise<DownResult> {
    return this.exchange({ method: methods.down, params: { target }, result: DownResult });
  }

  runs(target: EnvironmentTarget): Promise<RunsResult> {
    return this.exchange({ method: methods.runs, params: { target }, result: RunsResult });
  }

  egress(target: EnvironmentTarget, mode: EgressMode): Promise<EnvironmentInfo> {
    return this.exchange({
      method: methods.egress,
      params: { target, mode },
      result: EnvironmentInfo,
    });
  }

  reset(target: EnvironmentTarget, volume: string): Promise<EnvironmentInfo> {
    return this.exchange({
      method: methods.reset,
      params: { target, volume },
      result: EnvironmentInfo,
    });
  }

  importImage(reference: string): Promise<ImageImportResult> {
    return this.exchange({
      method: methods.imageImport,
      params: { reference },
      result: ImageImportResult,
    });
  }

  logs(options: LogsOptions): Promise<LogsResult> {
    const { target, service, tail, follow = false, onOutput, signal } = options;
    return this.exchange({
      method: methods.logs,
      params: { target, service, tail, follow },
      result: LogsResult,
      onOutput,
      signal,
    });
  }

  /** 结果里的 exitCode 和命令的退出码一样；命令失败不算出错，不抛 */
  exec(options: ExecOptions): Promise<ExecResult> {
    const { target, service, command, stdin, onOutput, signal } = options;
    return this.exchange({
      method: methods.exec,
      params: { target, service, command },
      result: ExecResult,
      onOutput,
      afterRequest: (write) => sendStdin(stdin, write),
      signal,
    });
  }

  /**
   * 一直收事件，直到 signal 取消（以 signal.reason 拒绝）或 napboxd 退出（抛 daemon_unavailable）。
   * 不存盘、不补发：断开后重新订阅，在 onSubscribed 里用 status 和 runs 补齐。
   */
  async subscribe(options: SubscribeOptions): Promise<void> {
    const { owner, names, onSubscribed, onEvent, signal } = options;
    await this.exchange({
      method: methods.subscribe,
      params: { owner, names },
      result: EmptyResult,
      onSubscribed,
      onEvent,
      signal,
    });
  }

  private async exchange<S extends z.ZodType>(call: Exchange<S>): Promise<z.output<S>> {
    const { signal } = call;
    signal?.throwIfAborted();
    const socket = await connect(this.socketPath);
    const abort = () => socket.destroy();
    signal?.addEventListener("abort", abort);
    let inputFailure: { error: unknown } | undefined;
    try {
      signal?.throwIfAborted();
      const replies = readLines(socket, this.socketPath);
      const write = (message: unknown) =>
        new Promise<boolean>((resolve) => {
          socket.write(`${JSON.stringify(message)}\n`, (error) => resolve(!error));
        });
      void write({ id: REQUEST_ID, method: call.method, params: call.params });
      void call.afterRequest?.(write).catch((error: unknown) => {
        inputFailure = { error };
        socket.destroy();
      });
      for await (const line of replies) {
        const reply = parseReply(line);
        if (reply.error) throw new NapboxError(reply.error.code, reply.error.message);
        if (reply.result !== undefined) return checked(call.result, reply.result);
        if (reply.output && call.onOutput) {
          const data = Buffer.from(reply.output.data, "base64");
          await call.onOutput({ stream: reply.output.stream, data });
        } else if (reply.event && call.onEvent) {
          await call.onEvent(reply.event);
        } else if (reply.subscribed && call.onEvent) {
          await call.onSubscribed?.();
        } else {
          throw new NapboxError("protocol_error", `${call.method} 收到看不懂的回应：${line}`);
        }
      }
      throw new NapboxError(
        "daemon_unavailable",
        `napboxd 没给最后的结果就断开了（${this.socketPath}），这次操作不一定没做，用 status 查当前状态`,
      );
    } catch (error) {
      // abort 是自己断开的，读到的断开不算 napboxd 的问题；标准输入出错同理
      signal?.throwIfAborted();
      if (inputFailure) throw inputFailure.error;
      throw error;
    } finally {
      signal?.removeEventListener("abort", abort);
      socket.destroy();
    }
  }
}

function connect(socketPath: string): Promise<Socket> {
  return new Promise((resolve, reject) => {
    const socket = createConnection(socketPath);
    socket.once("error", (error) => {
      reject(
        new NapboxError(
          "daemon_unavailable",
          `连不上 napboxd（${socketPath}：${error.message}）。客户端不会启动它，它由 napbox setup 注册的登录项运行。`,
        ),
      );
    });
    socket.once("connect", () => {
      socket.removeAllListeners("error");
      // 之后的错误由 readLines 读到；留一个监听，免得没有人在读的时候未处理的 error 事件带崩进程
      socket.on("error", () => {});
      resolve(socket);
    });
  });
}

/** 按行读。napboxd 突然断开（比如 ECONNRESET）和读到结尾一样处理：没有下一行了，由调用的地方报 */
async function* readLines(socket: Socket, socketPath: string): AsyncGenerator<string> {
  socket.setEncoding("utf8"); // 多字节字符切在两块数据之间时由它拼好
  let buffer = "";
  try {
    for await (const chunk of socket) {
      buffer += chunk as string;
      let end = buffer.indexOf("\n");
      while (end >= 0) {
        yield buffer.slice(0, end);
        buffer = buffer.slice(end + 1);
        end = buffer.indexOf("\n");
      }
    }
  } catch (error) {
    throw new NapboxError(
      "daemon_unavailable",
      `和 napboxd 的连接断了（${socketPath}：${(error as Error).message}），这次操作不一定没做，用 status 查当前状态`,
    );
  }
}

function parseReply(line: string): Response {
  let value: unknown;
  try {
    value = JSON.parse(line);
  } catch {
    throw new NapboxError("protocol_error", `napboxd 的回应不是 JSON：${line}`);
  }
  const reply = checked(Response, value);
  // id 0 是 napboxd 解析不了请求时的回应（Daemon.respond）
  if (reply.id !== REQUEST_ID && !(reply.id === 0 && reply.error)) {
    throw new NapboxError("protocol_error", `napboxd 回应的 id 是 ${reply.id}，请求的是 ${REQUEST_ID}`);
  }
  return reply;
}

function checked<S extends z.ZodType>(schema: S, value: unknown): z.output<S> {
  const parsed = schema.safeParse(value);
  if (parsed.success) return parsed.data;
  throw new NapboxError(
    "protocol_error",
    `napboxd 的回应对不上，可能是客户端和 napboxd 版本差太多：${parsed.error.message}`,
  );
}

async function sendStdin(
  stdin: ExecOptions["stdin"],
  write: (message: unknown) => Promise<boolean>,
): Promise<void> {
  const chunks = stdin === undefined ? [] : isSingleChunk(stdin) ? [stdin] : stdin;
  for await (const chunk of chunks) {
    const data = Buffer.from(chunk as Uint8Array).toString("base64");
    if (!(await write({ data }))) return; // 命令已经结束了
  }
  await write({ end: true });
}

function isSingleChunk(stdin: NonNullable<ExecOptions["stdin"]>): stdin is string | Uint8Array {
  return typeof stdin === "string" || stdin instanceof Uint8Array;
}
