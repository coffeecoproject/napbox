// 标准输入输出上的 MCP 服务（JSON-RPC，一行一条）。只提供工具，协议部分照 layermap 手写，不加 SDK 依赖。
import { createInterface } from "node:readline";
import { setTimeout as delay } from "node:timers/promises";
import { fileURLToPath } from "node:url";
import { NapboxClient } from "../client.ts";
import { packageVersion } from "./locations.ts";
import { callTool, listTools } from "./tools.ts";

const ROOTS_WAIT_MS = 5_000;

const INSTRUCTIONS =
  "napbox 用项目的 compose 文件给每个 worktree 起一套隔离的开发服务（数据库、对象存储、后端），不用 Docker，端口不冲突，同一个环境的端口固定不变，闲置自动休眠，连接时自动唤醒。需要这些服务时用 up 工具，不要运行 docker compose up。测试要一套用完就扔的服务时给 up 传 temp，要单独跑一次某个服务时用 run 工具，不要运行 docker run。前端、小程序要连后端时，由项目的启动脚本从 up 或 env 取地址交给它们，不要把端口写进代码。新项目要用这些服务时也照这样：写 compose.yaml（ports 只写容器端口）用 up 起，项目的脚本和 README 里不要用 docker，写法见 napbox 技能。";

type Message = {
  id?: string | number | null;
  method?: string;
  params?: Record<string, unknown>;
  result?: Record<string, unknown>;
};

export function serveMcp(): Promise<void> {
  const send = (message: Record<string, unknown>) =>
    process.stdout.write(`${JSON.stringify({ jsonrpc: "2.0", ...message })}\n`);
  const client = new NapboxClient();
  const calls = new Map<string | number, AbortController>();
  const replies = new Map<string | number, (message: Message) => void>();

  // 环境按 worktree 识别，所以要知道会话在哪工作。客户端不一定在那里启动服务：Claude Code 桌面版
  // 在主 checkout 启动，会话却在别的 worktree。客户端能列出 roots 时以第一个 root 为准。
  let sessionDirectory = process.cwd();
  let listsRoots = false;
  let rooted: Promise<unknown> = Promise.resolve();
  let requests = 0;
  const readRoots = () => {
    const id = `napbox-roots-${++requests}`;
    const reply = new Promise<Message>((resolve) => replies.set(id, resolve));
    send({ id, method: "roots/list" });
    rooted = Promise.race([reply, delay(ROOTS_WAIT_MS, undefined, { ref: false })]).then((message) => {
      replies.delete(id);
      const roots = message?.result?.roots;
      const root = Array.isArray(roots)
        ? roots.find((item) => typeof item?.uri === "string" && item.uri.startsWith("file:"))
        : undefined;
      if (root && id === `napbox-roots-${requests}`) sessionDirectory = fileURLToPath(root.uri);
    });
  };

  const call = async (id: string | number, params: Record<string, unknown>) => {
    const controller = new AbortController();
    calls.set(id, controller);
    try {
      const { value, isError } = await callTool(String(params.name), params.arguments, {
        client,
        sessionDirectory: async () => {
          await rooted;
          return sessionDirectory;
        },
        signal: controller.signal,
      });
      send({
        id,
        result: { content: [{ type: "text", text: JSON.stringify(value, null, 2) }], isError },
      });
    } catch (error) {
      // 取消的请求不用回应（MCP 规定）
      if (controller.signal.aborted) return;
      send({
        id,
        result: {
          content: [
            {
              type: "text",
              text: JSON.stringify({ error: { code: "internal_error", message: String(error) } }),
            },
          ],
          isError: true,
        },
      });
    } finally {
      calls.delete(id);
    }
  };

  const handle = (message: Message) => {
    const { id, method, params = {} } = message;
    if (method === undefined) {
      if (id !== undefined && id !== null) replies.get(id)?.(message);
      return;
    }
    if (id === undefined || id === null) {
      if (listsRoots && (method === "notifications/initialized" || method === "notifications/roots/list_changed")) {
        readRoots();
      }
      if (method === "notifications/cancelled") {
        calls.get(params.requestId as string | number)?.abort();
      }
      return;
    }
    switch (method) {
      case "initialize":
        listsRoots = Boolean((params.capabilities as { roots?: unknown } | undefined)?.roots);
        return send({
          id,
          result: {
            protocolVersion: typeof params.protocolVersion === "string" ? params.protocolVersion : "2025-06-18",
            capabilities: { tools: { listChanged: false } },
            serverInfo: { name: "napbox", title: "napbox", version: packageVersion },
            instructions: INSTRUCTIONS,
          },
        });
      case "ping":
        return send({ id, result: {} });
      case "tools/list":
        return send({ id, result: { tools: listTools() } });
      case "tools/call":
        return void call(id, params);
      default:
        return send({ id, error: { code: -32601, message: `Method not found: ${method}` } });
    }
  };

  return new Promise((resolve) => {
    const lines = createInterface({ input: process.stdin, crlfDelay: Infinity });
    lines.on("line", (line) => {
      if (!line.trim()) return;
      let message: Message;
      try {
        message = JSON.parse(line);
      } catch {
        return send({ id: null, error: { code: -32700, message: "Parse error" } });
      }
      handle(message);
    });
    // 会话结束：结束还在跑的 exec，进程退出时连接随之断开
    lines.on("close", () => {
      for (const controller of calls.values()) controller.abort();
      resolve();
    });
  });
}
