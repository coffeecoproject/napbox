// 真的起虚拟机，把客户端的每个接口走一遍，并比较 napboxd 发的原始内容和客户端解析的结果，看有没有字段对不上。
// 用临时的 NAPBOX_SUPPORT_DIR，镜像库、内核和 runc 链接到正在用的目录（只读着用）。从 scripts/test-client.sh vm 运行。
import assert from "node:assert/strict";
import { execFileSync, spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import {
  existsSync,
  mkdirSync,
  readdirSync,
  mkdtempSync,
  readFileSync,
  realpathSync,
  renameSync,
  rmSync,
  symlinkSync,
  writeFileSync,
} from "node:fs";
import { connect, createServer } from "node:net";
import { tmpdir } from "node:os";
import path from "node:path";
import { after, afterEach, before, describe, test } from "node:test";
import type { ExecOptions } from "../src/client.ts";
import { NapboxClient } from "../src/client.ts";
import {
  type EnvironmentEvent,
  EnvironmentInfo,
  type EnvironmentTarget,
  methods,
  RunsResult,
} from "../src/protocol.ts";
import { type Daemon, delay, rawCall, rejectsWithCode, startDaemon, waitUntil } from "./support.ts";

const real = process.env.NAPBOX_REAL_SUPPORT_DIR;
if (!real) throw new Error("要用 scripts/test-client.sh vm 运行");

const work = realpathSync(mkdtempSync(path.join(tmpdir(), "nbx-vm-")));
const support = path.join(work, "support");
mkdirSync(support);
symlinkSync(path.join(real, "images"), path.join(support, "images"));
symlinkSync(path.join(real, "kernel"), path.join(support, "kernel"));
symlinkSync(path.join(real, "runc"), path.join(support, "runc"));
const log = path.join(work, "napboxd.log");

const COMPOSE = `services:
  init:
    image: alpine:3.20
    command: ["sh", "-c", "echo init-done"]
  web:
    image: alpine:3.20
    environment: {MSG: "\${GREETING}"}
    command: ["sh", "-c", "while true; do echo \\"$$MSG\\" | nc -l -p 8080; done"]
    ports: ["8080"]
    stop_grace_period: 1s
  app:
    image: alpine:3.20
    volumes: ["data:/data"]
    command: ["sh", "-c", "printf 'line1\\\\nline2\\\\n你好\\\\n'; while true; do if [ -f /data/say ]; then cat /data/say; rm /data/say; fi; sleep 0.2; done"]
    stop_grace_period: 1s
  crasher:
    image: alpine:3.20
    command: ["sh", "-c", "while [ ! -f /tmp/die ]; do sleep 0.2; done; exit 4"]
    stop_grace_period: 1s
volumes:
  data:
`;

function repo(relative: string, compose: string, git = true): string {
  const dir = path.join(work, relative);
  mkdirSync(dir, { recursive: true });
  if (git) execFileSync("git", ["init", "-q", dir]);
  writeFileSync(path.join(dir, "compose.yaml"), compose);
  return dir;
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

describe("调用方持有的环境", { concurrency: false }, () => {
  let daemon: Daemon;
  let client: NapboxClient;
  const target: EnvironmentTarget = { name: "codeos/goal-1-work", owner: "codeos" };
  const directory = repo("goal/work/repo", COMPOSE);
  const events: EnvironmentEvent[] = [];
  const unsubscribe = new AbortController();
  let subscription: Promise<void>;

  /** 跑一条命令，收集输出 */
  async function run(
    service: string,
    command: string[],
    options: Partial<Pick<ExecOptions, "stdin" | "signal">> = {},
  ) {
    const stdout: Buffer[] = [];
    const stderr: Buffer[] = [];
    const { exitCode } = await client.exec({
      target,
      service,
      command,
      ...options,
      onOutput: (o) => {
        (o.stream === "stdout" ? stdout : stderr).push(Buffer.from(o.data));
      },
    });
    return { exitCode, stdout: Buffer.concat(stdout), stderr: Buffer.concat(stderr) };
  }

  const eventOf = (type: EnvironmentEvent["type"], extra: Partial<EnvironmentEvent> = {}) => {
    return () =>
      events.find(
        (e) =>
          e.environment === target.name &&
          e.type === type &&
          Object.entries(extra).every(([k, v]) => e[k as keyof EnvironmentEvent] === v),
      );
  };
  const waitEvent = (type: EnvironmentEvent["type"], extra: Partial<EnvironmentEvent> = {}) => {
    const find = eventOf(type, extra);
    return waitUntil(`事件 ${type} ${JSON.stringify(extra)}`, () => find() !== undefined).then(
      () => find() as EnvironmentEvent,
    );
  };

  /** Docker Desktop 29.4.3 的虚拟机里量到的值（2026-11-10），napbox 照着设 */
  const DOCKER_DESKTOP_INOTIFY_LIMITS = { max_user_watches: 1048576, max_user_instances: 8192, max_queued_events: 16384 };
  /** 虚拟机里文件监听的三个上限：容器和虚拟机用的是同一份 */
  async function inotifyLimits() {
    const names = Object.keys(DOCKER_DESKTOP_INOTIFY_LIMITS);
    const out = await run("app", ["sh", "-c", `cd /proc/sys/fs/inotify && cat ${names.join(" ")}`]);
    const values = out.stdout.toString().trim().split("\n").map(Number);
    return Object.fromEntries(names.map((name, i) => [name, values[i]]));
  }

  /**
   * 虚拟机的时钟落在本机时间的范围里：量 5 次，取往返最短的一次，
   * 虚拟机读到的时间要在发出命令和拿到结果之间，前后各放 5 毫秒。框架开机 30 秒后才第一次对时，
   * 在那之前差几毫秒到一百多毫秒，所以这条要在开机后 30 秒内跑
   */
  async function assertClockInStep() {
    let best: { before: number; after: number; guest: number } | undefined;
    for (let i = 0; i < 5; i++) {
      const before = performance.timeOrigin + performance.now();
      // alpine 的 busybox date 不支持 %N；adjtimex 不带参数只读不改，给到微秒
      const out = await run("app", ["adjtimex"]);
      const after = performance.timeOrigin + performance.now();
      const text = out.stdout.toString();
      const sec = /time\.tv_sec:\s*(\d+)/.exec(text)?.[1];
      const usec = /time\.tv_usec:\s*(\d+)/.exec(text)?.[1];
      assert.ok(sec && usec, `adjtimex 的输出：${text}${out.stderr.toString()}`);
      const guest = Number(sec) * 1000 + Number(usec) / 1000;
      if (!best || after - before < best.after - best.before) best = { before, after, guest };
    }
    const { before, after, guest } = best!;
    assert.ok(
      guest >= before - 5 && guest <= after + 5,
      `虚拟机比发出命令时早 ${(before - guest).toFixed(1)} 毫秒，比拿到结果时晚 ${(guest - after).toFixed(1)} 毫秒`,
    );
  }

  /** 客户端解析后的结果和 napboxd 发的原始内容完全一样：一个字段都没丢、没变 */
  async function assertNothingLost() {
    const info = await rawCall(daemon.socketPath, methods.environment, { target });
    assert.deepEqual(EnvironmentInfo.parse(info.result), info.result);
    const runs = await rawCall(daemon.socketPath, methods.runs, { target });
    assert.deepEqual(RunsResult.parse(runs.result), runs.result);
  }

  before(async () => {
    daemon = await startDaemon(support, log);
    client = daemon.client;
    await new Promise<void>((resolve, reject) => {
      subscription = client.subscribe({
        owner: "codeos",
        onSubscribed: () => resolve(),
        onEvent: (event) => {
          events.push(event);
        },
        signal: unsubscribe.signal,
      });
      subscription.catch(reject);
    });
  });

  after(async () => {
    unsubscribe.abort();
    await subscription.catch(() => {});
    await daemon.stop("SIGTERM");
  });

  test("create：起来了，端口真能连，结果和事件、运行记录对得上", async () => {
    const info = await client.create({
      name: "codeos/goal-1-work",
      owner: "codeos",
      directory,
      environment: { GREETING: "你好 napbox" },
    });
    assert.equal(info.name, "codeos/goal-1-work");
    assert.equal(info.owner, "codeos");
    assert.equal(info.state, "running");
    assert.equal(info.egress, "open");
    const port = info.ports.find((p) => p.service === "web");
    assert.ok(port);
    assert.equal(info.variables[port.variable], `127.0.0.1:${port.hostPort}`);
    assert.equal(info.hostname, "goal-1-work--codeos.localhost");
    assert.equal(info.variables[`${port.variable}_SITE`], `${info.hostname}:${port.hostPort}`);
    assert.equal(info.variables.NAPBOX_HOSTNAME, info.hostname);
    const hear = (host: string) =>
      new Promise<string>((resolve, reject) => {
        const socket = connect(port.hostPort, host);
        socket.setEncoding("utf8");
        socket.once("data", (data) => {
          socket.destroy();
          resolve(data as unknown as string);
        });
        socket.once("error", reject);
        socket.once("close", () => resolve("")); // 服务还没重新监听：转发连上又断开，没有数据
      });
    // 127.0.0.1、::1 都转发到服务，主机名也连得上（浏览器先试 ::1）。
    // 服务的 nc 回完一个连接才重新监听，紧接着连下一个可能赶在它重新监听之前，所以重试几次
    for (const host of ["127.0.0.1", "::1", info.hostname]) {
      let said = "";
      for (let attempt = 0; attempt < 20 && !said.trim(); attempt++) {
        if (attempt) await new Promise((r) => setTimeout(r, 100));
        said = await hear(host).catch(() => "");
      }
      assert.equal(said.trim(), "你好 napbox", host);
    }

    const started = await waitEvent("started", { purpose: "up" });
    const { runs } = await client.runs(target);
    assert.equal(runs.length, 1);
    assert.equal(runs[0]?.id, started.runId);
    assert.equal(runs[0]?.purpose, "up");
    const readiness = Object.fromEntries(runs[0]?.services.map((s) => [s.service, s.readiness]) ?? []);
    assert.equal(readiness.web, "port");
    assert.equal(readiness.app, "process");
    await assertNothingLost();
  });

  test("新起的虚拟机：文件监听的上限和 Docker Desktop 一样（内核自己算的默认值小得多，前端项目会不够）", async () => {
    assert.deepEqual(await inotifyLimits(), DOCKER_DESKTOP_INOTIFY_LIMITS);
  });

  test("新起的虚拟机：时钟马上和本机对准，不等框架 30 秒后的第一次对时", async () => {
    await assertClockInStep();
  });

  test("同名再 create：不重启；持有方或目录不同报 name_taken；按名字的持有方不对报 owner_mismatch", async () => {
    await client.create({
      name: "codeos/goal-1-work",
      owner: "codeos",
      directory,
      environment: { GREETING: "你好 napbox" },
    });
    assert.equal((await client.runs(target)).runs.length, 1);
    await rejectsWithCode(
      client.create({ name: "codeos/goal-1-work", owner: "other", directory }),
      "name_taken",
    );
    await rejectsWithCode(
      client.create({
        name: "codeos/goal-1-work",
        owner: "codeos",
        directory: repo("goal/other/repo", COMPOSE),
      }),
      "name_taken",
    );
    await rejectsWithCode(
      client.environment({ name: "codeos/goal-1-work", owner: "other" }),
      "owner_mismatch",
    );
    await rejectsWithCode(client.environment({ cwd: directory }), "owner_mismatch");
  });

  test("status 里能看到它", async () => {
    const status = await client.status();
    assert.deepEqual(
      status.environments.map((e) => e.name),
      ["codeos/goal-1-work"],
    );
  });

  test("exec：标准输出、标准错误分开，退出码原样，命令失败不算出错", async () => {
    const result = await run("app", ["sh", "-c", "echo 出; echo 错 >&2; exit 7"]);
    assert.equal(result.exitCode, 7);
    assert.equal(result.stdout.toString(), "出\n");
    assert.equal(result.stderr.toString(), "错\n");
  });

  test("exec 的标准输入：不给时命令马上读到结尾；字符串；任意字节分多块", async () => {
    const none = await run("app", ["cat"]);
    assert.equal(none.exitCode, 0);
    assert.equal(none.stdout.length, 0);

    const text = await run("app", ["cat"], { stdin: "中文输入" });
    assert.equal(text.stdout.toString(), "中文输入");

    const block = Buffer.from(Array.from({ length: 256 }, (_, i) => i));
    const chunks = Array.from({ length: 2000 }, () => block);
    const big = await run("app", ["cat"], {
      stdin: (async function* () {
        yield* chunks;
      })(),
    });
    assert.equal(big.exitCode, 0);
    assert.ok(big.stdout.equals(Buffer.concat(chunks)), "字节要原样回来");
  });

  test("exec：命令已经结束时不再等标准输入", async () => {
    const result = await run("app", ["true"], {
      stdin: (async function* () {
        yield "x";
        await new Promise(() => {}); // 永远不给下一块
      })(),
    });
    assert.equal(result.exitCode, 0);
  });

  test("exec：服务不存在报 service_not_found", async () => {
    await rejectsWithCode(run("nope", ["true"]), "service_not_found");
  });

  const alive = async (marker: string) => (await run("app", ["pgrep", "-f", `sleep ${marker}`])).exitCode === 0;
  // 记号出现在 sleep 和外层 sh 的命令行里，pgrep 查不到就说明这几层都没了
  const execForms: Record<string, (marker: string) => string[]> = {
    直接运行: (m) => ["sleep", m],
    "sh 下的子进程": (m) => ["sh", "-c", `sleep ${m}; echo done`],
    三层嵌套: (m) => ["sh", "-c", `sh -c 'sh -c "sleep ${m}; echo a"; echo b'; echo c`],
    后台子进程: (m) => ["sh", "-c", `sleep ${m} & wait`],
  };
  let nextMarker = 4000;
  const newMarker = () => `${nextMarker++}.5`;

  // 反复取消：只取消一次时，直接运行的命令常常碰巧被杀到（2026-11-08 实测 48 次里 9 次没杀到）
  for (const [form, command] of Object.entries(execForms)) {
    test(`exec：取消时以 signal.reason 拒绝，容器里整条命令都结束（${form}，6 次）`, async () => {
      for (let round = 0; round < 6; round++) {
        const marker = newMarker();
        const controller = new AbortController();
        const reason = new Error("不等了");
        const running = run("app", command(marker), { signal: controller.signal });
        await waitUntil("命令跑起来", () => alive(marker));
        controller.abort(reason);
        await assert.rejects(running, (error) => error === reason);
        await waitUntil(`第 ${round + 1} 次取消后命令结束`, async () => !(await alive(marker)), 5_000);
      }
    });
  }

  test("exec：超时后整个进程组结束，确认结束了才返回 timedOut", async () => {
    for (const [form, command] of Object.entries(execForms)) {
      const marker = newMarker();
      const started = Date.now();
      const result = await client.exec({ target, service: "app", command: command(marker), timeoutSeconds: 2, onOutput: () => {} });
      assert.deepEqual([result.timedOut, result.exitCode], [true, 137], form);
      assert.ok(Date.now() - started >= 2_000, `${form}：到了时限才结束`);
      // 同一个进程组一起收到 SIGKILL：组长的退出确认了，别的也就在结束了
      await waitUntil(`${form}：超时后命令都结束了`, async () => !(await alive(marker)), 1_000);
    }
    const quick = await client.exec({ target, service: "app", command: ["true"], timeoutSeconds: 30, onOutput: () => {} });
    assert.deepEqual([quick.exitCode, quick.timedOut], [0, undefined], "没超时不带 timedOut");
  });

  test("exec：命令刚启动就取消，也不留下进程", async () => {
    for (const ms of [0, 2, 5, 10, 20, 50]) {
      for (const [form, command] of Object.entries(execForms)) {
        const marker = newMarker();
        const controller = new AbortController();
        const running = run("app", command(marker), { signal: controller.signal });
        await delay(ms);
        controller.abort();
        await assert.rejects(running);
        await delay(1_000); // 这时可能还没启动，留时间让它（如果起来了）现身
        assert.equal(await alive(marker), false, `${form}，发出请求后 ${ms} 毫秒取消`);
      }
    }
  });

  test("exec：自己用 setsid 脱离的进程不在取消范围里（已知的边界），能手动结束", async () => {
    const marker = newMarker();
    const controller = new AbortController();
    const running = run("app", ["sh", "-c", `setsid sleep ${marker}; echo done`], { signal: controller.signal });
    await waitUntil("命令跑起来", () => alive(marker));
    controller.abort();
    await assert.rejects(running);
    await delay(1_000);
    assert.equal(await alive(marker), true);
    await run("app", ["pkill", "-f", `sleep ${marker}`]);
    await waitUntil("手动结束", async () => !(await alive(marker)), 5_000);
  });

  test("exec：onOutput 抛错时以那个错误结束，命令也结束", async () => {
    const boom = new Error("处理输出出错");
    const marker = "4343.5";
    const running = client.exec({
      target,
      service: "app",
      command: ["sh", "-c", `echo start; exec sleep ${marker}`],
      onOutput: () => {
        throw boom;
      },
    });
    await assert.rejects(running, (error) => error === boom);
    await waitUntil(
      "命令结束",
      async () => (await run("app", ["pgrep", "-f", `sleep ${marker}`])).exitCode === 1,
    );
  });

  test("logs：全部、最后几行，字节原样；服务不存在报错", async () => {
    const read = async (tail?: number) => {
      const chunks: Buffer[] = [];
      const result = await client.logs({
        target,
        service: "app",
        tail,
        onOutput: (o) => {
          assert.equal(o.stream, "stdout");
          chunks.push(Buffer.from(o.data));
        },
      });
      assert.deepEqual(result, {});
      return Buffer.concat(chunks).toString();
    };
    // napboxd 每次启动服务时在日志里记一行启动标记（RunningEnvironment 的日志）
    assert.match(await read(), /^----- napbox 启动 \S+ -----\nline1\nline2\n你好\n$/);
    assert.equal(await read(1), "你好\n");
    await rejectsWithCode(
      client.logs({ target, service: "nope", onOutput: () => {} }),
      "service_not_found",
    );
  });

  test("logs 跟着：新内容送到；取消时以 signal.reason 拒绝", async () => {
    const controller = new AbortController();
    const reason = new Error("不看了");
    let seen = "";
    const following = client.logs({
      target,
      service: "app",
      tail: 0,
      follow: true,
      signal: controller.signal,
      onOutput: (o) => {
        seen += Buffer.from(o.data).toString();
        if (seen.includes("新的一行")) controller.abort(reason);
      },
    });
    await run("app", ["sh", "-c", "echo 新的一行 > /data/say.tmp && mv /data/say.tmp /data/say"]);
    await assert.rejects(following, (error) => error === reason);
    assert.equal(seen, "新的一行\n");
  });

  test("egress：切换后结果和 environment 都对", async () => {
    assert.equal((await client.egress(target, "none")).egress, "none");
    assert.equal((await client.environment(target)).egress, "none");
    assert.equal((await client.egress(target, "open")).egress, "open");
    assert.equal((await client.runs(target)).runs.length, 1, "切换不重启");
  });

  test("sleep 和 wake：状态、事件、运行记录都对，一次性服务跳过", async () => {
    const slept = await client.sleep(target);
    assert.equal(slept.state, "sleeping");
    await waitEvent("slept", { sleepReason: "request" });
    assert.equal((await client.environment(target)).state, "sleeping", "environment 不唤醒");
    let logged = "";
    await client.logs({
      target,
      service: "app",
      onOutput: (o) => {
        logged += Buffer.from(o.data).toString();
      },
    });
    assert.match(logged, /line1/, "休眠时也能看日志");
    assert.equal((await client.environment(target)).state, "sleeping", "logs 不唤醒");

    const woken = await client.wake(target);
    assert.equal(woken.state, "running");
    await waitEvent("started", { purpose: "wake" });
    const last = (await client.runs(target)).runs.at(-1);
    assert.equal(last?.purpose, "wake");
    assert.equal(last?.services.find((s) => s.service === "init")?.skipped, true);
    await assertNothingLost();
  });

  test("exec 碰到休眠的环境：先唤醒", async () => {
    await client.sleep(target);
    const result = await run("app", ["echo", "醒了"]);
    assert.equal(result.stdout.toString(), "醒了\n");
    assert.equal((await client.environment(target)).state, "running");
  });

  test("唤醒后的虚拟机：文件监听的上限也和 Docker Desktop 一样", async () => {
    assert.deepEqual(await inotifyLimits(), DOCKER_DESKTOP_INOTIFY_LIMITS);
  });

  test("唤醒后的虚拟机：时钟也马上对准", async () => {
    await assertClockInStep();
  });

  test("reset：数据卷清空，运行记录 purpose 是 reset；没有这个卷报 volume_not_found", async () => {
    await run("app", ["touch", "/data/keep"]);
    await rejectsWithCode(client.reset(target, ["nope"]), "volume_not_found");
    const info = await client.reset(target, ["data"]);
    assert.equal(info.state, "running");
    assert.equal((await run("app", ["test", "-e", "/data/keep"])).exitCode, 1);
    assert.equal((await client.runs(target)).runs.at(-1)?.purpose, "reset");
  });

  test("运行中有服务退出：事件和 environment 里都有", async () => {
    await run("crasher", ["touch", "/tmp/die"]);
    const exited = await waitEvent("service_exited", { service: "crasher" });
    assert.equal(exited.exitCode, 4);
    assert.equal(exited.restart, "none");
    const info = await client.environment(target);
    // 跑完的一次性服务 init 也算退出过，这里只看 crasher
    assert.deepEqual(
      info.serviceExits.filter((e) => e.service === "crasher").map((e) => [e.exitCode, e.restart]),
      [[4, "none"]],
    );
    await assertNothingLost();
  });

  test("healthcheck 没通过：create、wake 报 healthcheck_timeout，有事件和运行记录", async () => {
    const bad = { name: "codeos/goal-2-bad", owner: "codeos" };
    const dir = repo(
      "goal/bad/repo",
      `services:
  sick:
    image: alpine:3.20
    command: ["sleep", "100000"]
    healthcheck: {test: ["CMD", "false"], interval: 1s, retries: 2}
    stop_grace_period: 1s
`,
    );
    await rejectsWithCode(client.create({ ...bad, directory: dir }), "healthcheck_timeout");
    await waitUntil("start_failed 事件", () =>
      events.some((e) => e.environment === bad.name && e.type === "start_failed"),
    );
    const failure = events.find((e) => e.environment === bad.name && e.type === "start_failed");
    assert.equal(failure?.error?.code, "healthcheck_timeout");
    const { runs } = await client.runs(bad);
    assert.equal(runs[0]?.error?.code, "healthcheck_timeout");
    assert.ok(runs[0]?.services[0]?.startedAt);
    assert.equal(runs[0]?.services[0]?.readyAt, undefined);
    assert.ok((await client.environment(bad)).lastError);
    await rejectsWithCode(client.wake(bad), "healthcheck_timeout");
    const raw = await rawCall(daemon.socketPath, methods.runs, { target: bad });
    assert.deepEqual(RunsResult.parse(raw.result), raw.result);
    await client.down(bad);
  });

  test("准备就失败：全新环境报 image_unavailable，没有登记", async () => {
    const dir = repo(
      "goal/no-image/repo",
      "services:\n  missing:\n    image: napbox-test/not-here:1\n    pull_policy: never\n",
    );
    const fresh = { name: "codeos/goal-3-image", owner: "codeos" };
    await rejectsWithCode(client.create({ ...fresh, directory: dir }), "image_unavailable");
    await rejectsWithCode(client.environment(fresh), "environment_not_found");
  });

  // 有没有命令要看镜像：镜像准备好以后、登记之前查
  test("镜像和 compose 合起来没有要执行的命令：全新环境报 compose_invalid，没有登记", async () => {
    const dir = repo("goal/no-command/repo", "services:\n  empty:\n    image: alpine:3.20\n    entrypoint: []\n");
    const fresh = { name: "codeos/goal-3-command", owner: "codeos" };
    const error = await rejectsWithCode(client.create({ ...fresh, directory: dir }), "compose_invalid");
    assert.match(error.message, /empty 没有要执行的命令/);
    await rejectsWithCode(client.environment(fresh), "environment_not_found");
  });

  test("worktree 持有的环境：up，按目录操作，按名字操作被拒绝；本机进程的端口分了、不占着", async () => {
    const wt = repo(
      "demo",
      "x-napbox: {host_ports: [server, web]}\nservices:\n  app:\n    image: alpine:3.20\n    command: [\"sleep\", \"100000\"]\n    stop_grace_period: 1s\n",
    );
    const info = await client.up({ cwd: wt, environment: {} });
    assert.equal(info.owner, undefined);
    assert.equal(info.state, "running");
    assert.deepEqual(
      info.hostPorts.map((p) => [p.name, p.variable]),
      [
        ["server", "NAPBOX_HOST_SERVER"],
        ["web", "NAPBOX_HOST_WEB"],
      ],
    );
    for (const p of info.hostPorts) assert.equal(info.variables[p.variable], String(p.hostPort));
    // 项目自己的程序能监听它（napboxd 没占着）
    const server = createServer();
    await new Promise<void>((resolve, reject) => {
      server.once("error", reject);
      server.listen(info.hostPorts[0]!.hostPort, "127.0.0.1", resolve);
    });
    await new Promise<void>((resolve) => server.close(() => resolve()));
    const portsFile = JSON.parse(readFileSync(path.join(wt, ".napbox", "ports.json"), "utf8"));
    assert.deepEqual(portsFile.hostPorts, info.hostPorts);
    assert.equal(portsFile.variables.NAPBOX_HOST_WEB, String(info.hostPorts[1]!.hostPort));
    const byDirectory = { cwd: wt };
    assert.equal((await client.environment(byDirectory)).name, info.name);
    const raw = await rawCall(daemon.socketPath, methods.environment, { target: byDirectory });
    assert.deepEqual(EnvironmentInfo.parse(raw.result), raw.result);
    await rejectsWithCode(client.environment({ name: info.name, owner: "codeos" }), "owner_mismatch");
    let output = "";
    const { exitCode } = await client.exec({
      target: byDirectory,
      service: "app",
      command: ["echo", "在 worktree 里"],
      onOutput: (o) => {
        output += Buffer.from(o.data).toString();
      },
    });
    assert.equal(exitCode, 0);
    assert.equal(output, "在 worktree 里\n");
    const down = await client.down(byDirectory);
    assert.equal(down.name, info.name);
    assert.deepEqual(down.releasedPorts, info.hostPorts.map((p) => p.hostPort).sort((a, b) => a - b), "本机进程的端口也放开");
    await rejectsWithCode(client.environment(byDirectory), "environment_not_found");
  });

  test("down：logs 跟着的以 ended 正常结束，有 destroyed 事件，端口放掉，之后查不到", async () => {
    const before = await client.environment(target);
    const following = client.logs({ target, service: "app", tail: 0, follow: true, onOutput: () => {} });
    await delay(500);
    const down = await client.down(target);
    assert.equal(down.name, target.name);
    assert.ok(down.keptDataAt);
    assert.deepEqual(
      [...down.releasedPorts].sort(),
      before.ports.map((p) => p.hostPort).sort(),
    );
    const ended = await following;
    assert.match(ended.ended ?? "", /回收/);
    const destroyed = await waitEvent("destroyed");
    assert.ok(destroyed.reason);
    await rejectsWithCode(client.environment(target), "environment_not_found");
  });

  test("down 带 discardData：数据直接删掉，不进 recycled，结果里没有 keptDataAt；同名再建是空的", async () => {
    const count = (dir: string) => {
      const full = path.join(support, dir);
      return existsSync(full) ? readdirSync(full).length : 0;
    };
    const throwaway = { name: "codeos/goal-1-discard", owner: "codeos" };
    const dir = repo(
      "goal/discard/repo",
      "services:\n  app:\n    image: alpine:3.20\n    volumes: [\"data:/data\"]\n    command: [\"sleep\", \"100000\"]\n    stop_grace_period: 1s\nvolumes:\n  data:\n",
    );
    const environmentsBefore = count("environments");
    const recycledBefore = count("recycled");
    await client.create({ ...throwaway, directory: dir });
    const shell = (script: string) =>
      client.exec({ target: throwaway, service: "app", command: ["sh", "-c", script], onOutput: () => {} });
    const write = await shell("echo kept > /data/who");
    assert.equal(write.exitCode, 0);
    assert.equal(count("environments"), environmentsBefore + 1);

    const down = await client.down(throwaway, { discardData: true });
    assert.equal(down.name, throwaway.name);
    assert.equal(down.keptDataAt, undefined);
    assert.equal(count("environments"), environmentsBefore);
    assert.equal(count("recycled"), recycledBefore);
    await rejectsWithCode(client.environment(throwaway), "environment_not_found");

    await client.create({ ...throwaway, directory: dir });
    // 只看退出码不为 0 的话，卷没挂上、exec 出错也会过：要数据卷在、里面没有那个文件
    const empty = await shell("test -d /data && test ! -e /data/who");
    assert.equal(empty.exitCode, 0, "数据卷应该在、而且是空的");
    await client.down(throwaway, { discardData: true });
  });

  test("create 带 confine：目录以内的挂载照常可用，里面指出去的符号链接到不了本机；越界的不起；之后换成指出去的链接，唤醒被拦下", async () => {
    const confined = { name: "codeos/goal-1-confined", owner: "codeos" };
    const outside = path.join(work, "goal/confined/outside");
    mkdirSync(outside, { recursive: true });
    writeFileSync(path.join(outside, "secret.txt"), "HOST-SECRET\n");
    const dir = repo(
      "goal/confined/repo",
      [
        "secrets:",
        "  key: {file: ./keys/key.txt}",
        "services:",
        "  app:",
        "    image: alpine:3.20",
        '    volumes: ["./src:/src", "./conf/app.conf:/etc/app.conf:ro", "./data/new:/data"]',
        "    secrets: [key]",
        '    command: ["sleep", "100000"]',
        "    stop_grace_period: 1s",
        "",
      ].join("\n"),
    );
    mkdirSync(path.join(dir, "src"));
    mkdirSync(path.join(dir, "conf"));
    mkdirSync(path.join(dir, "keys"));
    writeFileSync(path.join(dir, "src/a.txt"), "inside\n");
    writeFileSync(path.join(dir, "conf/app.conf"), "v1\n");
    writeFileSync(path.join(dir, "keys/key.txt"), "k\n");
    symlinkSync(outside, path.join(dir, "src/abs"));
    symlinkSync("../../outside", path.join(dir, "src/rel"));
    const shell = async (script: string) => {
      let text = "";
      const { exitCode } = await client.exec({
        target: confined,
        service: "app",
        command: ["sh", "-c", script],
        onOutput: (o) => {
          text += Buffer.from(o.data).toString();
        },
      });
      return { exitCode, text };
    };

    // 先不受限建一次，再带 confine：改成受限，按受限的方式重新起
    assert.equal((await client.create({ ...confined, directory: dir })).confined, undefined);
    const info = await client.create({ ...confined, directory: dir, confine: true });
    assert.equal(info.confined, true);
    assert.equal((await client.environment(confined)).confined, true);
    assert.equal((await shell("cat /src/a.txt /etc/app.conf /run/secrets/key")).text, "inside\nv1\nk\n");
    // 不存在的来源在代码目录里建成目录，容器写的宿主机上看得到
    assert.equal((await shell("echo written > /data/w")).exitCode, 0);
    assert.equal(readFileSync(path.join(dir, "data/new/w"), "utf8"), "written\n");
    // 宿主机改了单个文件，容器里跟上；只读的写不进去
    writeFileSync(path.join(dir, "conf/app.conf"), "v2\n");
    assert.equal((await shell("cat /etc/app.conf")).text, "v2\n");
    assert.notEqual((await shell("echo x > /etc/app.conf")).exitCode, 0);
    // 挂进去的目录里指出去的符号链接由虚拟机解析，读不到本机的文件
    const probe = await shell("cat /src/abs/secret.txt /src/rel/secret.txt 2>&1; true");
    assert.doesNotMatch(probe.text, /HOST-SECRET/);

    // 越界的 compose 不起，在跑的环境不受影响
    const ssh = repo("goal/confined/ssh", 'services:\n  db:\n    image: alpine:3.20\n    volumes: ["~/.ssh:/root/.ssh:ro"]\n');
    const sshTarget = { name: "codeos/goal-1-ssh", owner: "codeos" };
    await rejectsWithCode(client.create({ ...sshTarget, directory: ssh, confine: true }), "path_outside_directory");
    await rejectsWithCode(client.environment(sshTarget), "environment_not_found");
    // 打开了就不能去掉
    await rejectsWithCode(client.create({ ...confined, directory: dir }), "bad_request");

    // 建好以后把挂载的目录换成指出去的链接：唤醒前再查，拦下来，说明哪个服务、哪个字段
    await client.sleep(confined);
    renameSync(path.join(dir, "src"), path.join(dir, "src.real"));
    symlinkSync(outside, path.join(dir, "src"));
    const error = await rejectsWithCode(client.wake(confined), "path_outside_directory");
    assert.match(error.message, /services\.app\.volumes（挂到 \/src）/);
    rmSync(path.join(dir, "src"));
    renameSync(path.join(dir, "src.real"), path.join(dir, "src"));
    assert.equal((await client.wake(confined)).state, "running");
    assert.equal((await shell("cat /src/a.txt")).text, "inside\n");

    // 代码目录本身换成符号链接（rmdir 再 ln -s）：按 create 时记下的真实路径查，不跟过去
    await client.sleep(confined);
    renameSync(dir, `${dir}.real`);
    mkdirSync(path.join(outside, "src"), { recursive: true });
    symlinkSync(outside, dir);
    const swapped = await rejectsWithCode(client.wake(confined), "path_outside_directory");
    assert.match(swapped.message, /本身被换掉了/);
    rmSync(dir);
    renameSync(`${dir}.real`, dir);
    assert.equal((await client.wake(confined)).state, "running");
    await client.down(confined, { discardData: true });
  });

  test("subscribe 按持有方过滤：别的持有方的事件收不到", () => {
    const seen = new Set(events.map((e) => e.owner));
    assert.deepEqual([...seen], ["codeos"], "worktree 持有的环境的事件不该送到 owner 过滤的订阅");
  });
});

describe("exec 输出积压", { concurrency: false }, () => {
  // 积压上限 1MB，这个余量留给分配器和连接。没有上限时，yes 几秒就让 napboxd 涨过 1GB
  const GROWTH_LIMIT_MB = 64;
  const target = { name: "codeos/backlog", owner: "codeos" };
  const directory = repo(
    "backlog/repo",
    `services:
  app:
    image: alpine:3.20
    command: ["sleep", "100000"]
    stop_grace_period: 1s
`,
  );
  let daemon: Daemon;
  let client: NapboxClient;
  before(async () => {
    daemon = await startDaemon(support, log);
    client = daemon.client;
    await client.create({ ...target, directory });
  });
  after(async () => {
    await client.down(target);
    await daemon.stop("SIGTERM");
  });

  const rssMB = () => Number(execFileSync("ps", ["-o", "rss=", "-p", String(daemon.process.pid)]).toString()) / 1024;
  /** 从现在开始看 napboxd 的内存，返回的函数停止观察并给出涨了多少 MB */
  function watchGrowth() {
    const base = rssMB();
    let peak = base;
    const timer = setInterval(() => {
      peak = Math.max(peak, rssMB());
    }, 100);
    return () => {
      clearInterval(timer);
      return peak - base;
    };
  }
  /** pgrep 看容器里有没有命令行含 marker 的进程 */
  async function alive(marker: string) {
    const { exitCode } = await client.exec({
      target,
      service: "app",
      command: ["pgrep", "-f", marker],
      onOutput: () => {},
    });
    return exitCode === 0;
  }
  const gone = (marker: string) => waitUntil(`${marker} 结束`, async () => !(await alive(marker)), 5_000);
  /** 模拟调用方不读：客户端等回调返回时不读连接。取消时放开，否则 exec 一直等这个回调（取消后还可能再来一块已经收到的） */
  const untilAborted = (signal: AbortSignal) =>
    new Promise<void>((resolve) => {
      if (signal.aborted) resolve();
      else signal.addEventListener("abort", () => resolve(), { once: true });
    });

  /** seq 1 n 的内容应有的大小和摘要 */
  function seqDigest(n: number) {
    const hash = createHash("sha256");
    let size = 0;
    for (let start = 1; start <= n; start += 100_000) {
      const end = Math.min(start + 99_999, n);
      const lines: number[] = [];
      for (let i = start; i <= end; i++) lines.push(i);
      const block = `${lines.join("\n")}\n`;
      hash.update(block);
      size += block.length;
    }
    return { size, sha: hash.digest("hex") };
  }
  /** 跑 seq 1 n，每块调 onChunk，断言一个字节不少、内容一样 */
  async function assertSeqComplete(n: number, shell: string, onChunk: (index: number) => Promise<void> | void) {
    const hash = createHash("sha256");
    let size = 0;
    let index = 0;
    const { exitCode } = await client.exec({
      target,
      service: "app",
      command: ["sh", "-c", shell],
      onOutput: async (o) => {
        hash.update(o.data);
        size += o.data.length;
        await onChunk(index++);
      },
    });
    const expected = seqDigest(n);
    assert.equal(exitCode, 0);
    assert.equal(size, expected.size, `${shell}：收到的字节数`);
    assert.equal(hash.digest("hex"), expected.sha, `${shell}：内容`);
  }

  for (const [name, wait, atLeast] of [
    ["回调快", 0, 50_000_000],
    ["回调每块慢 10 毫秒", 10, 1_000_000],
  ] as const) {
    test(`不停输出，${name}：内存不随输出增长，取消后不留进程`, async () => {
      const marker = `flood-${wait}`;
      const controller = new AbortController();
      const growth = watchGrowth();
      let bytes = 0;
      const running = client.exec({
        target,
        service: "app",
        command: ["yes", marker],
        signal: controller.signal,
        onOutput: async (o) => {
          bytes += o.data.length;
          if (wait > 0) await delay(wait);
        },
      });
      await delay(6_000);
      controller.abort();
      await assert.rejects(running);
      const grew = growth();
      console.log(`${name}：收到 ${(bytes / 1e6).toFixed(0)}MB，napboxd 涨了 ${grew.toFixed(0)}MB`);
      assert.ok(bytes >= atLeast, `输出要一直在走，收到 ${bytes} 字节`);
      assert.ok(grew <= GROWTH_LIMIT_MB, `napboxd 涨了 ${grew.toFixed(0)}MB`);
      await gone(marker);
    });
  }

  test("调用方完全不读：命令停在写输出上，内存不涨；断开后整条命令结束，环境能休眠", async () => {
    const marker = "stuck-3";
    const controller = new AbortController();
    const growth = watchGrowth();
    let started = false;
    const running = client.exec({
      target,
      service: "app",
      // sed 的参数里也有记号：管道两头和外层 sh 都要结束
      command: ["sh", "-c", `yes ${marker} | sed s/${marker}/${marker}/`],
      signal: controller.signal,
      onOutput: () => {
        started = true;
        return untilAborted(controller.signal);
      },
    });
    await waitUntil("有输出了", () => started);
    await delay(4_000);
    assert.equal(await alive(marker), true, "这时命令应该还在，等着调用方");
    controller.abort();
    await assert.rejects(running);
    const grew = growth();
    console.log(`不读：napboxd 涨了 ${grew.toFixed(0)}MB`);
    assert.ok(grew <= GROWTH_LIMIT_MB, `napboxd 涨了 ${grew.toFixed(0)}MB`);
    await gone(marker);
    assert.equal((await client.sleep(target)).state, "sleeping");
    assert.equal((await client.wake(target)).state, "running");
  });

  test("调用方不读时能休眠；放开后 exec 有结果，不卡住", async () => {
    let release = () => {};
    const gate = new Promise<void>((resolve) => {
      release = resolve;
    });
    let started = false;
    const running = client.exec({
      target,
      service: "app",
      command: ["yes", "sleeping-4"],
      onOutput: () => {
        started = true;
        return gate;
      },
    });
    const settled = running.then(
      (r) => `退出码 ${r.exitCode}`,
      (e) => `错误 ${e.code}`,
    );
    await waitUntil("有输出了", () => started);
    await delay(1_000);
    assert.equal((await client.sleep(target)).state, "sleeping");
    release();
    const outcome = await Promise.race([settled, delay(10_000).then(() => "超时")]);
    console.log(`休眠后 exec：${outcome}`);
    assert.notEqual(outcome, "超时");
    assert.notEqual(outcome, "退出码 0", "命令是被停掉的");
    assert.equal((await client.wake(target)).state, "running");
  });

  test("多条命令同时被堵：别的命令照常，取消后都结束", async () => {
    const controllers = Array.from({ length: 10 }, () => new AbortController());
    const growth = watchGrowth();
    const running = controllers.map((controller) =>
      client
        .exec({
          target,
          service: "app",
          command: ["yes", "crowd-5"],
          signal: controller.signal,
          onOutput: () => untilAborted(controller.signal),
        })
        .catch(() => {}),
    );
    await delay(3_000);
    const startedAt = Date.now();
    assert.equal(await alive("crowd-5"), true);
    const took = Date.now() - startedAt;
    assert.ok(took < 2_000, `被堵时再跑一条命令用了 ${took} 毫秒`);
    for (const controller of controllers) controller.abort();
    await Promise.all(running);
    const grew = growth();
    console.log(`10 条被堵：napboxd 涨了 ${grew.toFixed(0)}MB`);
    assert.ok(grew <= GROWTH_LIMIT_MB, `napboxd 涨了 ${grew.toFixed(0)}MB`);
    await gone("crowd-5");
  });

  test("约 200MB 的输出，回调慢：一个字节不少，内存不涨", async () => {
    const n = 26_000_000;
    const growth = watchGrowth();
    await assertSeqComplete(n, `seq 1 ${n}`, () => delay(1));
    const grew = growth();
    console.log(`200MB：napboxd 涨了 ${grew.toFixed(0)}MB`);
    assert.ok(grew <= GROWTH_LIMIT_MB, `napboxd 涨了 ${grew.toFixed(0)}MB`);
  });

  // 刚超过积压上限的大小：命令写完退出时，剩下的还卡在途中（再大的话命令退不了，再小的话堵不住）。
  // LinuxProcess 只等输出 3 秒，调用方再慢一点，不等读完就 delete 的话这些输出会丢
  for (const n of [200_000, 220_000]) {
    test(`命令退出时输出还没读完（seq ${n}，第一块后停 6 秒）：一个字节不少`, async () => {
      await assertSeqComplete(n, `seq 1 ${n}`, (i) => (i === 0 ? delay(6_000) : undefined));
    });
  }

  test("命令退出时输出还没读完（每块慢 20 毫秒）：一个字节不少", async () => {
    await assertSeqComplete(220_000, "seq 1 220000", () => delay(20));
  });

  test("输出堵住后过了很久才退出：一个字节不少", async () => {
    await assertSeqComplete(200_000, "seq 1 200000; sleep 6", (i) => (i === 0 ? delay(12_000) : undefined));
  });

  test("标准输出和标准错误一起堵：两边都一个字节不少", async () => {
    const n = 300_000;
    const hashes = { stdout: createHash("sha256"), stderr: createHash("sha256") };
    const sizes = { stdout: 0, stderr: 0 };
    const { exitCode } = await client.exec({
      target,
      service: "app",
      command: ["sh", "-c", `seq 1 ${n} >&2 & seq 1 ${n}; wait`],
      onOutput: async (o) => {
        hashes[o.stream].update(o.data);
        sizes[o.stream] += o.data.length;
        await delay(1);
      },
    });
    const expected = seqDigest(n);
    assert.equal(exitCode, 0);
    assert.deepEqual(sizes, { stdout: expected.size, stderr: expected.size });
    assert.equal(hashes.stdout.digest("hex"), expected.sha);
    assert.equal(hashes.stderr.digest("hex"), expected.sha);
  });

  test("主命令退出了，后台进程还在不停输出：exec 能结束，不一直等", async () => {
    const running = client.exec({
      target,
      service: "app",
      command: ["sh", "-c", "(yes orphan-7 &) ; sleep 1; exit 3"],
      onOutput: () => delay(1),
    });
    const outcome = await Promise.race([running.then((r) => r.exitCode), delay(30_000).then(() => "超时")]);
    assert.equal(outcome, 3);
    await client.exec({ target, service: "app", command: ["pkill", "-f", "yes orphan-7"], onOutput: () => {} });
    await gone("yes orphan-7");
  });

  test("没堵过的命令结束时不多等", async () => {
    const startedAt = Date.now();
    await assertSeqComplete(1_000, "seq 1 1000", () => {});
    const took = Date.now() - startedAt;
    assert.ok(took < 450, `用了 ${took} 毫秒`);
  });

  test("调用方不读时 napboxd 收到 SIGTERM：能退出；重启后环境还在", async () => {
    const controller = new AbortController();
    let started = false;
    const running = client
      .exec({
        target,
        service: "app",
        command: ["yes", "term-6"],
        signal: controller.signal,
        onOutput: () => {
          started = true;
          return untilAborted(controller.signal);
        },
      })
      .catch(() => {});
    await waitUntil("有输出了", () => started);
    await delay(1_000);
    const startedAt = Date.now();
    await daemon.stop("SIGTERM");
    const took = Date.now() - startedAt;
    controller.abort();
    await running;
    assert.ok(took < 10_000, `退出用了 ${took} 毫秒`);
    daemon = await startDaemon(support, log);
    client = daemon.client;
    assert.equal((await client.environment(target)).state, "sleeping");
  });
});

describe("虚拟机没了", { concurrency: false }, () => {
  const target = { name: "codeos/vmlost", owner: "codeos" };
  const directory = repo(
    "vmlost/repo",
    `services:
  init:
    image: alpine:3.20
    volumes: ["data:/data"]
    command: ["sh", "-c", "echo run >> /data/init-runs; sync"]
  web:
    image: alpine:3.20
    volumes: ["data:/data"]
    depends_on: {init: {condition: service_completed_successfully}}
    command: ["sh", "-c", "echo web-started; while true; do (echo hello; sleep 30) | nc -l -p 8080; done"]
    ports: ["8080"]
    stop_grace_period: 5s # 比下面等事件的时间长：虚拟机没了时不用等它
volumes:
  data:
`,
  );
  let daemon: Daemon;
  let client: NapboxClient;
  let unsubscribe: AbortController;
  let subscription: Promise<void>;
  const events: EnvironmentEvent[] = [];

  async function startWatched() {
    daemon = await startDaemon(support, log);
    client = daemon.client;
    unsubscribe = new AbortController();
    await new Promise<void>((resolve, reject) => {
      subscription = client.subscribe({
        owner: "codeos",
        onSubscribed: () => resolve(),
        onEvent: (event) => {
          events.push(event);
        },
        signal: unsubscribe.signal,
      });
      subscription.catch(reject);
    });
  }
  async function stopWatched() {
    unsubscribe.abort();
    await subscription.catch(() => {});
    await daemon.stop("SIGTERM");
  }
  before(async () => {
    await startWatched();
    await client.create({ ...target, directory });
  });
  after(async () => {
    await client.down(target);
    await stopWatched();
  });

  /** 这份测试自己的虚拟机进程：打开了临时目录里文件的那些。同名的还有 Docker 的虚拟化进程，绝不能碰 */
  function ownVMs(): number[] {
    const all = spawnSync("pgrep", ["-f", "com.apple.Virtualization.VirtualMachine"]).stdout.toString();
    return all
      .trim()
      .split("\n")
      .filter(Boolean)
      .map(Number)
      .filter((pid) => spawnSync("lsof", ["-p", String(pid)], { maxBuffer: 1 << 26 }).stdout.toString().includes(support));
  }
  function ownVM(): number {
    const pids = ownVMs();
    const [pid] = pids;
    assert.ok(pid !== undefined && pids.length === 1, `认不出这个环境的虚拟机，不动手：${pids.join(",") || "没有"}`);
    return pid;
  }
  const lostEvents = () => events.filter((e) => e.type === "slept" && e.sleepReason === "vm_lost");
  const stateOf = async (t: EnvironmentTarget = target) => (await client.environment(t)).state;
  const runCount = async (t: EnvironmentTarget = target) => (await client.runs(t)).runs.length;
  /** 杀掉虚拟机进程，等环境转成休眠。这时虚拟机才刚没，正确的 napboxd 不用等 stop_grace_period */
  async function killVM() {
    process.kill(ownVM(), "SIGKILL");
    await waitUntil("环境转成休眠", async () => (await stateOf()) === "sleeping", 3_000);
  }
  async function sh(command: string) {
    let out = "";
    const result = await client.exec({
      target,
      service: "web",
      command: ["sh", "-c", command],
      onOutput: (o) => {
        out += Buffer.from(o.data).toString();
      },
    });
    assert.equal(result.exitCode, 0, out);
    return out.trim();
  }
  const portOf = (info: EnvironmentInfo) => {
    const [port] = info.ports;
    assert.ok(port);
    return port.hostPort;
  };
  const usage = () => {
    const pid = String(daemon.process.pid);
    return {
      threads: spawnSync("ps", ["-M", "-p", pid]).stdout.toString().trim().split("\n").length - 1,
      files: spawnSync("lsof", ["-p", pid], { maxBuffer: 1 << 26 }).stdout.toString().trim().split("\n").length - 1,
    };
  };
  /** 连上环境的端口，收到第一块数据后返回；closed 是连接断开的时候 */
  function open(port: number) {
    return new Promise<{ first: string; closed: () => boolean; close: () => void }>((resolve, reject) => {
      const socket = connect(port, "127.0.0.1");
      let isClosed = false;
      socket.once("close", () => {
        isClosed = true;
      });
      socket.on("error", () => {});
      socket.once("data", (d) => resolve({ first: d.toString().trim(), closed: () => isClosed, close: () => socket.destroy() }));
      socket.once("close", () => reject(new Error("连接断开了，没收到数据")));
    });
  }

  test("虚拟机进程被杀：很快转成休眠，有通知和原因；进行中的命令失败，转发断开，日志还跟着；唤醒后数据都在", async () => {
    const info = await client.wake(target);
    await sh("echo keep > /data/keep; sync");
    events.length = 0;

    const logged: string[] = [];
    const stopLogs = new AbortController();
    const following = client.logs({
      target,
      service: "web",
      tail: 0,
      follow: true,
      signal: stopLogs.signal,
      onOutput: (o) => {
        logged.push(Buffer.from(o.data).toString());
      },
    });
    following.catch(() => {});
    const quiet = client.exec({ target, service: "web", command: ["sleep", "1000"], onOutput: () => {} });
    quiet.catch(() => {}); // 下面才检查
    let release = () => {};
    const stalled = new Promise<void>((resolve) => {
      release = resolve;
    });
    const blocked = client.exec({ target, service: "web", command: ["yes"], onOutput: () => stalled });
    blocked.catch(() => {}); // 下面才检查
    const held = await open(portOf(info));
    assert.equal(held.first, "hello");
    await delay(500);

    const killedAt = Date.now();
    await killVM();
    const noticed = Date.now() - killedAt;
    console.log(`虚拟机被杀后 ${noticed}ms 转成休眠`);

    await waitUntil("转发的连接断开", () => held.closed(), 3_000);
    held.close();
    await rejectsWithCode(quiet, "service_failed");
    release();
    await rejectsWithCode(blocked, "service_failed");
    await waitUntil("收到 vm_lost 事件", () => lostEvents().length === 1, 3_000);
    assert.equal(events.filter((e) => e.type === "service_exited").length, 0, "虚拟机没了不算服务退出");
    assert.equal(events.filter((e) => e.type === "started").length, 0, "不自动重启");
    assert.match((await client.environment(target)).lastError ?? "", /虚拟机/);

    // 刚崩溃的冷却期里 exec 不自动唤醒，错误说明原因
    const refused = await rejectsWithCode(client.exec({ target, service: "web", command: ["true"], onOutput: () => {} }), "service_failed");
    assert.match(refused.message, /虚拟机/);
    assert.equal(ownVMs().length, 0, "冷却期里没有起虚拟机");

    // 明确唤醒不受冷却限制，失败原因清掉，数据还在，跑完的一次性服务不重跑
    const woken = await client.wake(target);
    assert.equal(woken.state, "running");
    assert.equal(woken.lastError, undefined);
    assert.equal(await sh("cat /data/keep"), "keep");
    assert.equal(await sh("wc -l < /data/init-runs"), "1");
    await waitUntil("跟着的日志收到唤醒后的输出", () => logged.join("").includes("web-started"), 5_000);
    stopLogs.abort();
    await following.catch(() => {});
  });

  test("反复崩溃：不自己重启，线程和句柄不涨；过了冷却期，连接进来才唤醒", async () => {
    const info = await client.wake(target);
    await killVM();
    await client.wake(target);
    const base = usage();
    for (let i = 0; i < 3; i++) {
      const runs = await runCount();
      await killVM();
      await delay(1_500);
      assert.equal(await stateOf(), "sleeping", "崩溃后不自己重启");
      assert.equal(await runCount(), runs, "崩溃后没有新的运行记录");
      await client.wake(target);
    }
    const now = usage();
    console.log(`崩溃 3 次：线程 ${base.threads} -> ${now.threads}，句柄 ${base.files} -> ${now.files}`);
    // 每次崩溃留下一组线程（CPU 核数个）和同样多的句柄时，这里至少涨 3 组
    assert.ok(now.threads - base.threads < 18, `线程涨了 ${now.threads - base.threads}`);
    assert.ok(now.files - base.files < 18, `句柄涨了 ${now.files - base.files}`);

    const runs = await runCount();
    await killVM();
    await delay(11_000);
    assert.equal(await stateOf(), "sleeping", "没人用就一直休眠");
    assert.equal(await runCount(), runs);
    const held = await open(portOf(info));
    assert.equal(held.first, "hello");
    held.close();
    // 连接只等它连的服务：回话时环境可能还没起完，状态还是休眠
    await waitUntil("环境起完", async () => (await stateOf()) === "running", 10_000);
  });

  test("虚拟机卡住（SIGSTOP）：不算没了，恢复后命令照常结束", async () => {
    await client.wake(target);
    events.length = 0;
    const runs = await runCount();
    const vm = ownVM();
    let out = "";
    const pending = client.exec({
      target,
      service: "web",
      command: ["sh", "-c", "sleep 2; echo done"],
      onOutput: (o) => {
        out += Buffer.from(o.data).toString();
      },
    });
    await delay(300);
    process.kill(vm, "SIGSTOP");
    try {
      for (let i = 0; i < 16; i++) {
        await delay(500);
        assert.equal(await stateOf(), "running");
      }
    } finally {
      process.kill(vm, "SIGCONT");
    }
    assert.equal((await pending).exitCode, 0);
    assert.equal(out.trim(), "done");
    assert.equal(await sh("echo ok"), "ok");
    assert.equal(ownVM(), vm, "还是同一台虚拟机");
    assert.equal(await runCount(), runs);
    assert.equal(lostEvents().length, 0);
  });

  test("正常休眠、napboxd 退出、down 都不算虚拟机没了", async () => {
    await client.wake(target);
    const logged = () => readFileSync(log, "utf8").split("\n").filter((l) => l.includes("意外停了")).length;
    const before = logged();
    events.length = 0;
    await client.sleep(target);
    // 事件走另一条连接，可能比 sleep 的回应晚到
    await waitUntil("收到 slept 事件", () => events.some((e) => e.type === "slept" && e.sleepReason === "request"), 3_000);
    await client.wake(target);
    await stopWatched();
    await startWatched();
    assert.equal(await stateOf(), "sleeping");
    await client.create({ ...target, directory });
    await delay(1_500); // 留够 napboxd 看一次虚拟机状态
    const other = { name: "codeos/vmlost-down", owner: "codeos" };
    await client.create({ ...other, directory: repo("vmlost/other", "services:\n  app:\n    image: alpine:3.20\n    command: [\"sleep\", \"100000\"]\n    stop_grace_period: 1s\n") });
    await client.down(other);
    await delay(1_500);
    assert.equal(lostEvents().length, 0);
    assert.equal(logged(), before);
  });

  test("启动过程中虚拟机没了：马上报错，不等到超时", async () => {
    await client.sleep(target);
    const starting = { name: "codeos/vmlost-start", owner: "codeos" };
    const never = repo(
      "vmlost/never",
      `services:
  app:
    image: alpine:3.20
    command: ["sleep", "100000"]
    ports: ["8080"]
    stop_grace_period: 1s
`,
    );
    const creating = client.create({ ...starting, directory: never });
    creating.catch(() => {});
    await waitUntil("虚拟机起来了", () => ownVMs().length === 1, 30_000);
    await delay(1_500); // 等它走到等端口监听那一步
    process.kill(ownVM(), "SIGKILL");
    const killedAt = Date.now();
    const error = await rejectsWithCode(creating, "runtime_unavailable");
    assert.match(error.message, /虚拟机/);
    assert.ok(Date.now() - killedAt < 5_000, `等了 ${Date.now() - killedAt}ms 才报错`);
    assert.equal(await stateOf(starting), "sleeping");
    await client.down(starting);
  });
});

describe("连接进行中 napboxd 没了", { concurrency: false }, () => {
  const target = { name: "codeos/crash", owner: "codeos" };
  const directory = repo(
    "crash/repo",
    `services:
  app:
    image: alpine:3.20
    command: ["sh", "-c", "echo up; exec sleep 100000"]
    stop_grace_period: 1s
`,
  );

  /** 同时开着 exec、logs 跟着、subscribe */
  async function openStreams(client: NapboxClient) {
    let subscribed = false;
    let execStarted = false;
    const exec = client.exec({
      target,
      service: "app",
      command: ["sh", "-c", "echo started; exec sleep 100000"],
      onOutput: () => {
        execStarted = true;
      },
    });
    const logs = client.logs({ target, service: "app", follow: true, onOutput: () => {} });
    const subscribe = client.subscribe({
      onSubscribed: () => {
        subscribed = true;
      },
      onEvent: () => {},
    });
    const settled = {
      exec: exec.then(
        (r) => ({ result: r }),
        (e) => ({ error: e }),
      ),
      logs: rejectsWithCode(logs, "daemon_unavailable"),
      subscribe: rejectsWithCode(subscribe, "daemon_unavailable"),
    };
    await waitUntil("都开始了", () => subscribed && execStarted);
    await delay(500); // logs 跟着没有输出可等，给它时间进入跟着的循环
    return settled;
  }

  test("正常退出：logs、subscribe 报 daemon_unavailable，exec 拿到结果或报 daemon_unavailable", async () => {
    const daemon = await startDaemon(support, log);
    await daemon.client.create({ ...target, directory });
    const open = await openStreams(daemon.client);
    await daemon.stop("SIGTERM");
    await open.logs;
    await open.subscribe;
    const exec = await open.exec;
    console.log(`SIGTERM 时 exec 的结果：${"result" in exec ? JSON.stringify(exec.result) : String(exec.error)}`);
    if ("error" in exec) await rejectsWithCode(Promise.reject(exec.error), "daemon_unavailable");
    else assert.notEqual(exec.result.exitCode, 0, "命令是被停掉的，不该是退出码 0");
  });

  test("被强杀：三个都报 daemon_unavailable，重启后环境还在，是休眠状态", async () => {
    const daemon = await startDaemon(support, log);
    assert.equal((await daemon.client.wake(target)).state, "running");
    const open = await openStreams(daemon.client);
    await daemon.stop("SIGKILL");
    await open.logs;
    await open.subscribe;
    const exec = await open.exec;
    await rejectsWithCode(
      "error" in exec ? Promise.reject(exec.error) : Promise.resolve(exec.result),
      "daemon_unavailable",
    );
    await rejectsWithCode(daemon.client.status(), "daemon_unavailable");
    const again = await startDaemon(support, log);
    assert.equal((await again.client.environment(target)).state, "sleeping");
    await again.client.down(target);
    await again.stop("SIGTERM");
  });
});

/** 在环境里跑一条命令，收集标准输出和退出码 */
async function execIn(client: NapboxClient, target: EnvironmentTarget, service: string, command: string[]) {
  const chunks: Buffer[] = [];
  const { exitCode } = await client.exec({
    target,
    service,
    command,
    onOutput: (o) => {
      if (o.stream === "stdout") chunks.push(Buffer.from(o.data));
    },
  });
  return { exitCode, stdout: Buffer.concat(chunks).toString() };
}

describe("服务的内存", { concurrency: false }, () => {
  // box 写了上限，碰到 /tmp/grow 就每 50 毫秒多占 8MB；free 没写上限。node 的代码页够大，到顶后内核反复挤它、不结束进程，
  // 正是要网络小容器处理的卡住（DESIGN.md 第 7 节「卡在内存上」）
  const compose = `services:
  box:
    image: node:22-alpine
    command: ["node", "-e", "const fs = require('fs'); const a = []; setInterval(() => { if (fs.existsSync('/tmp/grow')) a.push(Buffer.alloc(8 << 20, 1)) }, 50)"]
    mem_limit: 512m
    stop_grace_period: 1s
  free:
    image: alpine:3.20
    command: ["sleep", "100000"]
    stop_grace_period: 1s
`;
  const worktree = repo("memory/repo", compose);
  const target: EnvironmentTarget = { cwd: worktree };
  let daemon: Daemon;
  let client: NapboxClient;

  before(async () => {
    daemon = await startDaemon(support, log);
    client = daemon.client;
    await client.up({ cwd: worktree, environment: {} });
  });
  after(async () => {
    await client.down(target).catch(() => {});
    await daemon.stop("SIGTERM");
  });

  test("写了上限的按它封顶；没写的不封顶（memory.max 是 max），和别的服务共用虚拟机的内存", async () => {
    assert.equal((await execIn(client, target, "box", ["cat", "/sys/fs/cgroup/memory.max"])).stdout, `${512 << 20}\n`);
    assert.equal((await execIn(client, target, "free", ["cat", "/sys/fs/cgroup/memory.max"])).stdout, "max\n");
  });

  test("卡在自己的上限上：很快结束占内存最多的进程，服务的日志写明原因", async () => {
    await execIn(client, target, "box", ["touch", "/tmp/grow"]);
    await waitUntil(
      "box 被结束",
      async () => (await client.environment(target)).serviceExits.some((e) => e.service === "box" && e.exitCode === 137),
      90_000,
    );
    const chunks: Buffer[] = [];
    await client.logs({ target, service: "box", onOutput: (o) => void chunks.push(Buffer.from(o.data)) });
    assert.match(Buffer.concat(chunks).toString(), /napbox：box 的内存到了上限 512MB，卡住了.*结束了它里面占内存最多的进程 node（进程号 \d+/);
    assert.equal((await execIn(client, target, "free", ["true"])).exitCode, 0, "别的服务不受影响");
  });
});

describe("服务自己退出后恢复", { concurrency: false }, () => {
  // web 有端口，worker 没有端口；都不写 restart，要靠 up、create、wake 拉起来。容器文件系统重启后沿用，/tmp/quit 启动时先删
  const compose = `services:
  init:
    image: alpine:3.20
    volumes: ["data:/data"]
    command: ["sh", "-c", "echo run >> /data/init-runs; sync"]
  web:
    image: alpine:3.20
    volumes: ["data:/data"]
    command: ["sh", "-c", "rm -f /tmp/quit; echo run >> /data/web-runs; sync; (while true; do echo hello | nc -l -p 8080; done) & while [ ! -f /tmp/quit ]; do sleep 0.1; done; exit 0"]
    ports: ["8080"]
    stop_grace_period: 1s
  worker:
    image: alpine:3.20
    command: ["sh", "-c", "rm -f /tmp/quit; while [ ! -f /tmp/quit ]; do sleep 0.1; done; exit 3"]
    stop_grace_period: 1s
volumes:
  data:
`;
  const worktree = repo("exits/repo", compose);
  const callerDirectory = repo("exits/caller", compose);
  const byDirectory: EnvironmentTarget = { cwd: worktree };
  const byName: EnvironmentTarget = { name: "codeos/exits", owner: "codeos" };
  const createParams = { name: byName.name, owner: "codeos", directory: callerDirectory, environment: {} };
  let daemon: Daemon;
  let client: NapboxClient;

  before(async () => {
    daemon = await startDaemon(support, log);
    client = daemon.client;
  });
  after(async () => {
    await client.down(byDirectory).catch(() => {});
    await client.down(byName).catch(() => {});
    await daemon.stop("SIGTERM");
  });

  const exitCount = async (target: EnvironmentTarget, service: string) =>
    (await client.environment(target)).serviceExits.filter((e) => e.service === service).length;

  /** 让服务退出，等 napboxd 记下这次退出 */
  async function quit(target: EnvironmentTarget, service: string) {
    const before = await exitCount(target, service);
    await execIn(client, target, service, ["touch", "/tmp/quit"]);
    await waitUntil(`${service} 退出`, async () => (await exitCount(target, service)) > before);
  }

  const lines = async (target: EnvironmentTarget, file: string) =>
    Number((await execIn(client, target, "web", ["sh", "-c", `wc -l < ${file}`])).stdout.trim());

  const runCount = async (target: EnvironmentTarget) => (await client.runs(target)).runs.length;

  function hello(port: number): Promise<string> {
    return new Promise((resolve, reject) => {
      const socket = connect(port, "127.0.0.1");
      let got = "";
      socket.setEncoding("utf8");
      socket.on("data", (d) => {
        got += d;
        if (got.includes("\n")) {
          socket.destroy();
          resolve(got);
        }
      });
      socket.on("error", reject);
      socket.on("close", () => reject(new Error(`连接断了，收到 ${JSON.stringify(got)}`)));
    });
  }

  const port = async (target: EnvironmentTarget) =>
    (await client.environment(target)).ports.find((p) => p.service === "web")?.hostPort as number;

  test("服务都在、一次性服务跑完了：up 不重启", async () => {
    await client.up({ cwd: worktree, environment: {} });
    await waitUntil("init 跑完", async () => (await exitCount(byDirectory, "init")) === 1);
    const runs = await runCount(byDirectory);
    assert.equal((await client.up({ cwd: worktree, environment: {} })).state, "running");
    assert.equal(await runCount(byDirectory), runs);
  });

  test("有端口的服务退出码 0：up 把它拉起来，一次性服务不重跑，数据还在", async () => {
    await quit(byDirectory, "web");
    await rejectsWithCode(execIn(client, byDirectory, "web", ["true"]), "service_failed");
    assert.equal((await client.up({ cwd: worktree, environment: {} })).state, "running");
    assert.equal(await hello(await port(byDirectory)), "hello\n");
    assert.equal(await lines(byDirectory, "/data/web-runs"), 2);
    assert.equal(await lines(byDirectory, "/data/init-runs"), 1);
    assert.equal((await client.runs(byDirectory)).runs.at(-1)?.purpose, "up");
  });

  test("没有端口的服务退出码非 0：up 把它拉起来", async () => {
    await quit(byDirectory, "worker");
    await client.up({ cwd: worktree, environment: {} });
    assert.equal((await execIn(client, byDirectory, "worker", ["true"])).exitCode, 0);
  });

  test("有端口的服务退出码 0 后休眠：连接进来自动唤醒时它也起来，不当成跑完的一次性服务", async () => {
    await quit(byDirectory, "web");
    await client.sleep(byDirectory);
    assert.equal((await client.environment(byDirectory)).state, "sleeping");
    assert.equal(await hello(await port(byDirectory)), "hello\n");
    // 连接只等它连的服务：回话时环境可能还没起完，运行记录在起完时才写
    await waitUntil("环境起完", async () => (await client.environment(byDirectory)).state === "running", 10_000);
    assert.equal((await client.runs(byDirectory)).runs.at(-1)?.purpose, "wake");
    assert.equal(await lines(byDirectory, "/data/init-runs"), 1);
  });

  test("调用方：create、wake 都保证服务在", async () => {
    await client.create(createParams);
    await waitUntil("init 跑完", async () => (await exitCount(byName, "init")) === 1);
    await quit(byName, "web");
    await client.create(createParams);
    assert.equal(await hello(await port(byName)), "hello\n");
    assert.equal((await client.runs(byName)).runs.at(-1)?.purpose, "up");
    await quit(byName, "worker");
    await client.wake(byName);
    assert.equal((await execIn(client, byName, "worker", ["true"])).exitCode, 0);
    assert.equal((await client.runs(byName)).runs.at(-1)?.purpose, "wake");
    assert.equal(await lines(byName, "/data/init-runs"), 1);
  });
});

describe("源码挂载：宿主机改完马上 exec", { concurrency: false }, () => {
  const directory = repo(
    "mount/repo",
    `services:
  box:
    image: alpine:3.20
    command: ["sleep", "100000"]
    volumes: ["./src:/src"]
    stop_grace_period: 1s
`,
  );
  const src = path.join(directory, "src");
  const target: EnvironmentTarget = { cwd: directory };
  let daemon: Daemon;
  let client: NapboxClient;

  before(async () => {
    mkdirSync(src);
    daemon = await startDaemon(support, log);
    client = daemon.client;
    await client.up({ cwd: directory, environment: {} });
  });
  after(async () => {
    await client.down(target).catch(() => {});
    await daemon.stop("SIGTERM");
  });

  const read = (file: string) => execIn(client, target, "box", ["cat", `/src/${file}`]);
  const rounds = 30;

  /** 每轮都是：容器里刚读过，宿主机改，马上再读（不清缓存时几乎每轮都错） */
  async function expectFresh(file: string, write: (full: string, text: string, k: number) => void, text: (k: number) => string) {
    const full = path.join(src, file);
    write(full, "seed", -1);
    for (let k = 0; k < rounds; k++) {
      await read(file);
      write(full, text(k), k);
      const got = await read(file);
      assert.equal(got.exitCode, 0, `第 ${k} 轮读不到`);
      assert.equal(got.stdout, text(k), `第 ${k} 轮内容不对`);
    }
  }

  test("写临时文件再改名（很多编辑器这样存）", () =>
    expectFresh(
      "renamed.txt",
      (full, text, k) => {
        writeFileSync(`${full}.tmp${k}`, text);
        renameSync(`${full}.tmp${k}`, full);
      },
      (k) => `v${k}#${"x".repeat(100 + k * 100)}`,
    ));

  test("原地改写，变长", () =>
    expectFresh("grown.txt", (full, text) => writeFileSync(full, text), (k) => `v${k}#${"x".repeat(100 + k * 100)}`));

  test("原地改写，长度不变", () =>
    expectFresh(
      "same.txt",
      (full, text) => writeFileSync(full, text),
      (k) => `v${String(k).padStart(3, "0")}#${"x".repeat(300)}`,
    ));

  test("git 切换版本", async () => {
    const r = path.join(src, "g");
    mkdirSync(r);
    const git = (...args: string[]) =>
      execFileSync("git", ["-C", r, "-c", "user.name=t", "-c", "user.email=t@t", ...args], { stdio: "ignore" });
    git("init", "-q");
    writeFileSync(path.join(r, "code.txt"), "A".repeat(50));
    git("add", ".");
    git("commit", "-qm", "a");
    writeFileSync(path.join(r, "code.txt"), "B".repeat(500));
    git("commit", "-qam", "b");
    await read("g/code.txt");
    for (let k = 0; k < rounds; k++) {
      const older = k % 2 === 0;
      git("checkout", "-q", older ? "HEAD~1" : "-");
      assert.equal((await read("g/code.txt")).stdout, older ? "A".repeat(50) : "B".repeat(500), `第 ${k} 轮内容不对`);
    }
  });

  test("文件被容器里的进程打开着（已知的边界）：清不掉，等约 1 秒后读到新内容", async () => {
    const full = path.join(src, "held.txt");
    writeFileSync(full, "old");
    await execIn(client, target, "box", ["sh", "-c", "(exec 3</src/held.txt; sleep 30) >/dev/null 2>&1 &"]);
    await delay(300);
    writeFileSync(`${full}.tmp`, "new");
    renameSync(`${full}.tmp`, full);
    await delay(1200);
    assert.equal((await read("held.txt")).stdout, "new");
  });
});

describe("单文件挂载", { concurrency: false }, () => {
  // box 挂三个单独的文件（两个在同一个目录里，一个只读，一个盖住镜像里已有的文件），另挂一个目录、并把一个文件挂到这个目录里面；
  // peer 把 box 那两个文件所在的目录整个挂上，再单独挂一个 box 也挂了的文件
  const directory = repo(
    "file-mount/repo",
    `services:
  box:
    image: node:22-alpine
    command: ["sleep", "100000"]
    volumes:
      - ./conf/app.json:/etc/napbox-test/app.json
      - ./conf/locked.json:/etc/napbox-test/locked.json:ro
      - ./other/release:/etc/alpine-release:ro
      - ./src:/src
      - ./other/inside.txt:/src/inside.txt
    secrets: [db_password]
    stop_grace_period: 1s
  peer:
    image: node:22-alpine
    command: ["sleep", "100000"]
    volumes: ["./conf:/conf", "./other/release:/etc/release-in-peer"]
    stop_grace_period: 1s
secrets:
  db_password:
    file: ./keys/db.password
`,
  );
  // secrets 的文件不存在：起不来，也不能像普通挂载那样在宿主机上建出一个目录
  const missingSecret = repo(
    "file-mount/missing-secret",
    `services:
  box:
    image: node:22-alpine
    command: ["sleep", "100000"]
    secrets: [db_password]
    stop_grace_period: 1s
secrets:
  db_password:
    file: ./keys/db.password
`,
  );
  const target: EnvironmentTarget = { cwd: directory };
  const host = (relative: string) => path.join(directory, relative);
  let daemon: Daemon;
  let client: NapboxClient;

  before(async () => {
    for (const dir of ["conf", "other", "src", "keys"]) mkdirSync(host(dir));
    writeFileSync(host("keys/db.password"), "s3cret\n");
    writeFileSync(host("conf/app.json"), '{"v":1}\n');
    writeFileSync(host("conf/locked.json"), '{"locked":true}\n');
    writeFileSync(host("conf/not-mounted.txt"), "secret\n");
    writeFileSync(host("other/release"), "napbox\n");
    writeFileSync(host("other/inside.txt"), "inside\n");
    writeFileSync(host("src/a.txt"), "a\n");
    daemon = await startDaemon(support, log);
    client = daemon.client;
    await client.up({ cwd: directory, environment: {} });
  });
  after(async () => {
    await client.down(target).catch(() => {});
    await daemon.stop("SIGTERM");
  });

  async function sh(service: string, command: string): Promise<string> {
    const { exitCode, stdout } = await execIn(client, target, service, ["sh", "-c", command]);
    assert.equal(exitCode, 0, `${service}: ${command}\n${stdout}`);
    return stdout;
  }
  const code = async (service: string, command: string) => (await execIn(client, target, service, ["sh", "-c", command])).exitCode;

  test("内容和宿主机一样：镜像里没有的路径建出来，已有的文件被盖住，挂到目录挂载里面也行；同目录里没挂的文件看不到", async () => {
    assert.equal(await sh("box", "cat /etc/napbox-test/app.json"), '{"v":1}\n');
    assert.equal(await sh("box", "cat /etc/napbox-test/locked.json"), '{"locked":true}\n');
    assert.equal(await sh("box", "cat /etc/alpine-release"), "napbox\n");
    assert.equal(await sh("box", "cat /src/inside.txt"), "inside\n");
    assert.equal(await sh("box", "cat /src/a.txt"), "a\n");
    assert.equal(await sh("box", "ls /etc/napbox-test"), "app.json\nlocked.json\n");
    assert.equal(await sh("box", "stat -c %F /etc/napbox-test/app.json"), "regular file\n");
    // 共享的是文件所在的目录，但容器里只绑定了这一个文件
    assert.equal(await sh("box", "grep -c not-mounted /proc/self/mountinfo; find / -xdev -name not-mounted.txt | wc -l"), "0\n0\n");
  });

  test("可写的：容器里改，宿主机和另一个服务都看得到；只读的：容器里写不了", async () => {
    await sh("box", "echo from-box > /etc/napbox-test/app.json");
    assert.equal(readFileSync(host("conf/app.json"), "utf8"), "from-box\n");
    assert.equal(await sh("peer", "cat /conf/app.json"), "from-box\n");
    await sh("peer", "echo from-peer > /conf/app.json");
    assert.equal(await sh("box", "cat /etc/napbox-test/app.json"), "from-peer\n");
    for (const file of ["/etc/napbox-test/locked.json", "/etc/alpine-release"]) {
      assert.notEqual(await code("box", `echo x > ${file}`), 0, `${file} 应该写不了`);
    }
    assert.equal(readFileSync(host("conf/locked.json"), "utf8"), '{"locked":true}\n');
    assert.equal(readFileSync(host("other/release"), "utf8"), "napbox\n");
  });

  test("secrets：文件只读挂在 /run/secrets/<名字>，没声明要用的服务看不到（和 Docker 一样）", async () => {
    assert.equal(await sh("box", "cat /run/secrets/db_password"), "s3cret\n");
    assert.equal(await sh("box", "ls /run/secrets"), "db_password\n");
    assert.notEqual(await code("box", "echo x > /run/secrets/db_password"), 0, "应该写不了");
    assert.equal(readFileSync(host("keys/db.password"), "utf8"), "s3cret\n");
    assert.notEqual(await code("peer", "test -e /run/secrets"), 0, "peer 没写 secrets，不该有");
  });

  test("secrets 的文件不存在：up 报错说清是哪个文件，宿主机上不多出东西", async () => {
    const file = path.join(missingSecret, "keys/db.password");
    const error = await rejectsWithCode(client.up({ cwd: missingSecret, environment: {} }), "compose_invalid");
    assert.match(error.message, /secrets 文件 .*keys\/db\.password 不存在/);
    assert.equal(existsSync(file), false);
    assert.equal(existsSync(path.dirname(file)), false);
    await rejectsWithCode(client.environment({ cwd: missingSecret }), "environment_not_found");
  });

  // up 一上来查的那次拦不到这里：唤醒不经过 up，靠的是起容器时再查的那一次
  test("休眠期间 secrets 的文件没了：唤醒报错说清是哪个文件，环境还在、还是休眠；文件放回去就能唤醒", async () => {
    const other: EnvironmentTarget = { cwd: missingSecret };
    const file = path.join(missingSecret, "keys/db.password");
    mkdirSync(path.dirname(file));
    writeFileSync(file, "s3cret\n");
    try {
      assert.equal((await client.up({ cwd: missingSecret, environment: {} })).state, "running");
      assert.equal((await client.sleep(other)).state, "sleeping");
      rmSync(file);
      const error = await rejectsWithCode(client.wake(other), "compose_invalid");
      assert.match(error.message, /secrets 文件 .*keys\/db\.password 不存在/);
      assert.equal(existsSync(file), false, "不该像普通挂载那样建出东西");
      assert.equal((await client.environment(other)).state, "sleeping");
      writeFileSync(file, "back\n");
      assert.equal((await client.wake(other)).state, "running");
      const { exitCode, stdout } = await execIn(client, other, "box", ["cat", "/run/secrets/db_password"]);
      assert.equal(exitCode, 0, stdout);
      assert.equal(stdout, "back\n");
    } finally {
      await client.down(other).catch(() => {});
    }
  });

  test("宿主机原地改写：马上 exec 读到新内容", async () => {
    for (let k = 0; k < 20; k++) {
      await sh("box", "cat /etc/napbox-test/app.json /etc/napbox-test/locked.json");
      const text = `v${k}#${"x".repeat(50 + k * 200)}`;
      writeFileSync(host("conf/app.json"), text);
      writeFileSync(host("conf/locked.json"), text);
      assert.equal(await sh("box", "cat /etc/napbox-test/app.json"), text, `第 ${k} 轮`);
      assert.equal(await sh("box", "cat /etc/napbox-test/locked.json"), text, `第 ${k} 轮（只读的）`);
    }
  });

  // 在 box 里监听这个文件，等它准备好了做 change，返回监听的程序读到的内容；10 秒没收到通知就失败
  async function watched(inside: string, change: () => void): Promise<string> {
    const script = `const fs=require('fs');const f=${JSON.stringify(inside)};
fs.watch(f,()=>{console.log('got '+fs.readFileSync(f,'utf8'));process.exit(0)});
setTimeout(()=>process.exit(3),10000);console.log('ready')`;
    let output = "";
    let ready!: () => void;
    const watching = new Promise<void>((resolve) => {
      ready = resolve;
    });
    const running = client.exec({
      target,
      service: "box",
      command: ["node", "-e", script],
      onOutput: (o) => {
        output += Buffer.from(o.data).toString();
        if (output.includes("ready")) ready();
      },
    });
    await watching;
    change();
    const { exitCode } = await running;
    assert.equal(exitCode, 0, `${inside} 没收到通知：${output}`);
    return output.slice(output.indexOf("got ") + 4);
  }

  test("宿主机原地改写：容器里监听这个文件的程序收到通知，读到的是新内容（只读的也一样）", async () => {
    for (const [relative, inside] of [
      ["conf/app.json", "/etc/napbox-test/app.json"],
      ["conf/locked.json", "/etc/napbox-test/locked.json"],
      ["other/release", "/etc/alpine-release"],
    ] as const) {
      assert.equal(await watched(inside, () => writeFileSync(host(relative), `watched ${relative}`)), `watched ${relative}\n`);
    }
  });

  // 先写临时文件再改名，原来那个文件就没了：编辑器、git、agent 的写文件工具都这么保存
  function replace(relative: string, text: string) {
    writeFileSync(host(`${relative}.tmp`), text);
    renameSync(host(`${relative}.tmp`), host(relative));
  }
  const files = [
    ["conf/app.json", "/etc/napbox-test/app.json"],
    ["conf/locked.json", "/etc/napbox-test/locked.json"],
    ["other/release", "/etc/alpine-release"],
    ["other/inside.txt", "/src/inside.txt"],
  ] as const;
  const readOnly = ["/etc/napbox-test/locked.json", "/etc/alpine-release"];

  test("宿主机把文件整个换掉（改名覆盖）：马上 exec 读到新文件的内容，换几次都一样，挂载不会越叠越多", async () => {
    // 生效的那一层挂载（最上面那层）除了编号以外的信息：是哪个设备上的哪个文件、挂在哪、只读还是可写、怎么传播。
    // 只读的文件刚启动时是两层（框架先挂一层可写的，再盖一层只读的），换过以后是一层只读的
    const mounted = (inside: string) => sh("box", `grep ' ${inside} ' /proc/self/mountinfo | tail -n 1 | cut -d' ' -f3-`);
    const before = await Promise.all(files.map(([, inside]) => mounted(inside)));
    for (let round = 0; round < 3; round++) {
      for (const [relative, inside] of files) {
        // 先读一次：这时虚拟机记着这个名字对应的是马上要被换掉的那个文件
        await sh("box", `cat ${inside}`);
        replace(relative, `replaced ${round} ${relative}\n`);
        assert.equal(await sh("box", `cat ${inside}`), `replaced ${round} ${relative}\n`, `第 ${round} 轮 ${inside}`);
      }
    }
    for (const [index, [, inside]] of files.entries()) {
      assert.equal(await sh("box", `grep -c ' ${inside} ' /proc/self/mountinfo`), "1\n", `${inside} 上的挂载数`);
      assert.equal(await mounted(inside), before[index], `${inside} 生效的挂载应该和换之前一样`);
    }
    // other/release 还挂在 peer 里，peer 挂了整个 conf 目录
    assert.equal(await sh("peer", "cat /etc/release-in-peer /conf/app.json"), "replaced 2 other/release\nreplaced 2 conf/app.json\n");
  });

  test("换掉以后：可写的还是通到宿主机现在那个文件，只读的还是写不了，之后的原地改写照样读得到、收得到通知", async () => {
    await sh("box", "echo from-box-again > /etc/napbox-test/app.json");
    assert.equal(readFileSync(host("conf/app.json"), "utf8"), "from-box-again\n");
    for (const file of readOnly) assert.notEqual(await code("box", `echo x > ${file}`), 0, `${file} 应该写不了`);
    assert.equal(readFileSync(host("conf/locked.json"), "utf8"), "replaced 2 conf/locked.json\n");
    assert.equal(readFileSync(host("other/release"), "utf8"), "replaced 2 other/release\n");
    for (const [relative, inside] of files) {
      writeFileSync(host(relative), `in place ${relative}\n`);
      assert.equal(await sh("box", `cat ${inside}`), `in place ${relative}\n`);
    }
    for (const [relative, inside] of files.slice(0, 3)) {
      assert.equal(await watched(inside, () => writeFileSync(host(relative), `watched again ${relative}`)), `watched again ${relative}\n`);
    }
  });

  test("换掉以后同时来 30 条 exec：每一条读到的都是新内容", async () => {
    await sh("box", "cat /etc/napbox-test/app.json /etc/napbox-test/locked.json");
    replace("conf/app.json", "many-a\n");
    replace("conf/locked.json", "many-b\n");
    const results = await Promise.all(
      Array.from({ length: 30 }, () => execIn(client, target, "box", ["sh", "-c", "cat /etc/napbox-test/app.json /etc/napbox-test/locked.json"])),
    );
    for (const result of results) assert.deepEqual(result, { exitCode: 0, stdout: "many-a\nmany-b\n" });
    assert.equal(await sh("box", "grep -c ' /etc/napbox-test/app.json ' /proc/self/mountinfo"), "1\n");
  });

  test("宿主机删掉这个文件：容器里读不了；再建出来：读到新建的", async () => {
    await sh("box", "cat /etc/napbox-test/app.json");
    rmSync(host("conf/app.json"));
    assert.notEqual(await code("box", "cat /etc/napbox-test/app.json"), 0);
    writeFileSync(host("conf/app.json"), "created-again\n");
    assert.equal(await sh("box", "cat /etc/napbox-test/app.json"), "created-again\n");
  });

  test("休眠再唤醒：挂的是宿主机现在的文件，之后再换照样读到新的", async () => {
    await client.sleep(target);
    replace("conf/locked.json", "replaced-while-asleep\n");
    assert.equal(await sh("box", "cat /etc/napbox-test/app.json /etc/napbox-test/locked.json"), "created-again\nreplaced-while-asleep\n");
    replace("conf/locked.json", "replaced-after-wake\n");
    assert.equal(await sh("box", "cat /etc/napbox-test/locked.json"), "replaced-after-wake\n");
    assert.notEqual(await code("box", "echo x > /etc/napbox-test/locked.json"), 0);
  });

  test("同一个服务既挂目录、又挂这个目录里的文件：直接报错，不悄悄少一条挂载", async () => {
    const both = repo(
      "file-mount/both",
      `services:
  box:
    image: node:22-alpine
    command: ["sleep", "100000"]
    volumes: ["./conf:/conf", "./conf/app.json:/etc/app.json"]
`,
    );
    mkdirSync(path.join(both, "conf"));
    writeFileSync(path.join(both, "conf/app.json"), "{}\n");
    const error = await rejectsWithCode(client.up({ cwd: both, environment: {} }), "compose_unsupported");
    assert.match(error.message, /同时挂了目录 .*conf 和它里面的文件 .*app\.json/);
    await rejectsWithCode(client.environment({ cwd: both }), "environment_not_found");
  });
});

describe("新的命名卷带上镜像里那个目录的内容", { concurrency: false }, () => {
  // plain 不挂卷，用来看镜像里本来是什么样；second 把 seeded 已经带上内容的卷挂到另一个路径
  const compose = (environment = "") => `services:
  seeded:
    image: node:22-alpine
    command: ["sleep", "100000"]${environment}
    volumes:
      - home:/home/node
      - local:/usr/local
      - yarn:/opt
      - absent:/not/in/image
      - ssl:/etc/ssl:ro
    stop_grace_period: 1s
  second:
    image: node:22-alpine
    command: ["sleep", "100000"]
    volumes: ["local:/opt"]
    depends_on: [seeded]
    stop_grace_period: 1s
  plain:
    image: node:22-alpine
    command: ["sleep", "100000"]
    stop_grace_period: 1s
volumes:
  home:
  local:
  yarn:
  absent:
  ssl:
`;
  const directory = repo("seed/repo", compose());
  const target: EnvironmentTarget = { cwd: directory };
  let daemon: Daemon;
  let client: NapboxClient;

  before(async () => {
    daemon = await startDaemon(support, log);
    client = daemon.client;
    await client.up({ cwd: directory, environment: {} });
  });
  after(async () => {
    await client.down(target).catch(() => {});
    await daemon.stop("SIGTERM");
  });

  async function sh(service: string, script: string): Promise<string> {
    const result = await execIn(client, target, service, ["sh", "-c", script]);
    assert.equal(result.exitCode, 0, `${service} 里 ${script} 退出码 ${result.exitCode}：${result.stdout}`);
    return result.stdout;
  }
  /** 目录里每一项的属主、权限、类型、硬链接数、修改时间、链接指向，文件再加大小；目录的大小跟文件系统怎么分配有关，不比 */
  async function listing(service: string, dir: string): Promise<string[]> {
    const out = await sh(service, `cd ${dir} && find . -print0 | sort -z | xargs -0 stat -c '%n|%u:%g|%a|%F|%h|%Y|%N|%s'`);
    return out
      .trimEnd()
      .split("\n")
      .map((line) => (line.split("|")[3] === "directory" ? line.slice(0, line.lastIndexOf("|")) : line));
  }
  const contentHash = (service: string, dir: string) =>
    sh(service, `cd ${dir} && find . -type f -print0 | sort -z | xargs -0 sha256sum | sha256sum`);
  const entries = async (service: string, dir: string) => (await sh(service, `ls -A ${dir}`)).split("\n").filter(Boolean);

  test("内容、属主、权限、时间、符号链接都和镜像里一样", async () => {
    for (const dir of ["/home/node", "/usr/local", "/opt", "/etc/ssl"]) {
      const want = await listing("plain", dir);
      assert.deepEqual(await listing("seeded", dir), want, dir);
      assert.equal(await contentHash("seeded", dir), await contentHash("plain", dir), `${dir} 的文件内容`);
    }
    // 确认比的不是两边都空：node 和 npm 在里面，有上千个文件，也有符号链接（bin/npm）
    const local = await listing("seeded", "/usr/local");
    assert.ok(local.length > 1000, `/usr/local 只有 ${local.length} 项`);
    assert.ok(local.some((line) => line.split("|")[3] === "symbolic link"));
    assert.match(await sh("seeded", "mount | grep ' /usr/local '"), /^\/dev\/vd/);
    assert.equal((await sh("seeded", "npm --version")).trim(), (await sh("plain", "npm --version")).trim());
  });

  test("卷的根目录是镜像里那个目录的属主和权限，镜像里是空目录也一样：镜像里的普通用户能写", async () => {
    assert.deepEqual(await entries("plain", "/home/node"), []);
    assert.equal(await sh("seeded", "stat -c '%u:%g %a' /home/node"), "1000:1000 2755\n");
    await sh("seeded", "su node -c 'echo hi > /home/node/mine && cat /home/node/mine'");
  });

  test("镜像里没有的路径：卷是空的；只读挂载的卷也带上内容，容器里写不了", async () => {
    assert.deepEqual(await entries("seeded", "/not/in/image"), []);
    assert.equal(await sh("seeded", "stat -c '%u:%g %a' /not/in/image"), "0:0 755\n");
    assert.ok((await entries("seeded", "/etc/ssl")).length > 0);
    assert.notEqual((await execIn(client, target, "seeded", ["touch", "/etc/ssl/x"])).exitCode, 0);
  });

  test("卷里已经有东西就不动：第二个服务把同一个卷挂到别的路径，看到的是第一个服务带上的内容", async () => {
    assert.deepEqual(await entries("second", "/opt"), await entries("plain", "/usr/local"));
    assert.notDeepEqual(await entries("plain", "/opt"), await entries("plain", "/usr/local"));
    assert.ok((await entries("plain", "/opt")).length > 0, "镜像里的 /opt 是空的，这条比不出东西");
  });

  test("清空的卷休眠唤醒后还是空的（和 docker stop、start 一样）；reset 之后重新带上", async () => {
    await sh("seeded", "find /opt -mindepth 1 -delete");
    await client.sleep(target);
    assert.deepEqual(await entries("seeded", "/opt"), []);
    await client.reset(target, ["yarn"]);
    assert.deepEqual(await listing("seeded", "/opt"), await listing("plain", "/opt"));
    // 别的卷没有跟着重新带
    assert.ok((await entries("seeded", "/home/node")).includes("mine"));
  });

  test("服务定义变了、容器重新建：空的卷重新带上，有东西的不动（和 Docker 重建容器一样）", async () => {
    await sh("seeded", "find /opt -mindepth 1 -delete");
    writeFileSync(path.join(directory, "compose.yaml"), compose('\n    environment: {CHANGED: "1"}'));
    await client.up({ cwd: directory, environment: {} });
    assert.equal(await sh("seeded", "echo $CHANGED"), "1\n");
    assert.deepEqual(await listing("seeded", "/opt"), await listing("plain", "/opt"));
    assert.ok((await entries("seeded", "/home/node")).includes("mine"));
  });
});

describe("每个服务自己的网络", { concurrency: false }, () => {
  // one 和 two 都监听 80；two 晚 4 秒才开始监听；idle 什么都不监听。地址按服务名排序给：idle .2、one .3、two .4
  const listen = (words: string) => `while true; do echo ${words} | nc -l -p 80; done`;
  const compose = `services:
  one:
    image: alpine:3.20
    command: ["sh", "-c", "${listen("from-one")}"]
    ports: ["80"]
    stop_grace_period: 1s
  two:
    image: alpine:3.20
    command: ["sh", "-c", "sleep 4; ${listen("from-two")}"]
    ports: ["80"]
    stop_grace_period: 1s
  idle:
    image: alpine:3.20
    command: ["sleep", "infinity"]
    stop_grace_period: 1s
`;
  const target: EnvironmentTarget = { name: "codeos/networks", owner: "codeos" };
  const ports = new Map<string, number>();
  let daemon: Daemon;
  let client: NapboxClient;

  before(async () => {
    daemon = await startDaemon(support, log);
    client = daemon.client;
  });
  after(async () => {
    await client.down(target).catch(() => {});
    await daemon.stop("SIGTERM");
  });

  /** 从宿主机连这个服务的端口，读到对方关闭 */
  function fromHost(service: string): Promise<string> {
    return new Promise((resolve, reject) => {
      const socket = connect(ports.get(service) as number, "127.0.0.1");
      let got = "";
      socket.setEncoding("utf8");
      socket.on("data", (d) => (got += d));
      socket.on("close", () => resolve(got.trim()));
      socket.on("error", reject);
    });
  }
  /** 在一个服务里连另一个地址的 80 端口，返回收到的内容；连不上是空的 */
  const fromService = async (service: string, host: string) =>
    (await execIn(client, target, service, ["sh", "-c", `nc -w 3 ${host} 80 </dev/null 2>/dev/null; true`])).stdout.trim();
  /** nc 接完一个连接要重新监听，中间有一小段连不上，所以等到收到为止 */
  const eventually = (what: string, read: () => Promise<string>, expected: string) =>
    waitUntil(`${what} 收到 ${expected}`, async () => (await read()) === expected, 15_000);

  test("两个服务都监听 80 端口：环境起得来，宿主机上各自的端口连到各自的服务", async () => {
    const info = await client.create({ ...target, directory: repo("networks", compose) });
    assert.equal(info.state, "running");
    for (const port of info.ports) ports.set(port.service, port.hostPort);
    assert.deepEqual([...ports.keys()].sort(), ["one", "two"]);
    // 等端口监听只看这个服务自己：two 晚 4 秒才监听，create 返回时它已经在听了，第一次连就有内容。
    // 服务共用网络时 one 的 80 会被当成 two 的，create 提前返回，这里连不上
    assert.equal(await fromHost("two"), "from-two");
    await eventually("宿主机连 one", () => fromHost("one"), "from-one");
  });

  test("服务之间用服务名互相连，连到的是对方", async () => {
    await eventually("one 连 two", () => fromService("one", "two"), "from-two");
    await eventually("two 连 one", () => fromService("two", "one"), "from-one");
    await eventually("idle 连 one", () => fromService("idle", "one"), "from-one");
    await eventually("idle 连 two", () => fromService("idle", "two"), "from-two");
  });

  test("每个服务有自己的地址，服务名指到它；自己的 localhost 上没有别的服务，和 Docker 一样", async () => {
    const hosts = (await execIn(client, target, "idle", ["cat", "/etc/hosts"])).stdout;
    for (const line of ["10.88.0.2 idle", "10.88.0.3 one", "10.88.0.4 two"]) {
      assert.ok(hosts.split("\n").some((l) => l.trim().split(/\s+/).join(" ") === line), hosts);
    }
    const address = (await execIn(client, target, "one", ["ip", "-4", "-o", "addr", "show", "eth0"])).stdout;
    assert.match(address, /inet 10\.88\.0\.3\/24/);
    assert.equal(await fromService("idle", "127.0.0.1"), "");
    await eventually("one 连自己的 localhost", () => fromService("one", "127.0.0.1"), "from-one");
  });

  test("休眠再唤醒：地址不变，服务名互连和宿主机端口照常", async () => {
    await client.sleep(target);
    await client.wake(target);
    const address = (await execIn(client, target, "two", ["ip", "-4", "-o", "addr", "show", "eth0"])).stdout;
    assert.match(address, /inet 10\.88\.0\.4\/24/);
    await eventually("idle 连 two", () => fromService("idle", "two"), "from-two");
    await eventually("宿主机连 one", () => fromHost("one"), "from-one");
    await eventually("宿主机连 two", () => fromHost("two"), "from-two");
  });
});

describe("x86 的程序", { concurrency: false }, () => {
  // 镜像是 arm64 的，里面的程序是给 x86 编的（比如 Dockerfile 里写死 GOARCH=amd64）。Docker Desktop 里能跑，这里也要能跑：
  // 虚拟机开着 Rosetta。没开的时候是 exec format error，服务起不来
  const target: EnvironmentTarget = { name: "codeos/x86", owner: "codeos" };
  let daemon: Daemon;
  let client: NapboxClient;
  let directory: string;

  before(async () => {
    const bin = path.join(work, "x86-bin");
    mkdirSync(bin);
    execFileSync("go", ["build", "-o", path.join(bin, "program"), path.join(import.meta.dirname, "x86-program.go")], {
      env: { ...process.env, GOOS: "linux", GOARCH: "amd64", CGO_ENABLED: "0", GOTOOLCHAIN: "local" },
    });
    daemon = await startDaemon(support, log);
    client = daemon.client;
    directory = repo("x86", `services:
  main:
    image: alpine:3.20
    command: ["/x/program", "stay"]
    volumes: ["${bin}:/x"]
    stop_grace_period: 1s
`);
  });
  after(async () => {
    await client.down(target).catch(() => {});
    await daemon.stop("SIGTERM");
  });

  /** main 的日志里，主程序启动时打的那一行有几行。日志跨休眠保留，每启动一次多一行 */
  async function mainStarts() {
    const chunks: Buffer[] = [];
    await client.logs({
      target,
      service: "main",
      onOutput: (o) => {
        chunks.push(Buffer.from(o.data));
      },
    });
    return Buffer.concat(chunks).toString().match(/^arch=amd64$/gm)?.length ?? 0;
  }

  /** main 的主程序在跑：到现在一共启动了 starts 次（每次都打出了那一行），没有退出记录 */
  async function mainIsRunning(starts: number) {
    await waitUntil(`main 的日志里有 ${starts} 行 arch=amd64`, async () => (await mainStarts()) >= starts, 5_000);
    assert.equal(await mainStarts(), starts);
    assert.deepEqual((await client.environment(target)).serviceExits, []);
  }

  test("服务的主程序是 x86 的：环境起得来，它一直在跑", async () => {
    assert.equal((await client.create({ ...target, directory })).state, "running");
    await mainIsRunning(1);
  });

  test("exec 跑 x86 的程序：能跑，退出码正常；虚拟机本身是 arm64 的", async () => {
    assert.deepEqual(await execIn(client, target, "main", ["/x/program"]), { exitCode: 0, stdout: "arch=amd64\n" });
    assert.equal((await execIn(client, target, "main", ["uname", "-m"])).stdout, "aarch64\n");
  });

  test("休眠再唤醒：照样能跑", async () => {
    await client.sleep(target);
    await client.wake(target);
    await mainIsRunning(2);
    assert.deepEqual(await execIn(client, target, "main", ["/x/program"]), { exitCode: 0, stdout: "arch=amd64\n" });
  });
});

describe("端口转发", { concurrency: false }, () => {
  let daemon: Daemon;
  let client: NapboxClient;
  const target = { name: "codeos/forward", owner: "codeos" };
  const ports = new Map<number, number>();

  before(async () => {
    const bin = path.join(work, "forward-bin");
    mkdirSync(bin);
    const source = path.join(import.meta.dirname, "relay-server.go");
    execFileSync("go", ["build", "-o", path.join(bin, "relay-server"), source], {
      env: { ...process.env, GOOS: "linux", GOARCH: "arm64", CGO_ENABLED: "0", GOTOOLCHAIN: "local" },
    });
    daemon = await startDaemon(support, log);
    client = daemon.client;
    const directory = repo("forward", `services:
  relay:
    image: alpine:3.20
    command: ["/x/relay-server"]
    volumes: ["${bin}:/x"]
    ports: ["8080", "8081", "8082", "8083", "8084"]
    stop_grace_period: 1s
`);
    const info = await client.create({ ...target, directory });
    for (const port of info.ports) ports.set(port.containerPort, port.hostPort);
  });

  after(async () => {
    await client.down(target);
    await daemon.stop("SIGTERM");
  });

  /** 读到对方关闭，返回全部内容 */
  function readAll(port: number, send?: Buffer): Promise<Buffer> {
    return new Promise((resolve, reject) => {
      const socket = connect(ports.get(port) as number, "127.0.0.1");
      const chunks: Buffer[] = [];
      socket.on("data", (chunk) => chunks.push(chunk as Buffer));
      socket.on("close", () => resolve(Buffer.concat(chunks)));
      socket.on("error", reject);
      // 写完半关闭：对方要能读到结尾，还能继续把数据发回来
      if (send) socket.end(send);
    });
  }

  const sha = (data: Buffer) => createHash("sha256").update(data).digest("hex");
  const rss = () =>
    Number(execFileSync("ps", ["-o", "rss=", "-p", String(daemon.process.pid)], { encoding: "utf8" })) / 1024;

  test("大数据双向转发内容不错，半关闭传得过去", async () => {
    const data = Buffer.alloc(32 * 1024 * 1024);
    for (let i = 0; i < data.length; i += 1024) data.writeUInt32LE(i * 2654435761 % 2 ** 32, i);
    const echoed = await readAll(8080, data);
    assert.equal(echoed.length, data.length);
    assert.equal(sha(echoed), sha(data));
  });

  // 来源是虚拟机在服务那个网段里的地址（10.88.0.1），和 Docker 下看到网桥的地址一样
  test("服务看到的来源不是本机地址：pg_hba 这类规则和 Docker 一样生效", async () => {
    const seen = (await readAll(8081)).toString();
    assert.match(seen, /^10\.88\.0\.1$/);
  });

  test("只听 127.0.0.1 的服务转发不过来，和 Docker 一样；连接直接断开，不影响别的连接", async () => {
    assert.equal((await readAll(8083)).length, 0);
    assert.equal((await readAll(8081)).length > 0, true);
  });

  test("客户端读得慢时 napboxd 内存不涨，不影响同一环境的其他连接，内容不丢", async () => {
    const before = rss();
    const socket = connect(ports.get(8082) as number, "127.0.0.1");
    socket.pause();
    await new Promise((resolve) => socket.once("connect", resolve));
    await delay(3_000);
    const during = rss();
    assert.ok(during - before < 32, `内存涨了 ${during - before}MB`);
    const started = Date.now();
    assert.ok((await readAll(8081)).length > 0);
    assert.ok(Date.now() - started < 2_000, "别的连接被堵住了");
    let received = 0;
    await new Promise<void>((resolve, reject) => {
      socket.on("data", (chunk) => (received += chunk.length));
      socket.on("close", () => resolve());
      socket.on("error", reject);
      socket.resume();
    });
    assert.equal(received, 64 * 1024 * 1024);
  });

  test("同时 1000 条连接都能用，虚拟机没事（一个连接一条 vsock 时不到 300 条就崩）", async () => {
    // 分批打开：macOS 的监听队列上限 128（kern.ipc.somaxconn），同一瞬间发 1000 条，
    // 普通的本机服务也会偶尔收到 ECONNRESET（40 轮 2 轮），和转发无关。这里要测的是 1000 条同时开着。
    const sockets: ReturnType<typeof connect>[] = [];
    const open = (i: number) =>
      new Promise<ReturnType<typeof connect>>((resolve, reject) => {
        const socket = connect(ports.get(8080) as number, "127.0.0.1");
        socket.setEncoding("utf8");
        socket.once("connect", () => socket.write(`hi${i}`));
        socket.once("data", (text) => (text === `hi${i}` ? resolve(socket) : reject(new Error(String(text)))));
        socket.once("error", reject);
      });
    for (let start = 0; start < 1000; start += 100) {
      sockets.push(...(await Promise.all(Array.from({ length: 100 }, (_, i) => open(start + i)))));
    }
    assert.equal((await client.environment(target)).state, "running");
    for (const socket of sockets) socket.destroy();
    assert.equal(await execIn(client, target, "relay", ["echo", "ok"]).then((r) => r.stdout.trim()), "ok");
  });

  test("休眠断开连接，再连接自动唤醒后转发照常", async () => {
    const socket = connect(ports.get(8080) as number, "127.0.0.1");
    await new Promise((resolve) => socket.once("connect", resolve));
    const closed = new Promise((resolve) => socket.once("close", resolve));
    socket.on("error", () => {});
    await delay(200);
    await client.sleep(target);
    await closed;
    assert.match((await readAll(8081)).toString(), /^10\.88\.0\.1$/);
    // 连接只等它连的服务：回话时环境可能还没起完
    await waitUntil("环境起完", async () => (await client.environment(target)).state === "running", 10_000);
  });

  test("网络小容器被撑爆后环境转成休眠，不留下看着在运行、其实连不上的环境；之后还能起来", async () => {
    await client.wake(target);
    const lost = () => readFileSync(log, "utf8").split("\n").filter((l) => l.includes("意外停了")).length;
    const lostBefore = lost();
    // 服务不读，每条连接都把额度发满，都积压在网络小容器里，超过它的内存上限。
    // 分批连：一次连太多会超过 macOS 的监听队列，被断开的连接就攒不出积压。
    // 等得久是因为测试用 debug 版：实测 17～58 秒才撑爆，机器忙时更久。
    const block = Buffer.alloc(2 * 1024 * 1024);
    const sockets: ReturnType<typeof connect>[] = [];
    for (let start = 0; start < 400; start += 100) {
      await Promise.all(
        Array.from({ length: 100 }, () =>
          new Promise<void>((resolve) => {
            const socket = connect(ports.get(8084) as number, "127.0.0.1");
            socket.on("error", () => resolve());
            socket.once("connect", () => resolve());
            socket.write(block);
            sockets.push(socket);
          }),
        ),
      );
    }
    await waitUntil("环境转成休眠", async () => (await client.environment(target)).state === "sleeping", 180_000);
    assert.equal(lost(), lostBefore + 1, "要是网络小容器挂了才转休眠，不是别的原因");
    for (const socket of sockets) socket.destroy();
    await client.wake(target);
    assert.match((await readAll(8081)).toString(), /^10\.88\.0\.1$/);
  });
});

describe("数据快照（x-napbox.seed）", { concurrency: false }, () => {
  // app 收到 TERM 马上退出：服务都按时退出、sync 成功才算正常停下，才拍快照
  const compose = `x-napbox: {seed: [data]}
services:
  init:
    image: alpine:3.20
    volumes: ["data:/data"]
    command: ["sh", "-c", "echo run >> /data/init-runs; sync"]
  app:
    image: alpine:3.20
    volumes: ["data:/data"]
    command: ["sh", "-c", "trap 'exit 0' TERM; while true; do sleep 0.2 & wait; done"]
    stop_grace_period: 1s
volumes:
  data:
`;
  const main = repo("seed/main", compose);
  const git = (...args: string[]) => execFileSync("git", ["-C", main, "-c", "user.name=t", "-c", "user.email=t@t", ...args]);
  git("add", "compose.yaml");
  git("commit", "-qm", "x");
  const branch = path.join(work, "seed/branch");
  const later = path.join(work, "seed/later");
  git("worktree", "add", "-q", "-b", "branch", branch);
  git("worktree", "add", "-q", "-b", "later", later);
  const lonely = repo("seed/lonely", compose);
  execFileSync("git", ["-C", lonely, "add", "compose.yaml"]);
  execFileSync("git", ["-C", lonely, "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qm", "x"]);
  const lonelyBranch = path.join(work, "seed/lonely-branch");
  execFileSync("git", ["-C", lonely, "worktree", "add", "-q", "-b", "b", lonelyBranch]);
  // app 在 /data/slow 存在时不理 TERM，过了 stop_grace_period 被强制结束：这次停下不算正常
  const slow = repo("seed/slow", `x-napbox: {seed: [data]}
services:
  app:
    image: alpine:3.20
    volumes: ["data:/data"]
    command: ["sh", "-c", "trap 'test -e /data/slow || exit 0' TERM; while true; do sleep 0.2 & wait; done"]
    stop_grace_period: 1s
volumes:
  data:
`);
  execFileSync("git", ["-C", slow, "add", "compose.yaml"]);
  execFileSync("git", ["-C", slow, "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qm", "x"]);
  const slowBranch = path.join(work, "seed/slow-branch");
  execFileSync("git", ["-C", slow, "worktree", "add", "-q", "-b", "b", slowBranch]);
  let daemon: Daemon;
  let client: NapboxClient;
  const at = (cwd: string): EnvironmentTarget => ({ cwd });
  const read = async (cwd: string) => (await execIn(client, at(cwd), "app", ["cat", "/data/v"])).stdout;
  const write = async (cwd: string, text: string) =>
    assert.equal((await execIn(client, at(cwd), "app", ["sh", "-c", `echo ${text} > /data/v; sync`])).exitCode, 0);

  before(async () => {
    daemon = await startDaemon(support, log);
    client = daemon.client;
  });

  after(async () => {
    for (const cwd of [branch, later, main, slowBranch, slow]) await client.down(at(cwd)).catch(() => {});
    await daemon.stop("SIGTERM");
  });

  test("主目录没有环境、还没正常停下过：新 worktree 报 snapshot_not_found，不登记", async () => {
    await rejectsWithCode(client.up({ cwd: lonelyBranch, environment: {} }), "snapshot_not_found");
    await rejectsWithCode(client.environment(at(lonelyBranch)), "environment_not_found");
    await client.up({ cwd: main, environment: {} });
    await write(main, "v1");
    await rejectsWithCode(client.up({ cwd: branch, environment: {} }), "snapshot_not_found");
  });

  test("主目录正常停下拍了快照；运行中再改，新 worktree 拿到的是快照时的数据，主目录没被打断", async () => {
    await client.sleep(at(main));
    await client.up({ cwd: main, environment: {} });
    await write(main, "v2");
    const runsBefore = (await client.runs(at(main))).runs.length;
    const info = await client.up({ cwd: branch, environment: {} });
    assert.equal(info.seededFrom?.environment, (await client.environment(at(main))).name);
    assert.deepEqual(info.seededFrom?.volumes, ["data"]);
    assert.equal(await read(branch), "v1\n");
    const run = (await client.runs(at(branch))).runs.at(-1);
    assert.equal(run?.purpose, "up");
    assert.equal(run?.seededFrom?.environment, info.seededFrom?.environment);
    // 一次性服务在复制来的数据上又跑了一次
    assert.equal((await execIn(client, at(branch), "app", ["cat", "/data/init-runs"])).stdout, "run\nrun\n");
    // 主目录全程在跑：没有新的启动记录，数据是它自己的
    assert.equal((await client.environment(at(main))).state, "running");
    assert.equal((await client.runs(at(main))).runs.length, runsBefore);
    assert.equal(await read(main), "v2\n");
  });

  test("两边各写各的；再 up 不再复制", async () => {
    await write(branch, "branch");
    assert.equal(await read(main), "v2\n");
    const again = await client.up({ cwd: branch, environment: {} });
    assert.equal(again.seededFrom, undefined);
    assert.equal(await read(branch), "branch\n");
  });

  test("reset --from：换成主目录最新的快照，旧卷进 recycled；不带 from 是换成空的", async () => {
    await client.sleep(at(main)); // 拍下 v2
    await rejectsWithCode(client.reset(at(branch), ["data"], { from: branch }), "bad_request");
    await rejectsWithCode(client.reset(at(branch), ["nope"], { from: main }), "volume_not_found");
    const info = await client.reset(at(branch), ["data"], { from: main });
    assert.deepEqual(info.seededFrom?.volumes, ["data"]);
    assert.equal(await read(branch), "v2\n");
    assert.equal((await client.runs(at(branch))).runs.at(-1)?.purpose, "reset");
    assert.equal((await client.environment(at(main))).state, "sleeping", "复制不唤醒源环境");
    await client.reset(at(branch), ["data"]);
    assert.equal((await execIn(client, at(branch), "app", ["test", "-e", "/data/v"])).exitCode, 1);
  });

  test("没正常停下（napboxd 被强杀）不拍快照，留着上一份", async () => {
    await client.up({ cwd: main, environment: {} });
    await write(main, "v3");
    await daemon.stop("SIGKILL");
    daemon = await startDaemon(support, log);
    client = daemon.client;
    const info = await client.up({ cwd: later, environment: {} });
    assert.ok(info.seededFrom);
    assert.equal(await read(later), "v2\n");
  });

  test("服务过了 stop_grace_period 没退出：不拍快照，status 和 snapshot_not_found 写着是哪个服务；正常停下一次就清掉", async () => {
    await client.up({ cwd: slow, environment: {} });
    assert.equal((await execIn(client, at(slow), "app", ["sh", "-c", "touch /data/slow; sync"])).exitCode, 0);
    await client.sleep(at(slow));
    assert.match((await client.environment(at(slow))).snapshotError ?? "", /没拍成快照：app（等了 1 秒）过了 stop_grace_period/);
    const refused = await rejectsWithCode(client.up({ cwd: slowBranch, environment: {} }), "snapshot_not_found");
    assert.match(refused.message, /没拍成快照：app（等了 1 秒）过了 stop_grace_period.*按上面的原因处理好/s);

    await client.up({ cwd: slow, environment: {} });
    assert.equal((await execIn(client, at(slow), "app", ["sh", "-c", "rm /data/slow; sync"])).exitCode, 0);
    await client.sleep(at(slow));
    assert.equal((await client.environment(at(slow))).snapshotError, undefined);
    assert.ok((await client.up({ cwd: slowBranch, environment: {} })).seededFrom);
  });
});
