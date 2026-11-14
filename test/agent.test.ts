// MCP 服务和钩子，走真实的 napboxd（不起虚拟机）和真实的命令入口。有环境时的行为在 test/package.test.ts。
import assert from "node:assert/strict";
import { execFileSync, spawnSync } from "node:child_process";
import { mkdirSync, mkdtempSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { readFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import { after, before, type TestContext, test } from "node:test";
import { fileURLToPath } from "node:url";
import { generatedFiles } from "../scripts/plugins.ts";
import { describeEnvironment } from "../src/agent/hooks.ts";
import { type Daemon, McpClient, startDaemon } from "./support.ts";

const root = fileURLToPath(new URL("../", import.meta.url));
const cli = path.join(root, "src/cli.ts");
const scratch = realpathSync(mkdtempSync(path.join(tmpdir(), "nbx-agent-")));
const support = path.join(scratch, "s");
const noDaemon = path.join(scratch, "none");
const env = { ...process.env, NAPBOX_SUPPORT_DIR: support };
let daemon: Daemon;

function gitRepository(name: string): string {
  const directory = path.join(scratch, name);
  mkdirSync(directory, { recursive: true });
  execFileSync("git", ["init", "-q", directory]);
  return directory;
}

function hook(input: Record<string, unknown>, supportDir = support) {
  const run = spawnSync(process.execPath, [cli, "hook"], {
    input: JSON.stringify(input),
    encoding: "utf8",
    env: { ...process.env, NAPBOX_SUPPORT_DIR: supportDir },
  });
  assert.equal(run.status, 0, run.stderr);
  return run.stdout ? JSON.parse(run.stdout).hookSpecificOutput : undefined;
}

const bash = (command: string, cwd: string) => ({
  hook_event_name: "PreToolUse",
  tool_name: "Bash",
  tool_input: { command },
  cwd,
});

/** 开一个 MCP 服务进程，这条测试结束时关掉。断言失败也要关：它活着的话整组测试不会结束，结果也出不来 */
function mcp(t: TestContext, cwd: string, supportDir = support): McpClient {
  const client = new McpClient(process.execPath, [cli, "mcp"], {
    cwd,
    env: { ...process.env, NAPBOX_SUPPORT_DIR: supportDir },
  });
  t.after(() => client.close());
  return client;
}

before(async () => {
  mkdirSync(support);
  daemon = await startDaemon(support, path.join(scratch, "napboxd.log"));
});

after(async () => {
  await daemon.stop("SIGTERM");
  rmSync(scratch, { recursive: true, force: true });
});

test("MCP：初始化、工具列表和每个工具的输入说明", async (t) => {
  const client = mcp(t, scratch);
  const { result } = await client.initialize();
  assert.equal((result?.serverInfo as { name: string }).name, "napbox");
  assert.deepEqual(result?.capabilities, { tools: { listChanged: false } });
  assert.ok(String(result?.instructions).includes("docker compose up"));
  const list = await client.request("tools/list");
  const tools = list.result?.tools as {
    name: string;
    description: string;
    inputSchema: { type: string; properties: Record<string, unknown> };
    annotations: { destructiveHint: boolean; readOnlyHint: boolean };
  }[];
  assert.deepEqual(tools.map((tool) => tool.name).sort(), [
    "down", "egress", "env", "exec", "logs", "reset", "run", "setup", "sleep", "status", "up",
  ]);
  for (const tool of tools) {
    assert.equal(tool.inputSchema.type, "object", tool.name);
    assert.ok(tool.description.length > 10, tool.name);
  }
  const named = (name: string) => tools.find((tool) => tool.name === name);
  assert.ok(named("exec")?.inputSchema.properties.timeoutSeconds);
  assert.ok(named("run")?.inputSchema.properties.timeoutSeconds);
  // 临时环境：这六个工具能指定，sleep、reset 没有（napboxd 对临时环境不提供），run 的名字是 napbox 自己起的
  const takesTemp = tools.filter((tool) => "temp" in tool.inputSchema.properties).map((tool) => tool.name);
  assert.deepEqual(takesTemp.sort(), ["down", "egress", "env", "exec", "logs", "up"]);
  assert.equal(named("status")?.annotations.readOnlyHint, true);
  assert.equal(named("down")?.annotations.destructiveHint, true);
  assert.equal((await client.request("ping")).error, undefined);
  assert.equal((await client.request("nonsense")).error?.code, -32601);
});

test("MCP：调用真实的 napboxd，错误和命令行格式一样", async (t) => {
  const repository = gitRepository("mcp-repo");
  const client = mcp(t, repository);
  await client.initialize();
  const status = await client.tool("status");
  assert.equal(status.isError, false);
  assert.equal(status.value.pid, daemon.process.pid);
  const env = await client.tool("env");
  assert.equal(env.isError, true);
  assert.equal(env.value.error.code, "environment_not_found");
  const up = await client.tool("up");
  assert.equal(up.isError, true);
  assert.equal(up.value.error.code, "compose_not_found");
  const outside = await client.tool("env", { directory: scratch });
  assert.equal(outside.value.error.code, "not_in_repository");
  const unknown = await client.tool("nonsense");
  assert.equal(unknown.value.error.code, "usage_error");
  const badArgument = await client.tool("exec", { service: "a", command: [] });
  assert.equal(badArgument.isError, true);
  assert.equal(badArgument.value.error.code, "usage_error");
  const extra = await client.tool("env", { dirctory: "/typo" });
  assert.equal(extra.value.error.code, "usage_error");
  // temp 传到了 napboxd：找的是那个临时环境。名字写得对不对只有 up 查，别的就是找不到
  for (const [name, args] of [
    ["env", {}],
    ["down", {}],
    ["egress", { mode: "none" }],
    ["logs", { service: "a" }],
    ["exec", { service: "a", command: ["true"] }],
  ] as const) {
    const missing = await client.tool(name, { ...args, temp: "t1" });
    assert.equal(missing.value.error.code, "environment_not_found", name);
    assert.ok(missing.value.error.message.includes("t1"), `${name}：${missing.value.error.message}`);
  }
  assert.equal((await client.tool("up", { temp: "A/b" })).value.error.code, "bad_request");
  assert.equal((await client.tool("sleep", { temp: "t1" })).value.error.code, "usage_error");
  const run = await client.tool("run", { service: "a" });
  assert.equal(run.isError, true);
  assert.equal(run.value.error.code, "compose_not_found");
  assert.equal((await client.tool("run", { service: "a", command: [] })).value.error.code, "usage_error");
});

test("MCP：客户端列出 roots 时，以第一个 root 为会话目录（桌面版在主 checkout 启动服务）", async (t) => {
  const started = gitRepository("mcp-started");
  const working = gitRepository("mcp-working");
  writeFileSync(path.join(working, "compose.yaml"), "services:\n  a:\n    bad: 1\n");
  const client = mcp(t, started);
  client.roots = [working];
  await client.initialize();
  // 不写 directory：在 working 里找到坏的 compose，而不是 started 里找不到 compose
  const up = await client.tool("up");
  assert.notEqual(up.value.error.code, "compose_not_found");
  assert.ok(up.value.error.message.includes("bad") || up.value.error.code === "compose_invalid", up.value.error.message);
  // 写了 directory 就用它
  const there = await client.tool("up", { directory: started });
  assert.equal(there.value.error.code, "compose_not_found");
});

test("MCP：napboxd 没运行时说明要调用 setup，并提到下载和登录项", async (t) => {
  const client = mcp(t, scratch, noDaemon);
  await client.initialize();
  const status = await client.tool("status");
  assert.equal(status.isError, true);
  assert.equal(status.value.error.code, "daemon_unavailable");
  assert.ok(status.value.error.message.includes("setup"));
  assert.ok(status.value.error.message.includes("700MB"));
});

test("钩子：没接入的项目不拦 docker compose up", () => {
  const repository = gitRepository("not-onboarded");
  assert.equal(hook(bash("docker compose up -d", repository)), undefined);
  assert.equal(hook(bash("postgres -D data", repository)), undefined);
  assert.equal(hook(bash("docker run -d postgres", repository)), undefined);
  assert.equal(hook(bash("docker compose up", scratch)), undefined); // 不在 git 仓库里
  assert.equal(hook({ hook_event_name: "SessionStart", source: "startup", cwd: repository }), undefined);
});

test("钩子：有 .napbox.yaml 的项目拦下 compose up/start/run，别的命令不受影响", () => {
  const repository = gitRepository("onboarded");
  mkdirSync(path.join(repository, "server"));
  writeFileSync(path.join(repository, ".napbox.yaml"), "compose: server/compose.yaml\n");
  for (const command of [
    "docker compose up -d",
    "docker-compose start",
    "docker compose run api sh",
    "npm i && bash -c 'docker compose up'",
  ]) {
    const output = hook(bash(command, repository));
    assert.equal(output?.permissionDecision, "deny", command);
    assert.ok(output.permissionDecisionReason.includes("up 工具"), command);
    // 只有 compose run 才指向 run 工具
    assert.equal(output.permissionDecisionReason.includes("run 工具"), command.includes("compose run"), command);
  }
  // 从子目录也算
  assert.equal(hook(bash("docker compose up", path.join(repository, "server")))?.permissionDecision, "deny");
  for (const command of [
    "docker compose ps",
    "docker compose logs api",
    "docker compose down",
    "docker ps",
    "docker run --help",
    'git commit -m "docker compose up"',
    'git commit -m "docker run postgres"',
    "npm test",
  ]) {
    assert.equal(hook(bash(command, repository)), undefined, command);
  }
  // 别的工具不看
  assert.equal(
    hook({ hook_event_name: "PreToolUse", tool_name: "Read", tool_input: { command: "docker compose up" }, cwd: repository }),
    undefined,
  );
});

test("钩子：cd 到别的项目再运行时，按那个项目判断", () => {
  const onboarded = gitRepository("cd-onboarded");
  writeFileSync(path.join(onboarded, ".napbox.yaml"), "compose: compose.yaml\n");
  const other = gitRepository("cd-other");
  assert.equal(hook(bash(`cd ${other} && docker compose up`, onboarded)), undefined);
  assert.equal(hook(bash("cd ../cd-onboarded && docker compose up", other))?.permissionDecision, "deny");
});

test("钩子：自己起服务、docker run 只提醒，不拦；提醒里有临时环境", () => {
  const repository = gitRepository("remind");
  writeFileSync(path.join(repository, ".napbox.yaml"), "compose: compose.yaml\n");
  const output = hook(bash("redis-server --port 6380", repository));
  assert.equal(output?.permissionDecision, undefined);
  assert.ok(output?.additionalContext.includes("redis-server"));
  assert.ok(output.additionalContext.includes("传 temp"));
  assert.equal(hook(bash("redis-cli ping", repository)), undefined);

  const dockerRun = hook(bash("docker run -d --rm -p 5432 postgres:17", repository));
  assert.equal(dockerRun?.permissionDecision, undefined);
  assert.ok(dockerRun?.additionalContext.includes("docker run"));
  assert.ok(dockerRun.additionalContext.includes("传 temp"));
  assert.ok(dockerRun.additionalContext.includes("run 工具"));
  // 同一件事的另一种写法，提醒一样
  assert.deepEqual(hook(bash("docker container run -d redis", repository)), dockerRun);
  assert.equal(hook(bash("docker container ls", repository)), undefined);
  // 同一条命令里有要拦的：拦
  assert.equal(hook(bash("docker run alpine true && docker compose up", repository))?.permissionDecision, "deny");
});

test("钩子：napboxd 没运行时，有 .napbox.yaml 的项目照样拦，并在会话开始时提示", () => {
  const repository = gitRepository("no-daemon");
  writeFileSync(path.join(repository, ".napbox.yaml"), "compose: compose.yaml\n");
  assert.equal(hook(bash("docker compose up", repository), noDaemon)?.permissionDecision, "deny");
  const note = hook({ hook_event_name: "SessionStart", cwd: repository }, noDaemon);
  assert.ok(note?.additionalContext.includes("setup"));
  const plain = gitRepository("no-daemon-plain");
  assert.equal(hook(bash("docker compose up", plain), noDaemon), undefined);
  assert.equal(hook({ hook_event_name: "SessionStart", cwd: plain }, noDaemon), undefined);
});

test("会话开始的说明：服务的端口和本机程序用的端口都列出来", () => {
  const note = describeEnvironment({
    name: "demo/main",
    state: "sleeping",
    worktree: "/demo",
    ports: [{ service: "db", containerPort: 5432, hostPort: 41001, variable: "NAPBOX_DB_5432" }],
    hostPorts: [{ name: "server", hostPort: 41002, variable: "NAPBOX_HOST_SERVER" }],
    egress: "open",
    variables: { NAPBOX_DB_5432: "127.0.0.1:41001", NAPBOX_HOST_SERVER: "41002" },
    unsetVariables: [],
    serviceExits: [],
  });
  assert.ok(note.includes("db:5432 → 127.0.0.1:41001（变量 NAPBOX_DB_5432）"));
  assert.ok(note.includes("server → 端口 41002（变量 NAPBOX_HOST_SERVER"));
});

test("命令入口：别的命令交给原生命令行，退出码和输出都是它的", () => {
  const run = spawnSync(process.execPath, [cli, "status", "--text"], { encoding: "utf8", env });
  assert.equal(run.status, 0, run.stderr);
  assert.ok(run.stdout.includes("napboxd"));
  const failed = spawnSync(process.execPath, [cli, "env"], { encoding: "utf8", env, cwd: scratch });
  assert.equal(failed.status, 1);
  assert.ok(failed.stderr.includes("not_in_repository"));
  const exitCode = spawnSync(process.execPath, [cli, "setup", "nonsense"], { encoding: "utf8", env });
  assert.equal(exitCode.status, 1);
  assert.equal(JSON.parse(exitCode.stdout).error.code, "usage_error");
});

test("生成的插件文件是最新的，版本和 Swift、package.json 一致", async () => {
  const { version } = JSON.parse(await readFile(path.join(root, "package.json"), "utf8"));
  const swift = await readFile(path.join(root, "native/Sources/NapboxProtocol/Protocol.swift"), "utf8");
  assert.equal(/static let current = "([^"]+)"/.exec(swift)?.[1], version);
  for (const [name, expected] of Object.entries(await generatedFiles(version))) {
    assert.equal(await readFile(path.join(root, name), "utf8"), expected, `${name} 过期了：运行 node scripts/plugins.ts`);
  }
});
