// 由 scripts/plugins.ts 从 scripts/hook-launcher.mjs 生成。
// 钩子用缓存目录里固定版本的 napbox 运行。不在这里安装（安装由 MCP 服务的启动脚本做，钩子不能等 npm）：
// 还没装好时什么都不做。这时也不可能有 napbox 的环境。
import { existsSync, readFileSync } from "node:fs";
import { homedir } from "node:os";
import path from "node:path";
import { pathToFileURL } from "node:url";

const VERSION = "0.1.13";

const installed = path.join(homedir(), "Library/Caches/napbox/versions", VERSION, "node_modules/napbox");
const manifest = path.join(installed, "package.json");
if (existsSync(manifest)) {
  const entry = path.join(installed, JSON.parse(readFileSync(manifest, "utf8")).bin.napbox);
  process.argv = [process.argv[0], entry, "hook"];
  await import(pathToFileURL(entry).href);
}
