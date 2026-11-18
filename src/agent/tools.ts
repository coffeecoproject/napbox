// MCP 工具，和命令行一一对应。出错时的内容和命令行一样是 {"error": {"code", "message"}}。
import path from "node:path";
import { z } from "zod";
import type { NapboxClient, Output } from "../client.ts";
import { NapboxError } from "../client.ts";
import { EgressMode } from "../protocol.ts";
import { setup } from "./setup.ts";

/** 一次结果里每种输出最多留这么多字节（留最后的部分）：太长的结果 agent 也读不了，要全部内容就重定向到文件 */
const OUTPUT_LIMIT = 48 * 1024;
const DEFAULT_EXEC_SECONDS = 120;
/** run 的时间从起环境算起，第一次还要拉镜像、构建 */
const DEFAULT_RUN_SECONDS = 600;

export interface ToolContext {
  client: NapboxClient;
  /** 没传 directory 时用的目录：会话工作的地方 */
  sessionDirectory(): Promise<string>;
  signal: AbortSignal;
}

export interface ToolResult {
  value: unknown;
  isError: boolean;
}

interface Tool<S extends z.ZodObject = z.ZodObject> {
  name: string;
  title: string;
  description: string;
  input: S;
  annotations: { readOnlyHint: boolean; destructiveHint: boolean; idempotentHint: boolean };
  run(args: z.output<S>, context: ToolContext): Promise<unknown>;
}

const directory = z
  .string()
  .optional()
  .describe("在哪个目录操作（环境按所在 worktree 识别）。不写就是会话工作的目录；会话换了 worktree 时要写。");

/** 操作临时环境的工具共用；up 的说明另写（它是起，不是找） */
const temp = z
  .string()
  .optional()
  .describe("操作这个 worktree 里叫这个名字的临时环境（up 传 temp 起的）。不写是开发环境。");

const READ = { readOnlyHint: true, destructiveHint: false, idempotentHint: true };
const WRITE = { readOnlyHint: false, destructiveHint: false, idempotentHint: true };
const DESTROY = { readOnlyHint: false, destructiveHint: true, idempotentHint: false };

const define = <S extends z.ZodObject>(tool: Tool<S>) => tool as unknown as Tool;

async function target(args: { directory?: string; temp?: string }, context: ToolContext) {
  const base = await context.sessionDirectory();
  return { cwd: args.directory ? path.resolve(base, args.directory) : base, temp: args.temp };
}

/** compose 变量替换用 MCP 服务自己的环境变量，和命令行用它自己的一样 */
const processEnvironment = () =>
  Object.fromEntries(Object.entries(process.env).filter((entry): entry is [string, string] => entry[1] !== undefined));

const timeoutSeconds = (fallback: number, from: string) =>
  z.int().min(1).max(3600).optional().describe(`超时后结束命令，默认 ${fallback} 秒${from}`);

/** 只留最后 OUTPUT_LIMIT 字节 */
class TailBuffer {
  private kept: Buffer = Buffer.alloc(0);
  private total = 0;

  add(data: Uint8Array) {
    this.total += data.length;
    this.kept = Buffer.concat([this.kept, data]).subarray(-OUTPUT_LIMIT);
  }

  get text() {
    return this.kept.toString("utf8");
  }

  get droppedBytes() {
    return this.total - this.kept.length;
  }
}

/**
 * exec、run 共用：收下输出，超时不抛，返回 timedOut 和已经收到的输出。
 * - seconds：给了就到时间取消（run，从起环境算起）；不给是 start 自己把时限交给 napboxd（exec：它确认命令结束了才返回）
 */
async function capture(
  seconds: number | undefined,
  context: ToolContext,
  start: (onOutput: (output: Output) => void, signal: AbortSignal) => Promise<{ exitCode: number; timedOut?: true }>,
) {
  const stdout = new TailBuffer();
  const stderr = new TailBuffer();
  const timeout = seconds === undefined ? undefined : AbortSignal.timeout(seconds * 1000);
  const captured = () => ({
    stdout: stdout.text,
    stderr: stderr.text,
    droppedBytes: { stdout: stdout.droppedBytes, stderr: stderr.droppedBytes },
  });
  try {
    const { exitCode, timedOut } = await start(
      ({ stream, data }) => (stream === "stdout" ? stdout : stderr).add(data),
      timeout ? AbortSignal.any([context.signal, timeout]) : context.signal,
    );
    return { exitCode, ...(timedOut ? { timedOut } : {}), ...captured() };
  } catch (error) {
    if (!timeout?.aborted) throw error;
    return { timedOut: true, ...captured() };
  }
}

export const tools: readonly Tool[] = [
  define({
    name: "up",
    title: "启动环境",
    description:
      "用项目的 compose 文件启动当前 worktree 的开发环境（数据库、对象存储、后端等），不用 Docker，每个 worktree 一套，端口不冲突。等服务都就绪后返回端口和变量。同一个环境的端口固定不变（休眠、唤醒、再次 up、换 profile 都一样），down 之后才释放。已在运行时马上返回。第一次可能要拉镜像、构建镜像，比较慢。测试要一套用完就扔的服务（比如空的数据库）时传 temp，代替 docker run。",
    input: z.strictObject({
      directory,
      files: z.array(z.string()).optional().describe("compose 文件，按顺序合并。不写就自动查找。"),
      profiles: z.array(z.string()).optional().describe("启用的 profile"),
      build: z
        .boolean()
        .optional()
        .describe("写了 build 的服务都重新构建。不传时只在镜像还没有时构建；改了 Dockerfile 或打进镜像的文件后要传 true。"),
      temp: z
        .string()
        .optional()
        .describe(
          "起一个叫这个名字的临时环境，不动开发环境：有自己的端口和数据，可以同时起好几个。名字小写字母或数字开头，只用小写字母、数字和 . _ -，不超过 40 个字符。用完调 down 传同一个名字，数据直接删掉；它不休眠，闲置了自己销毁。",
        ),
    }),
    annotations: WRITE,
    async run(args, context) {
      return context.client.up({
        ...(await target(args, context)),
        files: args.files,
        profiles: args.profiles,
        environment: processEnvironment(),
        build: args.build,
      });
    },
  }),
  define({
    name: "run",
    title: "单独跑一次某个服务",
    description: `临时起一个环境，在前台跑 compose 里的一个服务（测试、检查、一次性脚本），跑完整个销毁，代替 docker compose run 和 docker run --rm。它依赖的服务先起好；和开发环境互不影响，数据不保留。stdout、stderr 各留最后 ${OUTPUT_LIMIT / 1024}KB；不支持交互。服务失败看 exitCode。`,
    input: z.strictObject({
      directory,
      service: z.string().describe("服务名"),
      command: z
        .array(z.string())
        .min(1)
        .optional()
        .describe('命令和参数，换掉服务的 command，比如 ["npm", "test"]；不写就用 compose 里写的'),
      files: z.array(z.string()).optional().describe("compose 文件，按顺序合并。不写就自动查找。"),
      profiles: z.array(z.string()).optional().describe("启用的 profile。要跑的服务自己的 profile 不用写。"),
      build: z.boolean().optional().describe("写了 build 的服务都重新构建。不传时只在镜像还没有时构建。"),
      noDeps: z.boolean().optional().describe("不起它 depends_on 的服务"),
      egress: EgressMode.optional().describe("出网模式，默认 open；none 是一起来就只能访问这个环境自己的服务"),
      stdin: z.string().optional().describe("给服务的标准输入"),
      timeoutSeconds: timeoutSeconds(DEFAULT_RUN_SECONDS, "，从起环境算起"),
    }),
    annotations: { readOnlyHint: false, destructiveHint: false, idempotentHint: false },
    async run(args, context) {
      const { cwd } = await target(args, context);
      return capture(args.timeoutSeconds ?? DEFAULT_RUN_SECONDS, context, (onOutput, signal) =>
        context.client.run({
          cwd,
          files: args.files,
          profiles: args.profiles,
          environment: processEnvironment(),
          build: args.build,
          egress: args.egress,
          service: args.service,
          command: args.command,
          noDeps: args.noDeps,
          stdin: args.stdin,
          onOutput,
          signal,
        }),
      );
    },
  }),
  define({
    name: "env",
    title: "查看环境",
    description:
      "当前 worktree 环境的状态、端口和变量（比如 NAPBOX_API_3100=127.0.0.1:41217）。不唤醒环境。代码连服务时用这里的地址；浏览器打开的页面地址用 NAPBOX_API_3100_SITE（比如 feat-x--crocwork.localhost:41217，每个环境的主机名不同，cookie 不串），本机程序的端口拼浏览器地址用 NAPBOX_HOSTNAME。compose 写了 x-napbox.host_ports 时还有 NAPBOX_HOST_<名字>=端口号，给项目在本机跑的程序自己监听。",
    input: z.strictObject({ directory, temp }),
    annotations: READ,
    async run(args, context) {
      return context.client.environment(await target(args, context));
    },
  }),
  define({
    name: "status",
    title: "所有环境",
    description: "napboxd 的版本和这台机器上所有环境的状态、端口。",
    input: z.strictObject({}),
    annotations: READ,
    run: (_args, context) => context.client.status(),
  }),
  define({
    name: "logs",
    title: "查看日志",
    description: "服务的日志，默认最后 200 行。不唤醒环境。每次启动前有一行分隔。",
    input: z.strictObject({
      directory,
      temp,
      service: z.string().describe("服务名"),
      tail: z.int().min(0).optional().describe("最后几行，默认 200"),
    }),
    annotations: READ,
    async run(args, context) {
      const output = new TailBuffer();
      await context.client.logs({
        target: await target(args, context),
        service: args.service,
        tail: args.tail ?? 200,
        onOutput: ({ data }) => output.add(data),
        signal: context.signal,
      });
      return { logs: output.text, droppedBytes: output.droppedBytes };
    },
  }),
  define({
    name: "exec",
    title: "在服务里执行命令",
    description: `在服务的容器里执行命令，比如跑数据库迁移或 psql。休眠时先唤醒。沿用容器的环境变量、工作目录和用户。stdout、stderr 各留最后 ${OUTPUT_LIMIT / 1024}KB；不支持交互。命令失败看 exitCode。`,
    input: z.strictObject({
      directory,
      temp,
      service: z.string().describe("服务名"),
      command: z.array(z.string()).min(1).describe('命令和参数，比如 ["sh", "-c", "ls /app | wc -l"]'),
      stdin: z.string().optional().describe("给命令的标准输入"),
      timeoutSeconds: timeoutSeconds(DEFAULT_EXEC_SECONDS, "，从命令开始跑算起，休眠时唤醒环境的时间不算在内"),
    }),
    annotations: { readOnlyHint: false, destructiveHint: true, idempotentHint: false },
    async run(args, context) {
      const environmentTarget = await target(args, context);
      return capture(undefined, context, (onOutput, signal) =>
        context.client.exec({
          target: environmentTarget,
          service: args.service,
          command: args.command,
          timeoutSeconds: args.timeoutSeconds ?? DEFAULT_EXEC_SECONDS,
          stdin: args.stdin,
          onOutput,
          signal,
        }),
      );
    },
  }),
  define({
    name: "reset",
    title: "换掉数据卷",
    description:
      "把数据卷换成空的，或者用 from 换成别的 worktree（比如主目录）环境最新快照里的那份，再重新起环境（一次性服务会重跑，迁移在新数据上跑）。" +
      "没点名的数据卷不动。旧数据保留 7 天。快照是源环境正常停下（闲置休眠、sleep）时拍的，要它的 compose 声明了 x-napbox.seed；复制不影响源环境。",
    input: z.strictObject({
      directory,
      volumes: z.array(z.string()).min(1).describe("数据卷名，可以给几个"),
      from: z
        .string()
        .optional()
        .describe("从这个目录所在 worktree 的开发环境的快照复制，比如主目录的路径；同一个项目。不写是换成空的"),
    }),
    annotations: DESTROY,
    async run(args, context) {
      const base = await context.sessionDirectory();
      return context.client.reset(await target(args, context), args.volumes, {
        from: args.from === undefined ? undefined : path.resolve(base, args.from),
      });
    },
  }),
  define({
    name: "sleep",
    title: "休眠环境",
    description: "让当前 worktree 的环境休眠，释放内存，断开现有连接。一连接就会自动唤醒。闲置 30 分钟也会自动休眠。",
    input: z.strictObject({ directory }),
    annotations: WRITE,
    async run(args, context) {
      return context.client.sleep(await target(args, context));
    },
  }),
  define({
    name: "down",
    title: "回收环境",
    description:
      "回收当前 worktree 的环境：停掉服务、释放端口，数据保留 7 天后删除。只是不用了不需要回收，它会自己休眠。传 temp 是销毁那个临时环境，它的数据直接删掉。",
    input: z.strictObject({ directory, temp }),
    annotations: DESTROY,
    async run(args, context) {
      return context.client.down(await target(args, context));
    },
  }),
  define({
    name: "egress",
    title: "切换出网模式",
    description: "open：服务能上外网；none：只能访问环境自己的服务。都访问不到宿主机和局域网。在运行的马上生效。",
    input: z.strictObject({ directory, temp, mode: EgressMode }),
    annotations: WRITE,
    async run(args, context) {
      return context.client.egress(await target(args, context), args.mode);
    },
  }),
  define({
    name: "setup",
    title: "首次准备",
    description:
      "第一次使用前的准备，或工具报 daemon_unavailable 时调用：下载约 700MB 的内核包，把后台程序 napboxd 注册成登录项并启动。已经准备好的不重做。后台程序要换版本时直接换：正在运行的环境会停下、连接断开，数据和端口都在，下次连接自动唤醒。",
    input: z.strictObject({}),
    annotations: { readOnlyHint: false, destructiveHint: false, idempotentHint: true },
    run: () => setup({ log: () => {} }),
  }),
];

export function listTools() {
  return tools.map(({ name, title, description, input, annotations }) => {
    const { $schema: _, ...inputSchema } = z.toJSONSchema(input) as Record<string, unknown>;
    return {
      name,
      title,
      description,
      inputSchema,
      annotations: { title, ...annotations, openWorldHint: false },
    };
  });
}

/** 工具的错误都放进结果（isError），不当 JSON-RPC 错误：agent 能看到原因 */
export async function callTool(
  name: string,
  rawArguments: unknown,
  context: ToolContext,
): Promise<ToolResult> {
  const tool = tools.find((candidate) => candidate.name === name);
  if (!tool) return failure("usage_error", `没有工具 ${name}`);
  const args = tool.input.safeParse(rawArguments ?? {});
  if (!args.success) return failure("usage_error", z.prettifyError(args.error));
  try {
    const value = await tool.run(args.data, context);
    const timedOut = (value as { timedOut?: boolean }).timedOut === true;
    return { value, isError: timedOut };
  } catch (error) {
    if (!(error instanceof NapboxError)) throw error;
    return failure(
      error.code,
      error.code === "daemon_unavailable"
        ? `${error.message} 调用 setup 工具准备（要用户同意：下载约 700MB、注册登录项）。`
        : error.message,
    );
  }
}

function failure(code: string, message: string): ToolResult {
  return { value: { error: { code, message } }, isError: true };
}
