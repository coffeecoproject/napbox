// 测试共用：起一份独立的真实 napboxd（NAPBOX_SUPPORT_DIR 指向临时目录），绕过客户端直接发请求看原始回应。
import { type ChildProcess, spawn } from "node:child_process";
import { mkdirSync, openSync, writeFileSync } from "node:fs";
import { createConnection } from "node:net";
import path from "node:path";
import { pathToFileURL } from "node:url";
import { NapboxClient, NapboxError } from "../src/client.ts";

export interface Daemon {
  process: ChildProcess;
  client: NapboxClient;
  socketPath: string;
  /** 发信号并等进程退出 */
  stop(signal: NodeJS.Signals): Promise<void>;
}

export async function startDaemon(supportDir: string, logFile: string): Promise<Daemon> {
  const bin = process.env.NAPBOX_BIN;
  if (!bin) throw new Error("要从 scripts/test-client.sh 运行，它会编译并设好 NAPBOX_BIN");
  const socketPath = path.join(supportDir, "napboxd.sock");
  const log = openSync(logFile, "a");
  const child = spawn(path.join(bin, "napboxd"), {
    env: { ...process.env, NAPBOX_SUPPORT_DIR: supportDir },
    stdio: ["ignore", log, log],
  });
  const exited = new Promise<void>((resolve) => child.once("exit", () => resolve()));
  const client = new NapboxClient({ socketPath });
  for (let i = 0; ; i++) {
    try {
      await client.status();
      break;
    } catch (error) {
      if (i >= 100) throw error;
      await delay(100);
    }
  }
  return {
    process: child,
    client,
    socketPath,
    async stop(signal) {
      child.kill(signal);
      await exited;
    },
  };
}

export function delay(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

/** 等到条件成立，超时报错并带上说明 */
export async function waitUntil(
  what: string,
  condition: () => boolean | Promise<boolean>,
  timeoutMs = 60_000,
): Promise<void> {
  const deadline = Date.now() + timeoutMs;
  while (!(await condition())) {
    if (Date.now() > deadline) throw new Error(`等不到：${what}`);
    await delay(100);
  }
}

/** 不经客户端发一个请求，返回第一行回应解析后的原始 JSON（用来比较客户端有没有丢字段） */
export function rawCall(socketPath: string, method: string, params?: unknown): Promise<RawReply> {
  return new Promise((resolve, reject) => {
    const socket = createConnection(socketPath);
    let buffer = "";
    socket.setEncoding("utf8");
    socket.on("connect", () => socket.write(`${JSON.stringify({ id: 1, method, params })}\n`));
    socket.on("data", (chunk) => {
      buffer += chunk;
      const end = buffer.indexOf("\n");
      if (end < 0) return;
      socket.destroy();
      resolve(JSON.parse(buffer.slice(0, end)) as RawReply);
    });
    socket.on("error", reject);
  });
}

export interface RawReply {
  id: number;
  result?: unknown;
  error?: { code: string; message: string };
}

/** 断言 promise 以这个错误码的 NapboxError 拒绝，返回这个错误 */
export async function rejectsWithCode(promise: Promise<unknown>, code: string): Promise<NapboxError> {
  try {
    await promise;
  } catch (error) {
    if (error instanceof NapboxError && error.code === code) return error;
    throw new Error(`期望错误码 ${code}，实际：${String(error)}`, { cause: error });
  }
  throw new Error(`期望错误码 ${code}，实际成功了`);
}

/** 像 agent 一样和 MCP 服务通信：标准输入输出上一行一条 JSON-RPC */
export class McpClient {
  readonly process: ChildProcess;
  readonly stderr: string[] = [];
  private buffer = "";
  private nextId = 1;
  private readonly pending = new Map<number, (message: McpMessage) => void>();
  private readonly closed: Promise<void>;
  roots: string[] | undefined;

  constructor(command: string, args: string[], options: { cwd: string; env: NodeJS.ProcessEnv }) {
    this.process = spawn(command, args, { ...options, stdio: ["pipe", "pipe", "pipe"] });
    this.process.stdout?.setEncoding("utf8").on("data", (chunk: string) => this.read(chunk));
    this.process.stderr?.setEncoding("utf8").on("data", (chunk: string) => this.stderr.push(chunk));
    this.closed = new Promise((resolve) => this.process.once("close", () => resolve()));
  }

  private read(chunk: string) {
    this.buffer += chunk;
    for (let end = this.buffer.indexOf("\n"); end >= 0; end = this.buffer.indexOf("\n")) {
      const message = JSON.parse(this.buffer.slice(0, end)) as McpMessage;
      this.buffer = this.buffer.slice(end + 1);
      if (message.method === "roots/list") {
        const roots = (this.roots ?? []).map((directory) => ({ uri: pathToFileURL(directory).href }));
        this.send({ id: message.id, result: { roots } });
      } else {
        this.pending.get(message.id as number)?.(message);
      }
    }
  }

  send(message: Record<string, unknown>) {
    this.process.stdin?.write(`${JSON.stringify({ jsonrpc: "2.0", ...message })}\n`);
  }

  request(method: string, params: Record<string, unknown> = {}): Promise<McpMessage> {
    const id = this.nextId++;
    return new Promise((resolve) => {
      this.pending.set(id, resolve);
      this.send({ id, method, params });
    });
  }

  async initialize() {
    const capabilities = this.roots ? { roots: {} } : {};
    const reply = await this.request("initialize", { protocolVersion: "2025-06-18", capabilities });
    this.send({ method: "notifications/initialized" });
    return reply;
  }

  /** 调用工具，返回解析后的内容和 isError */
  async tool(name: string, args: Record<string, unknown> = {}) {
    const { result } = await this.request("tools/call", { name, arguments: args });
    const { content, isError } = result as { content: { text: string }[]; isError: boolean };
    return { value: JSON.parse((content[0] as { text: string }).text), isError };
  }

  /** 关掉标准输入（agent 结束会话）并等进程退出 */
  async close() {
    this.process.stdin?.end();
    await this.closed;
  }
}

export interface McpMessage {
  id?: number | string;
  method?: string;
  result?: Record<string, unknown>;
  error?: { code: number; message: string };
}

/**
 * 构建虚拟机的地址记在隔离目录里轮换（DESIGN.md 第 2 节「开着 Clash TUN 时的断网」）。每次都是新目录，不写的话每轮都从同一个地址开始，
 * 碰到不通的就一直不通。真实使用时这个文件一直在，地址是接着轮的。
 */
export function startBuilderAtRandomAddress(support: string): void {
  mkdirSync(path.join(support, "builder"), { recursive: true });
  writeFileSync(path.join(support, "builder", "last-address"), `192.168.64.${247 + Math.floor(Math.random() * 8)}`);
}
