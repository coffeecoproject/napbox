// 临时环境（napbox up --temp）和 napbox run：真的起虚拟机，命令行、客户端和 MCP 工具都走一遍。
// 用临时的 NAPBOX_SUPPORT_DIR，镜像库、内核和 runc 链接到正在用的目录（只读着用）。从 scripts/test-client.sh temp 运行。
import assert from "node:assert/strict";
import { execFileSync, spawn } from "node:child_process";
import { randomBytes } from "node:crypto";
import {
  existsSync,
  mkdirSync,
  mkdtempSync,
  readdirSync,
  readFileSync,
  realpathSync,
  rmSync,
  symlinkSync,
  writeFileSync,
} from "node:fs";
import { connect } from "node:net";
import { tmpdir } from "node:os";
import path from "node:path";
import { setTimeout as delay } from "node:timers/promises";
import { after, afterEach, before, describe, test } from "node:test";
import { fileURLToPath } from "node:url";
import type { NapboxClient } from "../src/client.ts";
import { type EnvironmentEvent, EnvironmentInfo, methods } from "../src/protocol.ts";
import { type Daemon, McpClient, rawCall, rejectsWithCode, startDaemon, waitUntil } from "./support.ts";

const real = process.env.NAPBOX_REAL_SUPPORT_DIR;
const bin = process.env.NAPBOX_BIN;
if (!real || !bin) throw new Error("要用 scripts/test-client.sh temp 运行");

const work = realpathSync(mkdtempSync(path.join(tmpdir(), "nbx-temp-")));
const support = path.join(work, "support");
mkdirSync(support);
symlinkSync(path.join(real, "images"), path.join(support, "images"));
symlinkSync(path.join(real, "kernel"), path.join(support, "kernel"));
symlinkSync(path.join(real, "runc"), path.join(support, "runc"));
const log = path.join(work, "napboxd.log");

// db：有端口、有数据卷，连上就回一行。check：只在 napbox run 时跑的检查（profile 没启用时不起）；
// 它写了端口和 restart: always，run 时都不该生效（否则会等不到端口、退出后被重启）
const COMPOSE = `services:
  db:
    image: alpine:3.20
    command: ["sh", "-c", "while true; do echo from-db | nc -l -p 5432; done"]
    ports: ["5432"]
    volumes: ["data:/data"]
    stop_grace_period: 1s
  check:
    image: alpine:3.20
    profiles: [test]
    depends_on: [db]
    ports: ["9000"]
    restart: always
    command: ["sh", "-c", "echo out; echo err >&2; exit 3"]
    stop_grace_period: 1s
volumes:
  data:
`;

const SICK = `  sick:
    image: alpine:3.20
    command: ["sleep", "100000"]
    healthcheck: {test: ["CMD", "false"], interval: 1s, retries: 2}
    stop_grace_period: 1s
`;

function repo(relative: string, compose: string): string {
  const dir = path.join(work, relative);
  mkdirSync(dir, { recursive: true });
  execFileSync("git", ["init", "-q", dir]);
  writeFileSync(path.join(dir, "compose.yaml"), compose);
  return dir;
}

interface CliResult {
  code: number | null;
  stdout: Buffer;
  stderr: Buffer;
  seconds: number;
}

/** 起命令行，不等它结束。不给 input 时标准输入是 /dev/null（不是终端，命令行照样会转，一读就结束） */
function startCli(cwd: string, args: string[], input?: Buffer | string) {
  const started = Date.now();
  const child = spawn(path.join(bin as string, "napbox"), args, {
    cwd,
    env: { ...process.env, NAPBOX_SUPPORT_DIR: support },
    stdio: [input === undefined ? "ignore" : "pipe", "pipe", "pipe"],
  });
  const stdout: Buffer[] = [];
  const stderr: Buffer[] = [];
  child.stdout?.on("data", (chunk: Buffer) => stdout.push(chunk));
  child.stderr?.on("data", (chunk: Buffer) => stderr.push(chunk));
  if (input !== undefined) child.stdin?.end(input);
  const done = new Promise<CliResult>((resolve, reject) => {
    child.once("error", reject);
    child.once("close", (code) =>
      resolve({
        code,
        stdout: Buffer.concat(stdout),
        stderr: Buffer.concat(stderr),
        seconds: (Date.now() - started) / 1000,
      }),
    );
  });
  return { child, done };
}

const cli = (cwd: string, args: string[], input?: Buffer | string) => startCli(cwd, args, input).done;

/** 连宿主机上的端口说一句话再挂断。db 服务的 nc 把收到的话打到标准输出，所以这句话会进这个环境的日志 */
function tell(port: number, words: string): Promise<void> {
  return new Promise((resolve, reject) => {
    const socket = connect(port, "127.0.0.1");
    socket.setTimeout(10_000, () => socket.destroy(new Error(`对 ${port} 说话超时`)));
    socket.once("error", reject);
    socket.once("close", () => resolve());
    socket.resume();
    socket.end(`${words}\n`);
  });
}

/** 连宿主机上的端口，返回对方回的第一段话；连不上返回 undefined */
function ask(port: number): Promise<string | undefined> {
  return new Promise((resolve) => {
    const socket = connect(port, "127.0.0.1");
    socket.setEncoding("utf8");
    socket.setTimeout(10_000, () => {
      socket.destroy();
      resolve(undefined);
    });
    socket.once("data", (data) => {
      socket.destroy();
      resolve((data as unknown as string).trim());
    });
    socket.once("error", () => resolve(undefined));
    socket.once("end", () => resolve(undefined));
  });
}

/** 环境的数据目录有几个（每个登记过的环境一个） */
function environmentDirectories(): number {
  const dir = path.join(support, "environments");
  return existsSync(dir) ? readdirSync(dir).length : 0;
}

/** 回收后保留 7 天的数据有几份 */
function recycledEntries(): number {
  const dir = path.join(support, "recycled");
  return existsSync(dir) ? readdirSync(dir).length : 0;
}

let failed = false;
afterEach((t) => {
  if (t.passed === false) failed = true;
});
after(() => {
  if (failed) {
    console.log(`有失败，测试目录留着：${work}\nnapboxd 日志：\n${readFileSync(log, "utf8")}`);
  } else {
    rmSync(work, { recursive: true, force: true }); // 链接只删链接本身，不会删到链接指向的镜像库
  }
});

/** 订阅所有事件，收进数组 */
async function collectEvents(client: NapboxClient, events: EnvironmentEvent[]) {
  const stop = new AbortController();
  let subscription: Promise<void> | undefined;
  await new Promise<void>((resolve, reject) => {
    subscription = client.subscribe({
      onSubscribed: () => resolve(),
      onEvent: (event) => {
        events.push(event);
      },
      signal: stop.signal,
    });
    subscription.catch(reject);
  });
  return async () => {
    stop.abort();
    await subscription?.catch(() => {});
  };
}

describe("临时环境", { concurrency: false }, () => {
  let daemon: Daemon;
  let client: NapboxClient;
  const cwd = repo("proj", COMPOSE);
  let dev: EnvironmentInfo;
  let t1: EnvironmentInfo;
  let t2: EnvironmentInfo;
  const portOf = (info: EnvironmentInfo) => info.ports.find((p) => p.service === "db")?.hostPort as number;
  const names = async () => (await client.status()).environments.map((e) => e.name).sort();

  before(async () => {
    daemon = await startDaemon(support, log);
    client = daemon.client;
  });
  after(async () => {
    await daemon.stop("SIGTERM");
  });

  test("up --temp：和开发环境并排，名字是开发环境的名字再加一段，各有各的端口；ports.json 还是开发环境的", async (t) => {
    dev = await client.up({ cwd, environment: {} });
    const portsFile = readFileSync(path.join(cwd, ".napbox/ports.json"), "utf8");

    const up = await cli(cwd, ["up", "--temp", "t1"]);
    assert.equal(up.code, 0, up.stdout.toString());
    t.diagnostic(`开发环境在跑时，napbox up --temp（一个服务）用了 ${up.seconds.toFixed(1)} 秒`);
    t1 = EnvironmentInfo.parse(JSON.parse(up.stdout.toString()));
    t2 = await client.up({ cwd, environment: {}, temp: "t2" });

    assert.equal(t1.name, `${dev.name}/t1`);
    assert.equal(t2.name, `${dev.name}/t2`);
    assert.equal(t1.state, "running");
    assert.deepEqual(t1.ports.map((p) => p.service), ["db"], "没启用的 profile 里的 check 不起");
    assert.equal(new Set([portOf(dev), portOf(t1), portOf(t2)]).size, 3);
    for (const info of [dev, t1, t2]) assert.equal(await ask(portOf(info)), "from-db", info.name);
    assert.deepEqual(await names(), [dev.name, t1.name, t2.name]);
    assert.equal(readFileSync(path.join(cwd, ".napbox/ports.json"), "utf8"), portsFile);

    // 同名再 up：还是那一个
    const again = await client.up({ cwd, environment: {}, temp: "t1" });
    assert.deepEqual(again.ports, t1.ports);
    assert.deepEqual(await names(), [dev.name, t1.name, t2.name]);
    const raw = await rawCall(daemon.socketPath, methods.environment, { target: { cwd, temp: "t1" } });
    assert.deepEqual(EnvironmentInfo.parse(raw.result), raw.result);
  });

  test("exec、env、logs、egress 加 --temp 操作的是临时环境，数据和开发环境分开", async () => {
    const wrote = await cli(cwd, ["exec", "--temp", "t1", "db", "--", "sh", "-c", "echo 在-t1 > /data/who"]);
    assert.equal(wrote.code, 0, wrote.stderr.toString());
    assert.equal((await cli(cwd, ["exec", "--temp", "t1", "db", "--", "cat", "/data/who"])).stdout.toString(), "在-t1\n");
    assert.notEqual((await cli(cwd, ["exec", "db", "--", "cat", "/data/who"])).code, 0, "开发环境的卷里没有这个文件");
    assert.notEqual((await cli(cwd, ["exec", "--temp", "t2", "db", "--", "cat", "/data/who"])).code, 0);

    const env = (await cli(cwd, ["env", "--temp", "t1"])).stdout.toString();
    assert.match(env, new RegExp(`127\\.0\\.0\\.1:${portOf(t1)}\\b`));
    assert.doesNotMatch(env, new RegExp(`:${portOf(dev)}\\b`));
    // 日志：只对 t1 说一句话，只有 t1 的日志里有
    const logs = async (...temp: string[]) => (await cli(cwd, ["logs", ...temp, "db"])).stdout.toString();
    await tell(portOf(t1), "说给-t1");
    await waitUntil("t1 的日志里有这句话", async () => (await logs("--temp", "t1")).includes("说给-t1\n"), 10_000);
    assert.doesNotMatch(await logs(), /说给-t1/);
    assert.doesNotMatch(await logs("--temp", "t2"), /说给-t1/);

    const egress = await cli(cwd, ["egress", "--temp", "t1", "none"]);
    assert.equal(JSON.parse(egress.stdout.toString()).egress, "none");
    assert.equal((await client.environment({ cwd, temp: "t1" })).egress, "none");
    assert.equal((await client.environment({ cwd })).egress, "open");

    await rejectsWithCode(client.environment({ cwd, temp: "nope" }), "environment_not_found");
  });

  test("临时环境没有 sleep、reset；名字写得不对报 bad_request", async () => {
    await rejectsWithCode(client.sleep({ cwd, temp: "t1" }), "bad_request");
    await rejectsWithCode(client.reset({ cwd, temp: "t1" }, ["data"]), "bad_request");
    assert.equal((await client.environment({ cwd, temp: "t1" })).state, "running");
    assert.equal((await cli(cwd, ["exec", "--temp", "t1", "db", "--", "cat", "/data/who"])).stdout.toString(), "在-t1\n");
    for (const temp of ["T1", "a/b", "-x", ""]) {
      await rejectsWithCode(client.up({ cwd, environment: {}, temp }), "bad_request");
    }
    assert.deepEqual(await names(), [dev.name, t1.name, t2.name]);
  });

  test("down --temp：数据直接删掉，不进 recycled；端口放掉；开发环境不受影响", async () => {
    assert.equal(environmentDirectories(), 3);
    const down = await cli(cwd, ["down", "--temp", "t1"]);
    assert.equal(down.code, 0, down.stdout.toString());
    const result = JSON.parse(down.stdout.toString());
    assert.equal(result.name, t1.name);
    // 没启用的 profile 里的 check 也留着一个端口（不转发、不列出），一起放掉
    assert.equal(result.releasedPorts.length, 2);
    assert.equal(result.releasedPorts.includes(portOf(t1)), true);
    assert.equal(result.keptDataAt, undefined);
    assert.equal(environmentDirectories(), 2);
    assert.equal(recycledEntries(), 0);
    assert.equal(await ask(portOf(t1)), undefined);
    await rejectsWithCode(client.environment({ cwd, temp: "t1" }), "environment_not_found");
    assert.deepEqual(await names(), [dev.name, t2.name]);
    assert.equal(await ask(portOf(dev)), "from-db");
    assert.ok(existsSync(path.join(cwd, ".napbox/ports.json")), "开发环境的 ports.json 不跟着删");

    // 同名再起：是全新的，数据是空的
    await client.up({ cwd, environment: {}, temp: "t1" });
    assert.notEqual((await cli(cwd, ["exec", "--temp", "t1", "db", "--", "cat", "/data/who"])).code, 0);
    await client.down({ cwd, temp: "t1" });
    assert.equal(environmentDirectories(), 2);
  });

  test("起不来：报错，不留下登记和数据（普通环境会留着等修好再起）", async () => {
    const broken = repo("broken", `services:\n${SICK}`);
    await rejectsWithCode(client.up({ cwd: broken, environment: {}, temp: "bad" }), "healthcheck_timeout");
    await rejectsWithCode(client.environment({ cwd: broken, temp: "bad" }), "environment_not_found");
    assert.deepEqual(await names(), [dev.name, t2.name]);
    assert.equal(environmentDirectories(), 2);
    assert.equal(recycledEntries(), 0);
  });

  test("只起了临时环境的 worktree：开发环境的名字给它留着，调用方占不了", async () => {
    const solo = repo("solo", COMPOSE);
    const only = await client.up({ cwd: solo, environment: {}, temp: "only" });
    const reserved = only.name.slice(0, -"/only".length);
    await rejectsWithCode(
      client.create({ name: reserved, owner: "codeos", directory: repo("solo-copy", COMPOSE) }),
      "name_taken",
    );
    assert.deepEqual(await names(), [dev.name, t2.name, only.name].sort());
    await client.down({ cwd: solo, temp: "only" });
    assert.deepEqual(await names(), [dev.name, t2.name]);
    assert.equal(environmentDirectories(), 2);
    assert.equal(recycledEntries(), 0);
  });

  test("napboxd 重启：临时环境销毁，开发环境还在", async () => {
    await daemon.stop("SIGTERM");
    daemon = await startDaemon(support, log);
    client = daemon.client;
    await waitUntil("临时环境 t2 销毁", async () => (await names()).length === 1, 30_000);
    assert.deepEqual(await names(), [dev.name]);
    assert.equal((await client.environment({ cwd })).state, "sleeping");
    assert.equal(environmentDirectories(), 1);
    assert.equal(recycledEntries(), 0);
    assert.equal(await ask(portOf(t2)), undefined);
    await client.down({ cwd });
  });
});

describe("napbox run", { concurrency: false }, () => {
  let daemon: Daemon;
  let client: NapboxClient;
  const cwd = repo("runproj", COMPOSE);
  let dev: EnvironmentInfo;
  // 闲置销毁要等 1 分多钟：这一组开头起一个闲置 1 分钟的临时环境，最后一条用例再查，和别的用例同时等。
  // 它在另一个项目里，下面「只剩开发环境」的检查不算它
  const idleEvents: EnvironmentEvent[] = [];
  let stopIdleEvents: () => Promise<void> = async () => {};
  let idle: EnvironmentInfo;
  let idleDirectory = "";
  const names = async () =>
    (await client.status()).environments
      .map((e) => e.name)
      .filter((name) => name !== idle?.name)
      .sort();
  const directories = () => {
    const dir = path.join(support, "environments");
    return existsSync(dir) ? readdirSync(dir) : [];
  };
  // 上一组回收开发环境时留下的那几份不算
  let recycledBefore = 0;
  /** 跑完以后只剩开发环境，临时环境的数据没留下 */
  async function assertOnlyDevLeft() {
    assert.deepEqual(await names(), [dev.name]);
    assert.equal(directories().filter((d) => d !== idleDirectory).length, 1);
    assert.equal(recycledEntries(), recycledBefore);
  }
  const runEnvironment = async () =>
    (await client.status()).environments.find((e) => /\/run-[0-9a-f]{8}$/.test(e.name));
  /** 等 run 的临时环境起好（起的过程中 status 里已经有它，状态还不是 running） */
  async function runningEnvironment() {
    await waitUntil("run 的临时环境起好", async () => (await runEnvironment())?.state === "running", 30_000);
    return runEnvironment();
  }

  before(async () => {
    daemon = await startDaemon(support, log);
    client = daemon.client;
    recycledBefore = recycledEntries();
    stopIdleEvents = await collectEvents(client, idleEvents);
    const existing = directories();
    idle = await client.up({ cwd: repo("idle", `x-napbox: {idle_minutes: 1}\n${COMPOSE}`), environment: {}, temp: "left-behind" });
    idleDirectory = directories().find((d) => !existing.includes(d)) ?? "";
    assert.notEqual(idleDirectory, "", "闲置的临时环境有自己的数据目录");
    dev = await client.up({ cwd, environment: {} });
  });
  after(async () => {
    await stopIdleEvents();
    await client.down({ cwd });
    await daemon.stop("SIGTERM");
  });

  test("跑 compose 里写的命令：标准输出、标准错误分开，退出码原样；跑完环境销毁，开发环境没动", async (t) => {
    const ran = await cli(cwd, ["run", "check"]);
    assert.equal(ran.stdout.toString(), "out\n");
    assert.equal(ran.stderr.toString(), "err\n");
    assert.equal(ran.code, 3);
    t.diagnostic(`napbox run（依赖一个服务，从起到销毁）用了 ${ran.seconds.toFixed(1)} 秒`);
    await assertOnlyDevLeft();
    assert.equal(await ask(dev.ports[0]?.hostPort as number), "from-db");
  });

  test("-- 后面的命令换掉 command；它依赖的服务先起好，用服务名连得上", async () => {
    const ran = await cli(cwd, ["run", "check", "--", "sh", "-c", "grep -c ' db$' /etc/hosts; nc -w 5 db 5432"]);
    assert.equal(ran.stdout.toString(), "1\nfrom-db\n", ran.stderr.toString());
    assert.equal(ran.code, 0);
    await assertOnlyDevLeft();
  });

  test("--no-deps：只起它自己", async (t) => {
    const ran = await cli(cwd, ["run", "--no-deps", "check", "--", "sh", "-c", "grep -c ' db$' /etc/hosts; true"]);
    assert.equal(ran.stdout.toString(), "0\n", ran.stderr.toString());
    assert.equal(ran.code, 0);
    t.diagnostic(`napbox run --no-deps（只有它自己，从起到销毁）用了 ${ran.seconds.toFixed(1)} 秒`);
    await assertOnlyDevLeft();
  });

  test("标准输入转给服务，一个字节不差；输入结束服务也读到结束", async () => {
    const input = randomBytes(300_000);
    const ran = await cli(cwd, ["run", "--no-deps", "check", "--", "cat"], input);
    assert.equal(ran.code, 0, ran.stderr.toString());
    assert.ok(ran.stdout.equals(input), `收到 ${ran.stdout.length} 字节`);
    // 不给输入（/dev/null）：服务一读就是结束，不会卡住
    const empty = await cli(cwd, ["run", "--no-deps", "check", "--", "sh", "-c", "cat; echo 读完了"]);
    assert.equal(empty.stdout.toString(), "读完了\n");
    await assertOnlyDevLeft();
  });

  test("--egress none：一起来就连不出去；不加时同一条命令连得出去", async () => {
    // 和 scripts/test-up.sh 一样拿 1.1.1.1:80 试：要这台电脑能上网
    const probe = ["--no-deps", "check", "--", "sh", "-c", "nc -z -w 3 1.1.1.1 80 && echo 通 || echo 不通"];
    const open = await cli(cwd, ["run", ...probe]);
    assert.deepEqual([open.code, open.stdout.toString()], [0, "通\n"], open.stderr.toString());
    const none = await cli(cwd, ["run", "--egress", "none", ...probe]);
    assert.deepEqual([none.code, none.stdout.toString()], [0, "不通\n"], none.stderr.toString());
    await assertOnlyDevLeft();
  });

  test("运行中 status 里看得到，登记的出网模式是给的那个；命令行被杀掉，环境照样销毁", async () => {
    const running = startCli(cwd, ["run", "--egress", "none", "--no-deps", "check", "--", "sleep", "600"]);
    const info = await runningEnvironment();
    assert.equal(info?.name.startsWith(`${dev.name}/run-`), true);
    assert.equal(info?.state, "running");
    assert.equal(info?.egress, "none");
    assert.deepEqual(info?.ports.map((p) => [p.service, p.containerPort]), [["check", 9000]], "前台的服务照常分配端口");
    running.child.kill("SIGKILL");
    await running.done;
    await waitUntil("run 的临时环境销毁", async () => (await runEnvironment()) === undefined, 30_000);
    await assertOnlyDevLeft();
  });

  test("同一个目录同时跑两个：各跑各的", async () => {
    const [a, b] = await Promise.all([
      cli(cwd, ["run", "--no-deps", "check", "--", "sh", "-c", "sleep 2; echo A; exit 5"]),
      cli(cwd, ["run", "--no-deps", "check", "--", "sh", "-c", "sleep 2; echo B; exit 6"]),
    ]);
    assert.deepEqual([a.stdout.toString(), a.code], ["A\n", 5], a.stderr.toString());
    assert.deepEqual([b.stdout.toString(), b.code], ["B\n", 6], b.stderr.toString());
    await assertOnlyDevLeft();
  });

  test("没有这个服务、依赖的服务起不来：错误写到标准错误，退出码 1，环境没留下", async () => {
    const missing = await cli(cwd, ["run", "nope"]);
    assert.equal(missing.code, 1);
    assert.equal(missing.stdout.length, 0);
    assert.equal(JSON.parse(missing.stderr.toString()).error.code, "compose_invalid");

    const broken = repo(
      "run-broken",
      `services:\n  check:\n    image: alpine:3.20\n    command: ["echo", "不该跑到"]\n    depends_on: {sick: {condition: service_healthy}}\n${SICK}`,
    );
    const ran = await cli(broken, ["run", "check"]);
    assert.equal(ran.code, 1);
    assert.equal(ran.stdout.length, 0);
    assert.equal(JSON.parse(ran.stderr.toString()).error.code, "healthcheck_timeout");
    await assertOnlyDevLeft();
  });

  test("客户端的 run：输出、标准输入、退出码一样；取消后环境销毁", async () => {
    let output = "";
    const { exitCode } = await client.run({
      cwd,
      environment: {},
      service: "check",
      command: ["sh", "-c", "cat; exit 7"],
      noDeps: true,
      stdin: "你好 run",
      onOutput: (o) => {
        output += Buffer.from(o.data).toString();
      },
    });
    assert.equal(exitCode, 7);
    assert.equal(output, "你好 run");
    await assertOnlyDevLeft();

    const cancel = new AbortController();
    const pending = client.run({
      cwd,
      environment: {},
      service: "check",
      command: ["sleep", "600"],
      noDeps: true,
      // 标准输入一直不结束
      stdin: (async function* () {
        await new Promise((resolve) => cancel.signal.addEventListener("abort", resolve));
      })(),
      onOutput: () => {},
      signal: cancel.signal,
    });
    pending.catch(() => {});
    await runningEnvironment();
    cancel.abort(new Error("不等了"));
    await assert.rejects(pending, /不等了/);
    await waitUntil("run 的临时环境销毁", async () => (await runEnvironment()) === undefined, 30_000);
    await assertOnlyDevLeft();
  });

  test("构建期间命令行断开：构建完就停下，不登记、不起环境，构建结果删掉", async () => {
    const slow = repo("run-slow-build", "services:\n  check:\n    build: .\n    command: [\"echo\", \"不该跑到\"]\n");
    writeFileSync(path.join(slow, "Dockerfile"), `FROM alpine:3.20\nRUN echo ${randomBytes(4).toString("hex")} && sleep 15\n`);
    const logs = path.join(support, "builder", "logs");
    const buildLogs = () => (existsSync(logs) ? readdirSync(logs).length : 0);
    const logsBefore = buildLogs();
    const cancel = new AbortController();
    const pending = client.run({ cwd: slow, environment: {}, service: "check", onOutput: () => {}, signal: cancel.signal });
    pending.catch(() => {});
    await waitUntil("开始构建", async () => buildLogs() > logsBefore, 60_000);
    cancel.abort(new Error("不等了"));
    await assert.rejects(pending, /不等了/);
    // 构建还要十几秒：这期间和之后都不该出现这个临时环境
    let seen = false;
    await waitUntil(
      "构建完、构建结果删掉",
      async () => {
        if ((await runEnvironment()) !== undefined) seen = true;
        return buildLogs() === logsBefore;
      },
      180_000,
    );
    assert.equal(seen, false, "断开以后不该再登记、起环境");
    await delay(1_000);
    assert.equal(await runEnvironment(), undefined);
    await assertOnlyDevLeft();
  });

  // 开发环境闲置休眠在 scripts/test-up.sh 的「闲置休眠」里测，这里只看临时环境
  test("闲置到时间：临时环境销毁，不是休眠；数据目录删掉，不进 recycled", async () => {
    await waitUntil(
      "闲置的临时环境销毁",
      async () => !(await client.status()).environments.some((e) => e.name === idle.name),
      150_000,
    );
    const destroyed = await (async () => {
      await waitUntil("destroyed 事件", () => idleEvents.some((e) => e.environment === idle.name && e.type === "destroyed"), 10_000);
      return idleEvents.find((e) => e.environment === idle.name && e.type === "destroyed");
    })();
    assert.match(destroyed?.reason ?? "", /idle/);
    assert.equal(idleEvents.some((e) => e.environment === idle.name && e.type === "slept"), false);
    assert.equal(directories().includes(idleDirectory), false);
    await assertOnlyDevLeft();
  });
});

describe("MCP 工具：临时环境和 run", { concurrency: false }, () => {
  let daemon: Daemon;
  let client: NapboxClient;
  let mcp: McpClient;
  const cwd = repo("mcpproj", COMPOSE);
  let dev: EnvironmentInfo;
  let recycledBefore = 0;
  const names = async () => (await client.status()).environments.map((e) => e.name).sort();
  async function assertOnlyDevLeft() {
    assert.deepEqual(await names(), [dev.name]);
    assert.equal(environmentDirectories(), 1);
    assert.equal(recycledEntries(), recycledBefore);
  }

  before(async () => {
    daemon = await startDaemon(support, log);
    client = daemon.client;
    recycledBefore = recycledEntries();
    mcp = new McpClient(process.execPath, [fileURLToPath(new URL("../src/cli.ts", import.meta.url)), "mcp"], {
      cwd,
      env: { ...process.env, NAPBOX_SUPPORT_DIR: support },
    });
    await mcp.initialize();
    const up = await mcp.tool("up");
    assert.equal(up.isError, false, JSON.stringify(up.value));
    dev = EnvironmentInfo.parse(up.value);
  });
  after(async () => {
    await mcp.close();
    await client.down({ cwd });
    await daemon.stop("SIGTERM");
  });

  test("up 传 temp 起的是临时环境；env、exec、logs、egress 传同一个名字操作的是它；down 传它直接删掉", async () => {
    const up = await mcp.tool("up", { temp: "m1" });
    assert.equal(up.isError, false, JSON.stringify(up.value));
    const m1 = EnvironmentInfo.parse(up.value);
    assert.equal(m1.name, `${dev.name}/m1`);
    assert.equal(m1.state, "running");
    assert.notEqual(m1.ports[0]?.hostPort, dev.ports[0]?.hostPort);
    assert.equal(await ask(m1.ports[0]?.hostPort as number), "from-db");
    assert.deepEqual(await names(), [dev.name, m1.name]);

    const write = { service: "db", command: ["sh", "-c", "echo 在-m1 > /data/who; cat /data/who"] };
    const wrote = await mcp.tool("exec", { ...write, temp: "m1" });
    assert.deepEqual([wrote.value.exitCode, wrote.value.stdout], [0, "在-m1\n"], JSON.stringify(wrote.value));
    const inDev = await mcp.tool("exec", { service: "db", command: ["cat", "/data/who"] });
    assert.notEqual(inDev.value.exitCode, 0, "开发环境的卷里没有这个文件");

    assert.equal((await mcp.tool("env", { temp: "m1" })).value.name, m1.name);
    assert.equal((await mcp.tool("env")).value.name, dev.name);
    // 日志：只对 m1 说一句话，只有 m1 的日志里有
    const logs = async (temp?: string) => (await mcp.tool("logs", { temp, service: "db" })).value.logs as string;
    await tell(m1.ports[0]?.hostPort as number, "说给-m1");
    await waitUntil("m1 的日志里有这句话", async () => (await logs("m1")).includes("说给-m1\n"), 10_000);
    assert.doesNotMatch(await logs(), /说给-m1/);
    assert.equal((await mcp.tool("egress", { temp: "m1", mode: "none" })).value.egress, "none");
    assert.equal((await client.environment({ cwd, temp: "m1" })).egress, "none");
    assert.equal((await client.environment({ cwd })).egress, "open");

    const down = await mcp.tool("down", { temp: "m1" });
    assert.equal(down.isError, false, JSON.stringify(down.value));
    assert.equal(down.value.name, m1.name);
    assert.equal(down.value.keptDataAt, undefined);
    assert.equal((await mcp.tool("env", { temp: "m1" })).value.error.code, "environment_not_found");
    await assertOnlyDevLeft();
    assert.equal(await ask(dev.ports[0]?.hostPort as number), "from-db");
  });

  test("run 工具：退出码原样，标准输出、标准错误分开；服务失败不算工具出错；跑完只剩开发环境", async () => {
    const ran = await mcp.tool("run", { service: "check" });
    assert.equal(ran.isError, false, JSON.stringify(ran.value));
    assert.deepEqual(ran.value, {
      exitCode: 3,
      stdout: "out\n",
      stderr: "err\n",
      droppedBytes: { stdout: 0, stderr: 0 },
    });
    await assertOnlyDevLeft();
  });

  test("run 工具：command、stdin、noDeps、egress 都传到了", async () => {
    const piped = await mcp.tool("run", {
      service: "check",
      command: ["sh", "-c", "grep -c ' db$' /etc/hosts; cat; exit 7"],
      noDeps: true,
      stdin: "你好 run",
    });
    assert.deepEqual([piped.value.exitCode, piped.value.stdout], [7, "0\n你好 run"], JSON.stringify(piped.value));
    const withDeps = await mcp.tool("run", { service: "check", command: ["nc", "-w", "5", "db", "5432"] });
    assert.deepEqual([withDeps.value.exitCode, withDeps.value.stdout], [0, "from-db\n"], JSON.stringify(withDeps.value));

    // 和上一组一样拿 1.1.1.1:80 试：要这台电脑能上网
    const probe = { service: "check", noDeps: true, command: ["sh", "-c", "nc -z -w 3 1.1.1.1 80 && echo 通 || echo 不通"] };
    assert.equal((await mcp.tool("run", probe)).value.stdout, "通\n");
    assert.equal((await mcp.tool("run", { ...probe, egress: "none" })).value.stdout, "不通\n");
    await assertOnlyDevLeft();
  });

  test("run 工具：到时间就结束，带回已经收到的输出，环境照样销毁；起不来报的是 napboxd 的错误", async () => {
    const timedOut = await mcp.tool("run", {
      service: "check",
      noDeps: true,
      command: ["sh", "-c", "echo begun; sleep 600"],
      timeoutSeconds: 20,
    });
    assert.equal(timedOut.isError, true);
    assert.equal(timedOut.value.timedOut, true);
    assert.equal(timedOut.value.stdout, "begun\n");
    await waitUntil("run 的临时环境销毁", async () => (await names()).length === 1, 30_000);

    const missing = await mcp.tool("run", { service: "nope" });
    assert.equal(missing.isError, true);
    assert.equal(missing.value.error.code, "compose_invalid");
    await assertOnlyDevLeft();
  });
});
