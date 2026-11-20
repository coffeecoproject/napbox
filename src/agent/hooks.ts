// Claude Code 插件的钩子：
// - 会话开始和每次压缩上下文之后，当前 worktree 有环境就把端口告诉 agent；
// - 已接入的项目里运行 docker compose up/start/run 时拦下；自己起数据库这类服务、或者 docker run 时提醒。
import { execFile } from "node:child_process";
import { existsSync, realpathSync } from "node:fs";
import path from "node:path";
import { NapboxClient, NapboxError } from "../client.ts";
import type { EnvironmentInfo } from "../protocol.ts";
import { composeSubcommand, isDockerRun, simpleCommands, startsOwnService } from "./shell-command.ts";

const BLOCKED_COMPOSE = new Set(["up", "start", "run"]);
const RUN_INSTEAD =
  "要像 docker compose run 那样单独跑一次某个服务（测试、检查），用 run 工具（命令行是 npx napbox run <服务> [-- 命令]）：临时起一个环境，在前台跑它，跑完销毁，返回它的退出码和输出。";
const TEMP_INSTEAD =
  "测试要一套用完就扔的（比如空的数据库），给 up 工具传 temp 起一个临时环境（命令行是 npx napbox up --temp <名字>），用完调 down 传同一个名字。";
/** 大多数 Bash 命令到这里就结束，不用查 git 和 napboxd */
const MIGHT_MATTER = /docker|postgres|pg_ctl|mysql|mongod|redis-server|minio|brew/;

export interface HookInput {
  hook_event_name?: string;
  cwd?: string;
  tool_name?: string;
  tool_input?: { command?: unknown };
}

export async function runHook(input: HookInput): Promise<Record<string, unknown> | undefined> {
  const cwd = input.cwd || process.cwd();
  if (input.hook_event_name === "SessionStart") {
    const note = await sessionNote(cwd);
    return note
      ? { hookSpecificOutput: { hookEventName: "SessionStart", additionalContext: note } }
      : undefined;
  }
  if (input.hook_event_name === "PreToolUse" && input.tool_name === "Bash") {
    const command = input.tool_input?.command;
    return typeof command === "string" ? await checkCommand(command, cwd) : undefined;
  }
  return undefined;
}

async function sessionNote(cwd: string): Promise<string | undefined> {
  let info: EnvironmentInfo;
  try {
    info = await new NapboxClient().environment({ cwd });
  } catch (error) {
    if (error instanceof NapboxError && error.code === "daemon_unavailable") {
      return (await isOnboarded(cwd))
        ? "这个项目用 napbox 管理服务，但 napbox 的后台程序没有运行。需要服务时调用 napbox 的 setup 工具。"
        : undefined;
    }
    // 这里没有环境（environment_not_found、not_in_repository 等）：什么都不说
    if (error instanceof NapboxError) return undefined;
    throw error;
  }
  return describeEnvironment(info);
}

export function describeEnvironment(info: EnvironmentInfo): string {
  const lines = [`这个 worktree 的 napbox 环境是 ${info.name}（${info.state}）。服务和端口：`];
  for (const port of info.ports) {
    lines.push(
      `- ${port.service}:${port.containerPort} → 127.0.0.1:${port.hostPort}（变量 ${port.variable}）`,
    );
  }
  lines.push(
    `浏览器打开的页面地址用这个环境的主机名 ${info.hostname}（变量 NAPBOX_<服务>_<端口>_SITE 是主机名加端口，NAPBOX_HOSTNAME 是主机名），每个环境不同，cookie 不串；程序连服务仍用 127.0.0.1。`,
  );
  for (const port of info.hostPorts) {
    lines.push(`- 本机程序用的 ${port.name} → 端口 ${port.hostPort}（变量 ${port.variable}，napbox 不占着，项目的程序自己监听）`);
  }
  if (info.state !== "running") lines.push("休眠时一连接就会自动唤醒，不用手动启动。");
  if (info.lastError) lines.push(`最近出错：${info.lastError}`);
  if (info.snapshotError) lines.push(info.snapshotError);
  if (info.composeChanged) lines.push(info.composeChanged);
  if (info.unsetVariables.length) {
    lines.push(`compose 里用到但没有值的变量：${info.unsetVariables.join("、")}`);
  }
  lines.push("用 napbox 的工具（up、env、logs、exec、reset）管理这些服务，不要运行 docker compose up。");
  return lines.join("\n");
}

async function checkCommand(command: string, cwd: string) {
  if (!MIGHT_MATTER.test(command)) return undefined;
  const commands = simpleCommands(command);
  for (const { argv, cds } of commands) {
    const subcommand = composeSubcommand(argv);
    if (subcommand === undefined || !BLOCKED_COMPOSE.has(subcommand)) continue;
    if (!(await isOnboarded(resolveCds(cwd, cds)))) continue;
    return {
      hookSpecificOutput: {
        hookEventName: "PreToolUse",
        permissionDecision: "deny",
        permissionDecisionReason: `这个项目的服务由 napbox 管理，不能运行 docker compose ${subcommand}。改用 napbox 的 up 工具（命令行是 npx napbox up），它用同一份 compose 起服务，并返回分配好的端口和变量。服务里执行命令用 exec 工具。${subcommand === "run" ? RUN_INSTEAD : ""}如果用户明确要用 Docker，请用户自己在终端运行。`,
      },
    };
  }
  for (const { argv, cds } of commands) {
    const reminder = ownServiceReminder(argv);
    if (reminder === undefined || !(await isOnboarded(resolveCds(cwd, cds)))) continue;
    return { hookSpecificOutput: { hookEventName: "PreToolUse", additionalContext: reminder } };
  }
  return undefined;
}

/** 不拦、只提醒的命令：在宿主机上自己起数据库这类服务，或者 docker run 直接起一个容器 */
function ownServiceReminder(argv: string[]): string | undefined {
  const service = startsOwnService(argv);
  if (service !== undefined) {
    return `提醒：这个项目的服务由 napbox 管理。如果 ${service} 是 compose 里已有的服务，用 napbox 的 up 工具和它分配的端口，不要自己再起一份。${TEMP_INSTEAD}`;
  }
  if (isDockerRun(argv)) {
    return `提醒：这个项目的服务由 napbox 管理。如果 docker run 要起的是 compose 里已有的服务，用 napbox 的工具，不要自己再起一份。${TEMP_INSTEAD}只跑一次拿结果的，用 run 工具（命令行是 npx napbox run <服务> [-- 命令]）。`;
  }
  return undefined;
}

function resolveCds(cwd: string, cds: string[]): string {
  return cds.reduce((directory, target) => path.resolve(directory, target), cwd);
}

/** 已接入：worktree 根目录有 .napbox.yaml，或者这个仓库的某个 worktree 有环境记录 */
async function isOnboarded(directory: string): Promise<boolean> {
  const root = await git(directory, ["rev-parse", "--show-toplevel"]);
  if (!root) return false;
  if (existsSync(path.join(root.trim(), ".napbox.yaml"))) return true;
  let worktrees: Set<string>;
  try {
    const { environments } = await new NapboxClient().status();
    worktrees = new Set(environments.filter((e) => !e.owner).map((e) => canonical(e.worktree)));
  } catch (error) {
    if (error instanceof NapboxError && error.code === "daemon_unavailable") return false;
    throw error;
  }
  const listed = (await git(directory, ["worktree", "list", "--porcelain"])) ?? "";
  return listed
    .split("\n")
    .filter((line) => line.startsWith("worktree "))
    .some((line) => worktrees.has(canonical(line.slice("worktree ".length))));
}

/** 路径可能写成 /var 或 /private/var，比较前统一。已经不存在的路径原样比较 */
function canonical(file: string): string {
  try {
    return realpathSync(file);
  } catch {
    return file;
  }
}

function git(directory: string, args: string[]): Promise<string | undefined> {
  return new Promise((resolve) => {
    execFile("git", ["-C", directory, ...args], (error, stdout) => {
      resolve(error ? undefined : stdout);
    });
  });
}
