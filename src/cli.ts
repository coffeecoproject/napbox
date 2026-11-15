#!/usr/bin/env node
// npm 包的 napbox 命令。setup、mcp、hook 是 TypeScript 写的；其余都交给 Swift 写的命令行，
// 用 execve 直接换成它：标准输入输出、信号和退出码都不用转发。
import path from "node:path";
import { NapboxError } from "./client.ts";
import { runHook, type HookInput } from "./agent/hooks.ts";
import { nativeDirectory } from "./agent/locations.ts";
import { serveMcp } from "./agent/mcp.ts";
import { sweepCachedVersions } from "./agent/cache.ts";
import { registerMcp, setup } from "./agent/setup.ts";

const [command, ...rest] = process.argv.slice(2);

async function runSetup(args: string[]) {
  const [agent, extra] = args;
  if (extra !== undefined || (agent !== undefined && agent !== "claude" && agent !== "codex")) {
    throw new NapboxError("usage_error", "用法：napbox setup [claude|codex]");
  }
  const result = await setup({ log: (line) => process.stderr.write(`${line}\n`) });
  const mcp = agent ? await registerMcp(agent) : undefined;
  process.stdout.write(`${JSON.stringify({ ...result, mcp })}\n`);
}

async function readStdin(): Promise<string> {
  let text = "";
  process.stdin.setEncoding("utf8");
  for await (const chunk of process.stdin) text += chunk;
  return text;
}

try {
  switch (command) {
    case "setup":
      await runSetup(rest);
      break;
    case "mcp":
      // 只是清理，失败了下次再清，不影响服务
      void sweepCachedVersions().catch(() => {});
      await serveMcp();
      process.exit(0);
      break;
    case "hook": {
      const output = await runHook(JSON.parse(await readStdin()) as HookInput);
      if (output) process.stdout.write(`${JSON.stringify(output)}\n`);
      break;
    }
    default: {
      const native = path.join(nativeDirectory(), "napbox");
      // engines 要求的 Node 都有它，类型里写成可选是因为 Windows 没有
      process.execve!(native, [native, ...process.argv.slice(2)]);
    }
  }
} catch (error) {
  // 和命令行一样的错误格式
  const { code, message } =
    error instanceof NapboxError ? error : { code: "internal_error", message: String(error) };
  process.stdout.write(`${JSON.stringify({ error: { code, message } })}\n`);
  process.exit(1);
}
