// 打好的 npm 包的全流程，从 scripts/test-package.sh 运行：
// 假的 npm registry 提供 .pack 里的包 → 插件的启动脚本安装它 → setup 工具（下载内核、注册 launchd）→ 起真实的虚拟机。
import assert from "node:assert/strict";
import { execFileSync, spawnSync } from "node:child_process";
import { appendFileSync, chmodSync, copyFileSync, existsSync, mkdirSync, mkdtempSync, readFileSync, realpathSync, renameSync, writeFileSync } from "node:fs";
import { createServer, type Server } from "node:http";
import { createHash } from "node:crypto";
import { homedir, tmpdir } from "node:os";
import { connect } from "node:net";
import path from "node:path";
import { after, before, test } from "node:test";
import { fileURLToPath } from "node:url";
import { delay, McpClient, waitUntil } from "./support.ts";

const root = fileURLToPath(new URL("../", import.meta.url));
const { version } = JSON.parse(readFileSync(path.join(root, "package.json"), "utf8"));
const tarball = path.join(root, `.pack/napbox-${version}.tgz`);

const scratch = realpathSync(mkdtempSync(path.join(tmpdir(), "nbx-pkg-")));
const home = path.join(scratch, "home");
const support = path.join(scratch, "s");
const uid = process.getuid?.();
const label = `io.github.coffeecoproject.napbox.${createHash("sha256").update(support).digest("hex").slice(0, 8)}`;
const service = `gui/${uid}/${label}`;
let registry: Server;
let env: NodeJS.ProcessEnv;
let client: McpClient;

function gitRepository(name: string, compose?: string): string {
  const directory = path.join(scratch, name);
  mkdirSync(directory, { recursive: true });
  execFileSync("git", ["init", "-q", directory]);
  if (compose) writeFileSync(path.join(directory, "compose.yaml"), compose);
  return directory;
}

/** 假的 registry：napbox 由这里给，别的包转到真的 npm */
function startRegistry(): Promise<string> {
  const data = readFileSync(tarball);
  const shasum = createHash("sha1").update(data).digest("hex");
  return new Promise((resolve) => {
    registry = createServer((request, response) => {
      const address = registry.address() as { port: number };
      if (request.url === "/napbox") {
        const { dependencies, bin, engines, os, cpu } = JSON.parse(
          execFileSync("tar", ["-xOf", tarball, "package/package.json"], { encoding: "utf8" }),
        );
        response.setHeader("content-type", "application/json");
        response.end(
          JSON.stringify({
            name: "napbox",
            "dist-tags": { latest: version },
            versions: {
              [version]: {
                name: "napbox", version, dependencies, bin, engines, os, cpu,
                dist: { tarball: `http://127.0.0.1:${address.port}/napbox.tgz`, shasum },
              },
            },
          }),
        );
      } else if (request.url === "/napbox.tgz") {
        response.end(data);
      } else {
        response.writeHead(302, { location: `https://registry.npmjs.org${request.url}` }).end();
      }
    });
    registry.listen(0, "127.0.0.1", () => {
      resolve(`http://127.0.0.1:${(registry.address() as { port: number }).port}/`);
    });
  });
}

/** 运行插件里的钩子脚本，和 Claude Code 一样从标准输入给内容 */
function pluginHook(input: Record<string, unknown>) {
  const run = spawnSync(process.execPath, [path.join(root, "plugins/claude/hooks/napbox.mjs")], {
    input: JSON.stringify(input),
    encoding: "utf8",
    env,
  });
  assert.equal(run.status, 0, run.stderr);
  return run.stdout ? JSON.parse(run.stdout).hookSpecificOutput : undefined;
}

/** 从宿主机连端口，读到对方发的内容（busybox nc 发完就关） */
function readPort(port: number): Promise<string> {
  return new Promise((resolve, reject) => {
    const socket = connect(port, "127.0.0.1");
    let text = "";
    socket.setEncoding("utf8");
    socket.on("data", (chunk) => (text += chunk));
    socket.on("close", () => resolve(text));
    socket.on("error", reject);
    socket.setTimeout(30_000, () => socket.destroy(new Error("读端口超时")));
  });
}

const launchPrint = () =>
  spawnSync("launchctl", ["print", service], { encoding: "utf8" });

const COMPOSE = `services:
  web:
    image: busybox:1.37
    command: ["sh", "-c", "echo started-web; while true; do echo hello-from-web | nc -l -p 8080; done"]
    ports: ["8080:8080"]
    volumes: ["data:/data"]
volumes:
  data:
`;

before(async () => {
  assert.ok(existsSync(tarball), `没有 ${tarball}：从 scripts/test-package.sh 运行`);
  mkdirSync(home);
  mkdirSync(support);
  const given = process.env.NAPBOX_TEST_KERNEL;
  if (given) {
    mkdirSync(path.join(support, "kernel"));
    copyFileSync(given, path.join(support, "kernel", path.basename(given)));
  }
  const givenRunc = process.env.NAPBOX_TEST_RUNC;
  if (givenRunc) {
    mkdirSync(path.join(support, "runc"));
    copyFileSync(givenRunc, path.join(support, "runc", path.basename(givenRunc)));
    chmodSync(path.join(support, "runc", path.basename(givenRunc)), 0o755);
  }
  const registryUrl = await startRegistry();
  const { NAPBOX_BIN: _ignored, ...inherited } = process.env;
  env = {
    ...inherited,
    HOME: home,
    NAPBOX_SUPPORT_DIR: support,
    npm_config_registry: registryUrl,
    npm_config_cache: path.join(scratch, "npm-cache"),
  };
});

after(async () => {
  await client?.close();
  spawnSync("launchctl", ["bootout", service]);
  registry?.close();
  // 留在废纸篓的子文件夹里，不直接删
  const trash = path.join(homedir(), ".Trash/napbox-test-leftovers");
  mkdirSync(trash, { recursive: true });
  renameSync(scratch, path.join(trash, path.basename(scratch)));
});

test("插件的启动脚本从 registry 安装固定版本，启动 MCP 服务", async () => {
  client = new McpClient(process.execPath, [path.join(root, "plugins/claude/server.mjs")], { cwd: scratch, env });
  const { result } = await client.initialize();
  assert.equal((result?.serverInfo as { version: string }).version, version, client.stderr.join(""));
  const installed = path.join(home, "Library/Caches/napbox/versions", version, "node_modules/napbox");
  assert.ok(existsSync(path.join(installed, "dist/cli.js")));
  assert.ok(existsSync(path.join(installed, "native/napboxd")));
  assert.ok(existsSync(path.join(installed, "node_modules/zod")) || existsSync(path.join(installed, "../zod")));
  // 包里的 napboxd 签名和权限还在：npm 打包、解开后不能丢
  const signature = spawnSync("codesign", ["-d", "--entitlements", "-", path.join(installed, "native/napboxd")], { encoding: "utf8" });
  assert.ok(`${signature.stdout}${signature.stderr}`.includes("com.apple.security.virtualization"));
});

test("还没准备时，工具报 daemon_unavailable 并说明要 setup", async () => {
  const { value, isError } = await client.tool("status");
  assert.equal(isError, true);
  assert.equal(value.error.code, "daemon_unavailable");
  assert.ok(value.error.message.includes("setup"));
});

test("setup 工具：下载内核和 runc、拉 vminit、注册 launchd 并启动 napboxd", { timeout: 1_800_000 }, async () => {
  const { value, isError } = await client.tool("setup");
  assert.equal(isError, false, JSON.stringify(value));
  assert.equal(value.daemon, "started");
  assert.equal(value.daemonVersion, version);
  // 程序在固定位置，不在缓存目录
  const daemon = path.join(support, "daemon", version, "napboxd");
  const command = execFileSync("ps", ["-o", "command=", "-p", String(value.pid)], { encoding: "utf8" });
  assert.equal(command.trim(), daemon);
  assert.ok(existsSync(path.join(support, "daemon", version, "napbox-guard")));
  // 内核是非 debug 版，vmlinux 指向它
  assert.equal(execFileSync("readlink", [path.join(support, "kernel/vmlinux")], { encoding: "utf8" }).trim(), "vmlinux-6.18.35-197");
  const kernel = readFileSync(path.join(support, "kernel/vmlinux"));
  assert.ok(kernel.length > 15_000_000 && kernel.length < 25_000_000, `内核大小 ${kernel.length}`);
  // runc 也下载好了（虚拟机里用它启动容器）
  const runc = readFileSync(path.join(support, "runc/runc-1.5.1"));
  assert.ok(runc.length > 5_000_000 && runc.subarray(0, 4).equals(Buffer.from("\x7fELF", "latin1")), `runc 大小 ${runc.length}`);
  // launchd 管着它，进程类型是 Interactive，不被限速
  const printed = launchPrint();
  assert.equal(printed.status, 0, printed.stderr);
  assert.ok(printed.stdout.includes(`pid = ${value.pid}`), printed.stdout);
  const priority = Number(execFileSync("ps", ["-o", "pri=", "-p", String(value.pid)], { encoding: "utf8" }));
  assert.ok(priority >= 20, `优先级 ${priority}`);
});

test("再次 setup 不重做", async () => {
  const before = (await client.tool("status")).value.pid;
  const started = Date.now();
  const { value } = await client.tool("setup");
  assert.equal(value.daemon, "unchanged");
  assert.equal(value.pid, before);
  assert.ok(Date.now() - started < 20_000, "不该重新下载");
});

let web: { hostPort: number; variable: string };
let project: string;

test("up 起真实环境，端口能连，env、exec、logs、reset 都能用", { timeout: 600_000 }, async () => {
  project = gitRepository("project", COMPOSE);
  const up = await client.tool("up", { directory: project });
  assert.equal(up.isError, false, JSON.stringify(up.value));
  assert.equal(up.value.state, "running");
  web = up.value.ports[0];
  assert.equal(web.variable, "NAPBOX_WEB_8080");
  assert.ok((await readPort(web.hostPort)).includes("hello-from-web"));

  const info = await client.tool("env", { directory: project });
  assert.equal(info.value.variables.NAPBOX_WEB_8080, `127.0.0.1:${web.hostPort}`);

  const exec = await client.tool("exec", { directory: project, service: "web", command: ["sh", "-c", "cat; echo err >&2; exit 3"], stdin: "from-stdin" });
  assert.equal(exec.value.exitCode, 3);
  assert.equal(exec.value.stdout, "from-stdin");
  assert.equal(exec.value.stderr, "err\n");

  const big = await client.tool("exec", { directory: project, service: "web", command: ["sh", "-c", "head -c 200000 /dev/zero | tr '\\0' x; echo END"] });
  assert.ok(big.value.stdout.endsWith("END\n"));
  assert.equal(big.value.stdout.length, 48 * 1024);
  assert.equal(big.value.droppedBytes.stdout, 200004 - 48 * 1024);

  const timedOut = await client.tool("exec", { directory: project, service: "web", command: ["sh", "-c", "echo begun; sleep 60"], timeoutSeconds: 2 });
  assert.equal(timedOut.isError, true);
  assert.equal(timedOut.value.timedOut, true);
  assert.equal(timedOut.value.stdout, "begun\n");

  const logs = await client.tool("logs", { directory: project, service: "web", tail: 5 });
  assert.ok(logs.value.logs.includes("started-web"));

  await client.tool("exec", { directory: project, service: "web", command: ["sh", "-c", "echo keep > /data/f"] });
  const reset = await client.tool("reset", { directory: project, volumes: ["data"] });
  assert.equal(reset.isError, false, JSON.stringify(reset.value));
  const after = await client.tool("exec", { directory: project, service: "web", command: ["sh", "-c", "ls /data/f 2>&1 || true"] });
  assert.ok(after.value.stdout.includes("No such file"));
});

test("插件的钩子：会话开始和压缩后说端口；compose up 被拦；同仓库的另一个 worktree 也算已接入", () => {
  for (const source of ["startup", "compact"]) {
    const note = pluginHook({ hook_event_name: "SessionStart", source, cwd: project });
    assert.ok(note.additionalContext.includes(`127.0.0.1:${web.hostPort}`), note.additionalContext);
    assert.ok(note.additionalContext.includes("NAPBOX_WEB_8080"));
    assert.ok(note.additionalContext.includes("running"));
  }
  const bash = (cwd: string, command = "docker compose up -d") => ({ hook_event_name: "PreToolUse", tool_name: "Bash", tool_input: { command }, cwd });
  assert.equal(pluginHook(bash(project)).permissionDecision, "deny");
  assert.equal(pluginHook(bash(project, "npm test")), undefined);
  execFileSync("git", ["-C", project, "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "--allow-empty", "-m", "x"]);
  const linked = path.join(scratch, "linked");
  execFileSync("git", ["-C", project, "worktree", "add", "-q", linked]);
  assert.equal(pluginHook(bash(linked)).permissionDecision, "deny");
  assert.equal(pluginHook({ hook_event_name: "SessionStart", cwd: linked }), undefined);
  const other = gitRepository("unrelated", COMPOSE);
  assert.equal(pluginHook(bash(other)), undefined);
});

test("有环境在运行时也直接换版本，换完连接进来自动恢复", { timeout: 300_000 }, async () => {
  assert.equal((await client.tool("env", { directory: project })).value.state, "running", "前提：环境在运行");
  const before = (await client.tool("status")).value.pid;
  // 模拟装好的程序和包里的不同
  appendFileSync(path.join(support, "daemon", version, "napboxd"), "x");
  const { value, isError } = await client.tool("setup");
  assert.equal(isError, false, JSON.stringify(value));
  assert.equal(value.daemon, "restarted");
  assert.notEqual(value.pid, before);
  assert.ok((await readPort(web.hostPort)).includes("hello-from-web"), "端口保留，连接进来自动唤醒");
  assert.equal(readFileSync(path.join(support, "daemon", version, "napboxd")).at(-1) === "x".charCodeAt(0), false);
});

test("没有环境在运行时直接换版本", { timeout: 120_000 }, async () => {
  await client.tool("sleep", { directory: project });
  const before = (await client.tool("status")).value.pid;
  appendFileSync(path.join(support, "daemon", version, "napboxd"), "x");
  const { value } = await client.tool("setup");
  assert.equal(value.daemon, "restarted", JSON.stringify(value));
  assert.notEqual(value.pid, before);
});

// 0.1.3 的 setup 先问正在运行的 napboxd 有没有环境在运行，0.1.2 的回应缺字段，报 protocol_error，升不上来。
// 这里用一个只会给看不懂回应的程序顶替登录项，当作旧版。
test("登录项是看不懂的旧版 napboxd 时照样换", { timeout: 300_000 }, async () => {
  assert.equal(spawnSync("launchctl", ["bootout", service]).status, 0);
  await waitUntil("napboxd 退出", async () => (await client.tool("status")).value.error?.code === "daemon_unavailable", 150_000);

  const socketPath = path.join(support, "napboxd.sock");
  const old = path.join(scratch, "old-napboxd.mjs");
  writeFileSync(
    old,
    `import { createServer } from "node:net";
import { rmSync } from "node:fs";
rmSync(${JSON.stringify(socketPath)}, { force: true });
createServer((socket) => socket.on("data", () => socket.write('{"id":1,"result":{"version":"0.0.1"}}\\n'))).listen(${JSON.stringify(socketPath)});
process.on("SIGTERM", () => process.exit(0));
`,
  );
  const plist = path.join(home, "Library/LaunchAgents", `${label}.plist`);
  writeFileSync(
    plist,
    `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>${label}</string>
  <key>ProgramArguments</key>
  <array>
    <string>${process.execPath}</string>
    <string>${old}</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
</dict>
</plist>
`,
  );
  mkdirSync(path.join(support, "daemon", "0.0.1"));
  const registered = spawnSync("launchctl", ["bootstrap", `gui/${uid}`, plist], { encoding: "utf8" });
  assert.equal(registered.status, 0, registered.stderr);
  await waitUntil("旧版顶上来", async () => (await client.tool("status")).value.error?.code === "protocol_error");

  const { value, isError } = await client.tool("setup");
  assert.equal(isError, false, JSON.stringify(value));
  assert.equal(value.daemon, "restarted");
  assert.equal(value.daemonVersion, version);
  const command = execFileSync("ps", ["-o", "command=", "-p", String(value.pid)], { encoding: "utf8" });
  assert.equal(command.trim(), path.join(support, "daemon", version, "napboxd"));
  assert.equal(existsSync(path.join(support, "daemon", "0.0.1")), false, "旧版本的目录删掉");
  assert.ok((await readPort(web.hostPort)).includes("hello-from-web"), "环境还在，连接进来自动唤醒");
});

test("napboxd 崩溃后 launchd 把它拉起来，环境还能用", { timeout: 180_000 }, async () => {
  assert.ok((await readPort(web.hostPort)).includes("hello-from-web"));
  const before = (await client.tool("status")).value.pid;
  process.kill(before, "SIGKILL");
  await waitUntil("launchd 拉起 napboxd", async () => {
    const { value, isError } = await client.tool("status");
    return !isError && value.pid !== before;
  }, 60_000);
  await delay(1000);
  assert.ok((await readPort(web.hostPort)).includes("hello-from-web"));
});

test("napboxd 正常退出、登录项还在时，setup 把它拉起来", { timeout: 180_000 }, async () => {
  const before = (await client.tool("status")).value.pid;
  process.kill(before, "SIGTERM");
  await waitUntil("napboxd 退出", async () => (await client.tool("status")).value.error?.code === "daemon_unavailable", 150_000);
  await delay(12_000); // 超过 launchd 默认的 10 秒重启间隔：正常退出不该被拉起
  assert.equal((await client.tool("status")).value.error?.code, "daemon_unavailable");
  assert.equal(launchPrint().status, 0, "登录项还注册着");
  const { value, isError } = await client.tool("setup");
  assert.equal(isError, false, JSON.stringify(value));
  assert.equal(value.daemon, "restarted");
  assert.notEqual(value.pid, before);
  assert.ok((await readPort(web.hostPort)).includes("hello-from-web"));
});

test("正常退出（bootout）后不再拉起；down 回收环境", { timeout: 120_000 }, async () => {
  const down = await client.tool("down", { directory: project });
  assert.equal(down.isError, false, JSON.stringify(down.value));
  assert.equal((await client.tool("env", { directory: project })).value.error.code, "environment_not_found");
  assert.equal(spawnSync("launchctl", ["bootout", service]).status, 0);
  await delay(12_000); // 超过 launchd 默认的 10 秒重启间隔
  assert.equal((await client.tool("status")).value.error.code, "daemon_unavailable");
  assert.notEqual(launchPrint().status, 0);
});
