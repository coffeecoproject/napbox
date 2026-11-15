// 由 scripts/plugins.ts 从 scripts/server-launcher.mjs 生成。
// 启动固定版本的 napbox MCP 服务，就在这个进程里。这个版本只在第一次安装一次，装进 napbox 的缓存目录，
// 之后不需要 npm 和网络。npm 在缓存目录里运行，项目自己的 npm 设置和依赖不会影响安装结果。
import { spawn } from "node:child_process";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, renameSync, rmSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import path from "node:path";
import { pathToFileURL } from "node:url";

const VERSION = "0.1.5";

// 和 src/agent/locations.ts 的 cacheDirectory 同一个目录
const versions = path.join(homedir(), "Library/Caches/napbox/versions");
const home = path.join(versions, VERSION);
const installed = path.join(home, "node_modules/napbox");
const manifest = path.join(installed, "package.json");

// 运行这个脚本的 Node 自带的 npm，没有就用 PATH 上的
const npm = () => {
  const directory = path.dirname(process.execPath);
  for (const cli of [
    path.join(directory, "node_modules/npm/bin/npm-cli.js"),
    path.join(directory, "../lib/node_modules/npm/bin/npm-cli.js"),
  ])
    if (existsSync(cli)) return [process.execPath, [cli]];
  return ["npm", []];
};

// 装进单独的目录，完整了才改名到位：不会从装了一半的地方启动，两个同时启动也只留先改名的那个
async function install() {
  mkdirSync(versions, { recursive: true, mode: 0o700 });
  const staging = mkdtempSync(path.join(versions, `.${VERSION}-`));
  process.stderr.write(`napbox：用 npm 安装 napbox@${VERSION}\n`);
  const [command, prefix] = npm();
  const args = [
    ...prefix,
    "install",
    `napbox@${VERSION}`,
    "--prefix",
    staging,
    "--prefer-online",
    "--omit=dev",
    "--no-audit",
    "--no-fund",
    "--no-update-notifier",
    "--loglevel=error",
  ];
  await new Promise((resolve, reject) => {
    const child = spawn(command, args, { cwd: staging, stdio: ["ignore", "pipe", "pipe"] });
    let output = "";
    child.stdout.on("data", (data) => (output += data));
    child.stderr.on("data", (data) => (output += data));
    child.on("error", reject);
    child.on("close", (code) =>
      code === 0 ? resolve() : reject(new Error(`npm 退出码 ${code}\n${output.trim()}`)),
    );
  }).catch((error) => {
    rmSync(staging, { recursive: true, force: true });
    throw error;
  });
  try {
    renameSync(staging, home);
  } catch (error) {
    rmSync(staging, { recursive: true, force: true });
    if (!existsSync(manifest)) throw error;
  }
}

try {
  if (!existsSync(manifest)) await install();
  // 一周没启动过的版本会从缓存里删掉（src/agent/cache.ts）
  writeFileSync(path.join(home, "last-used"), "");
  const entry = path.join(installed, JSON.parse(readFileSync(manifest, "utf8")).bin.napbox);
  process.argv = [process.argv[0], entry, "mcp"];
  await import(pathToFileURL(entry).href);
} catch (error) {
  process.stderr.write(`napbox：启动不了 ${VERSION}：${error?.message ?? error}\n`);
  process.exit(1);
}
