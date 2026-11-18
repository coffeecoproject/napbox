// napbox setup：把后台程序放到固定位置，准备内核和 vminit，注册成登录项并启动。
// 不放在 npm 或 npx 的目录里运行：那些目录会变、会被清理，登录项要一直找得到程序。
import { execFile as execFileCallback, spawn } from "node:child_process";
import { createHash } from "node:crypto";
import { existsSync, readFileSync } from "node:fs";
import { chmod, cp, mkdir, mkdtemp, readdir, rename, rm, writeFile } from "node:fs/promises";
import { homedir } from "node:os";
import path from "node:path";
import { createInterface } from "node:readline";
import { promisify } from "node:util";
import { NapboxClient, NapboxError, supportDirectory } from "../client.ts";
import type { StatusResult } from "../protocol.ts";
import { cacheDirectory, nativeDirectory, packageRoot, packageVersion } from "./locations.ts";

const execFile = promisify(execFileCallback);

const BASE_LABEL = "io.github.coffeecoproject.napbox";
const MINIMUM_MACOS = 26;
/** napboxd 收到 SIGTERM 后要停掉所有环境，launchd 默认只等 20 秒 */
const EXIT_TIMEOUT_SECONDS = 120;
const START_TIMEOUT_MS = 20_000;

export interface SetupResult {
  version: string;
  /** started：新启动；restarted：换了版本；unchanged：已经是这个版本 */
  daemon: "started" | "restarted" | "unchanged";
  daemonVersion: string;
  pid: number;
}

export interface SetupOptions {
  log: (line: string) => void;
}

const failed = (message: string) => new NapboxError("setup_failed", message);

/** 设了 NAPBOX_SUPPORT_DIR（测试用的独立目录）时用另一个名字，不和正式的登录项冲突 */
function launchLabel(): string {
  const custom = process.env.NAPBOX_SUPPORT_DIR;
  if (!custom) return BASE_LABEL;
  return `${BASE_LABEL}.${createHash("sha256").update(custom).digest("hex").slice(0, 8)}`;
}

const launchDomain = () => `gui/${process.getuid?.()}`;

async function launchctl(...args: string[]) {
  return execFile("launchctl", args);
}

async function isRegistered(): Promise<boolean> {
  try {
    await launchctl("print", `${launchDomain()}/${launchLabel()}`);
    return true;
  } catch {
    return false;
  }
}

async function checkPlatform() {
  if (process.platform !== "darwin" || process.arch !== "arm64") {
    throw failed(`napbox 只支持 Apple 芯片的 Mac，这里是 ${process.platform} ${process.arch}`);
  }
  const { stdout } = await execFile("sw_vers", ["-productVersion"]);
  if (Number.parseInt(stdout, 10) < MINIMUM_MACOS) {
    throw failed(`napbox 要 macOS ${MINIMUM_MACOS} 或更新的版本，这里是 ${stdout.trim()}`);
  }
}

async function runningDaemon(client: NapboxClient): Promise<StatusResult | undefined> {
  try {
    return await client.status();
  } catch (error) {
    if (error instanceof NapboxError && error.code === "daemon_unavailable") return undefined;
    throw error;
  }
}

const fileHash = (file: string) => createHash("sha256").update(readFileSync(file)).digest("hex");

// 换不换版本只看文件：登录项是不是指着这个包里的程序，再看它在不在听。不问正在运行的 napboxd，它可能是旧版，协议对不上。
// 在不在听要看：napboxd 收到 SIGTERM 正常退出后 launchd 不再拉起，登录项却还注册着。
// 要换就直接换：正在运行的环境停掉、连接断开，数据和端口都在，下次连接自动唤醒。
export async function setup({ log }: SetupOptions): Promise<SetupResult> {
  await checkPlatform();
  const source = nativeDirectory();
  const sourceDaemon = path.join(source, "napboxd");
  if (!existsSync(sourceDaemon)) throw failed(`没有 ${sourceDaemon}：包不完整`);

  const client = new NapboxClient();
  const registered = await isRegistered();
  if (!registered && (await client.accepts())) {
    throw failed(`有一份不是登录项的 napboxd 在运行（${client.socketPath}），先停掉它再运行 setup`);
  }

  const installDirectory = path.join(supportDirectory(), "daemon", packageVersion);
  const installedDaemon = path.join(installDirectory, "napboxd");
  const sameProgram = existsSync(installedDaemon) && fileHash(installedDaemon) === fileHash(sourceDaemon);
  const upToDate =
    registered && sameProgram && readLaunchAgent() === launchAgent(installedDaemon) && (await client.accepts());

  if (!sameProgram) await install(source, installDirectory);
  await prepare(installedDaemon, log);
  if (upToDate) {
    const current = await waitForDaemon(client);
    return { version: packageVersion, daemon: "unchanged", daemonVersion: current.version, pid: current.pid };
  }

  // 先停旧的再写登录项：登录项指着这个程序，就说明旧的已经停了
  if (registered) await stopRegistered(client);
  await writeLaunchAgent(installedDaemon);
  await bootstrap();
  const started = await waitForDaemon(client);
  if (started.version !== packageVersion) {
    throw failed(`启动后 napboxd 的版本是 ${started.version}，包的版本是 ${packageVersion}，这个包打得不对`);
  }
  await removeOldVersions(path.dirname(installDirectory));
  return {
    version: packageVersion,
    daemon: registered ? "restarted" : "started",
    daemonVersion: started.version,
    pid: started.pid,
  };
}

/** 先放进临时目录再改名：不会留下一半 */
async function install(source: string, destination: string) {
  const parent = path.dirname(destination);
  await mkdir(parent, { recursive: true });
  const staging = await mkdtemp(path.join(parent, ".install-"));
  try {
    // napboxd 用到的都和它放在一起：网络小容器的程序，建数据盘的 e2fsprogs 程序和它的配置
    for (const [name, mode] of [
      ["napboxd", 0o755],
      ["napbox-guard", 0o755],
      ["mke2fs", 0o755],
      ["debugfs", 0o755],
      ["mke2fs.conf", 0o644],
    ] as const) {
      await cp(path.join(source, name), path.join(staging, name));
      await chmod(path.join(staging, name), mode);
    }
    await rm(destination, { recursive: true, force: true });
    await rename(staging, destination);
  } finally {
    await rm(staging, { recursive: true, force: true });
  }
}

/** 下载可能要很久（慢的网络要几个小时），进度一行一行实时转出来 */
async function prepare(daemon: string, log: (line: string) => void) {
  const child = spawn(daemon, ["prepare"], { stdio: ["ignore", "pipe", "pipe"] });
  let stderr = "";
  child.stderr.setEncoding("utf8").on("data", (chunk: string) => (stderr += chunk));
  const lines = createInterface({ input: child.stdout, crlfDelay: Infinity });
  lines.on("line", (line) => line && log(line));
  const exit = await new Promise<{ code: number | null; signal: NodeJS.Signals | null }>((resolve, reject) => {
    child.on("error", reject);
    child.on("close", (code, signal) => resolve({ code, signal }));
  }).catch((error: Error) => {
    throw failed(`准备内核和 vminit 失败：${error.message}`);
  });
  if (exit.code !== 0) {
    const reason = stderr.trim() || (exit.signal ? `napboxd prepare 被信号 ${exit.signal} 停下` : `napboxd prepare 退出码 ${exit.code}`);
    throw failed(`准备内核和 vminit 失败：${reason}`);
  }
}

const xml = (text: string) =>
  text.replaceAll("&", "&amp;").replaceAll("<", "&lt;").replaceAll(">", "&gt;");

function launchAgent(daemon: string): string {
  const log = xml(path.join(supportDirectory(), "napboxd.log"));
  const custom = process.env.NAPBOX_SUPPORT_DIR;
  const environment = custom
    ? `  <key>EnvironmentVariables</key>
  <dict>
    <key>NAPBOX_SUPPORT_DIR</key>
    <string>${xml(custom)}</string>
  </dict>
`
    : "";
  // ProcessType：不写时 launchd 会限速，虚拟机跟着慢。Interactive 和普通 app 一样不限。
  // KeepAlive：崩溃了拉起来；正常退出（退出码 0）不拉，比如 launchctl bootout。
  return `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>${launchLabel()}</string>
  <key>ProgramArguments</key>
  <array>
    <string>${xml(daemon)}</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <dict>
    <key>SuccessfulExit</key>
    <false/>
  </dict>
  <key>ProcessType</key>
  <string>Interactive</string>
  <key>ExitTimeOut</key>
  <integer>${EXIT_TIMEOUT_SECONDS}</integer>
  <key>StandardOutPath</key>
  <string>${log}</string>
  <key>StandardErrorPath</key>
  <string>${log}</string>
${environment}</dict>
</plist>
`;
}

const launchAgentPath = () => path.join(homedir(), "Library/LaunchAgents", `${launchLabel()}.plist`);

function readLaunchAgent(): string | undefined {
  const file = launchAgentPath();
  return existsSync(file) ? readFileSync(file, "utf8") : undefined;
}

async function writeLaunchAgent(daemon: string) {
  const file = launchAgentPath();
  await mkdir(path.dirname(file), { recursive: true });
  await writeFile(`${file}.tmp`, launchAgent(daemon));
  await rename(`${file}.tmp`, file);
}

/** 停掉正在运行的。bootout 发 SIGTERM，napboxd 停完环境才退出 */
async function stopRegistered(client: NapboxClient) {
  await launchctl("bootout", `${launchDomain()}/${launchLabel()}`).catch(() => {});
  const deadline = Date.now() + (EXIT_TIMEOUT_SECONDS + 10) * 1000;
  while ((await isRegistered()) || (await client.accepts())) {
    if (Date.now() > deadline) throw failed("旧的 napboxd 一直没有退出");
    await sleep(200);
  }
}

/** launchd 刚清理完同名服务时可能短暂报错，等一下再试 */
async function bootstrap() {
  for (let attempt = 0; ; attempt++) {
    try {
      await launchctl("bootstrap", launchDomain(), launchAgentPath());
      return;
    } catch (error) {
      if (attempt >= 10) {
        throw failed(`注册登录项失败：${(error as { stderr?: string }).stderr?.trim() || String(error)}`);
      }
      await sleep(500);
    }
  }
}

async function waitForDaemon(client: NapboxClient): Promise<StatusResult> {
  const deadline = Date.now() + START_TIMEOUT_MS;
  for (;;) {
    const status = await runningDaemon(client);
    if (status) return status;
    if (Date.now() > deadline) {
      throw failed(`napboxd 没有启动，看 ${path.join(supportDirectory(), "napboxd.log")}`);
    }
    await sleep(200);
  }
}

async function removeOldVersions(directory: string) {
  for (const name of await readdir(directory)) {
    if (name !== packageVersion) await rm(path.join(directory, name), { recursive: true, force: true });
  }
}

const sleep = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms));

// ---- 不用插件时：把 MCP 服务加进 agent（npx napbox setup claude|codex）

export type SetupAgent = "claude" | "codex";

/** agent 启动 MCP 服务用的命令。发布的包：缓存目录里的启动脚本，不依赖 npx 的目录；仓库里：直接运行自己 */
async function mcpCommand(): Promise<string[]> {
  const published = path.join(packageRoot, "dist/server-launcher.mjs");
  if (!existsSync(published)) return [process.execPath, path.resolve(process.argv[1] as string), "mcp"];
  const launcher = path.join(cacheDirectory(), "server.mjs");
  await mkdir(cacheDirectory(), { recursive: true });
  await cp(published, launcher);
  return ["node", launcher];
}

export async function registerMcp(agent: SetupAgent) {
  const scope = agent === "claude" ? ["--scope", "user"] : [];
  const command = await mcpCommand();
  await execFile(agent, ["mcp", "remove", "napbox", ...scope]).catch(() => {});
  try {
    await execFile(agent, ["mcp", "add", ...scope, "napbox", "--", ...command]);
  } catch (error) {
    const { stderr, message } = error as { stderr?: string; message: string };
    throw failed(`加不进 ${agent}：${stderr?.trim() || message}`);
  }
  return { agent, server: "napbox", command };
}
