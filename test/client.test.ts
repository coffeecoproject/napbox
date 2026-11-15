// 不起虚拟机的部分：错误码原样带回、napboxd 没运行、退出和被强杀时怎么结束、回应看不懂时怎么报。
// 能用真实 napboxd 的都用真实的；只有真实 napboxd 发不出来的坏回应才用假服务端，放在最后一组。
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { existsSync, mkdirSync, mkdtempSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { createServer, type Socket } from "node:net";
import { tmpdir } from "node:os";
import path from "node:path";
import { after, before, describe, test } from "node:test";
import { NapboxClient, NapboxError } from "../src/client.ts";
import { errorCodes, methods, StatusResult } from "../src/protocol.ts";
import { type Daemon, delay, rawCall, rejectsWithCode, startDaemon, waitUntil } from "./support.ts";

const work = realpathSync(mkdtempSync(path.join(tmpdir(), "napbox-client-")));
after(() => rmSync(work, { recursive: true, force: true }));

function gitRepo(name: string, compose?: string): string {
  const dir = path.join(work, name);
  mkdirSync(dir, { recursive: true });
  execFileSync("git", ["init", "-q", dir]);
  if (compose !== undefined) writeFileSync(path.join(dir, "compose.yaml"), compose);
  return dir;
}

function supportDir(name: string): string {
  const dir = path.join(work, name);
  mkdirSync(dir, { recursive: true });
  return dir;
}

describe("真实 napboxd：请求和错误码", () => {
  let daemon: Daemon;
  let client: NapboxClient;
  const missing = { name: "codeos/not-here", owner: "codeos" };
  const createTarget = { name: "codeos/undefined", owner: "codeos" };

  before(async () => {
    daemon = await startDaemon(supportDir("errors"), path.join(work, "errors.log"));
    client = daemon.client;
  });
  after(() => daemon.stop("SIGTERM"));

  test("status 的结果和 napboxd 发的完全一样，没有丢字段", async () => {
    const raw = await rawCall(daemon.socketPath, methods.status);
    assert.deepEqual(StatusResult.parse(raw.result), raw.result);
    assert.equal((await client.status()).pid, daemon.process.pid);
  });

  test("协议里的每个方法 napboxd 都认识", async () => {
    for (const method of Object.values(methods)) {
      if (method === methods.status || method === methods.subscribe) continue; // 这两个 params 为空也能成功
      const raw = await rawCall(daemon.socketPath, method, {});
      assert.equal(raw.error?.code, "bad_request", method);
    }
    const unknown = await rawCall(daemon.socketPath, "no.such.method", {});
    assert.equal(unknown.error?.code, "unknown_method");
  });

  test("错误码和说明原样带给调用方", async () => {
    const error = await rejectsWithCode(client.environment(missing), "environment_not_found");
    const raw = await rawCall(daemon.socketPath, methods.environment, { target: missing });
    assert.equal(error.message, raw.error?.message);
    assert.ok(error instanceof Error);
    assert.equal(error.name, "NapboxError");
  });

  test("指定环境的方法都带 target，没有这个环境时都报 environment_not_found", async () => {
    await rejectsWithCode(client.wake(missing), "environment_not_found");
    await rejectsWithCode(client.sleep(missing), "environment_not_found");
    await rejectsWithCode(client.down(missing), "environment_not_found");
    await rejectsWithCode(client.runs(missing), "environment_not_found");
    await rejectsWithCode(client.egress(missing, "none"), "environment_not_found");
    await rejectsWithCode(client.reset(missing, ["data"]), "environment_not_found");
    const onOutput = () => assert.fail("不该有输出");
    await rejectsWithCode(
      client.logs({ target: missing, service: "app", onOutput }),
      "environment_not_found",
    );
    await rejectsWithCode(
      client.exec({ target: missing, service: "app", command: ["true"], onOutput }),
      "environment_not_found",
    );
  });

  test("down 带 discardData 只能用在调用方持有的环境：按目录指定报 usage_error", async () => {
    const repo = gitRepo("discard", "services: {}\n");
    await rejectsWithCode(client.down({ cwd: repo }, { discardData: true }), "usage_error");
    await rejectsWithCode(client.down({ cwd: repo, temp: "t" }, { discardData: true }), "usage_error");
    // false 和不写一样，照常按目录找环境
    await rejectsWithCode(client.down({ cwd: repo }, { discardData: false }), "environment_not_found");
  });

  test("exec 没给命令：bad_request", async () => {
    await rejectsWithCode(
      client.exec({ target: missing, service: "app", command: [], onOutput: () => {} }),
      "bad_request",
    );
  });

  test("按目录指定：不在 git 仓库里报 not_in_repository，没有环境报 environment_not_found", async () => {
    const plain = path.join(work, "plain");
    mkdirSync(plain);
    await rejectsWithCode(client.environment({ cwd: plain }), "not_in_repository");
    const repo = gitRepo("no-env", "services: {}\n");
    await rejectsWithCode(client.environment({ cwd: repo }), "environment_not_found");
  });

  // 能走到 compose_not_found，说明 napboxd 解开了请求（解不开时报 bad_request，Key not found）
  const undefinedCases: Record<string, (directory: string) => Promise<unknown>> = {
    "up files": (cwd) => client.up({ cwd, environment: {}, files: undefined }),
    "up profiles": (cwd) => client.up({ cwd, environment: {}, profiles: undefined }),
    "create files": (directory) => client.create({ ...createTarget, directory, files: undefined }),
    "create profiles": (directory) => client.create({ ...createTarget, directory, profiles: undefined }),
    "create environment": (directory) => client.create({ ...createTarget, directory, environment: undefined }),
    "create egress": (directory) => client.create({ ...createTarget, directory, egress: undefined }),
  };
  for (const [field, call] of Object.entries(undefinedCases)) {
    test(`${field} 显式传 undefined，和不写一样`, async () => {
      await rejectsWithCode(call(gitRepo("undefined-options")), "compose_not_found");
    });
  }

  test("logs、subscribe 的可选字段显式传 undefined，napboxd 也解得开", async () => {
    await rejectsWithCode(
      client.logs({
        target: missing,
        service: "app",
        tail: undefined,
        follow: undefined,
        onOutput: () => assert.fail("不该有输出"),
      }),
      "environment_not_found",
    );
    const controller = new AbortController();
    const reason = new Error("订阅生效了");
    await assert.rejects(
      client.subscribe({
        owner: undefined,
        names: undefined,
        onSubscribed: () => controller.abort(reason),
        onEvent: () => {},
        signal: controller.signal,
      }),
      (error) => error === reason,
    );
  });

  test("up 和 create 的 compose 问题：找不到、写错、不支持", async () => {
    const empty = gitRepo("no-compose");
    await rejectsWithCode(client.up({ cwd: empty, environment: {} }), "compose_not_found");
    await rejectsWithCode(
      client.create({ name: "codeos/empty", owner: "codeos", directory: empty }),
      "compose_not_found",
    );
    const broken = gitRepo("broken", "services: [not, a, map\n");
    await rejectsWithCode(client.up({ cwd: broken, environment: {} }), "compose_invalid");
    const privileged = gitRepo(
      "privileged",
      "services:\n  app:\n    image: alpine:3.20\n    privileged: true\n",
    );
    await rejectsWithCode(client.up({ cwd: privileged, environment: {} }), "compose_unsupported");
  });

  // 这里没有内核，走到准备镜像那一步报的是 runtime_unavailable：报 compose_invalid 说明文件在不在是先查的
  test("secrets 的文件不存在：up 和 create 在准备镜像、登记环境之前就报错，不留登记", async () => {
    const repo = gitRepo(
      "missing-secret",
      "services:\n  db:\n    image: alpine:3.20\n    secrets: [db_password]\nsecrets:\n  db_password:\n    file: ./keys/db.password\n",
    );
    const file = path.join(repo, "keys/db.password");
    const caller = { name: "codeos/missing-secret", owner: "codeos" };
    const error = await rejectsWithCode(client.up({ cwd: repo, environment: {} }), "compose_invalid");
    assert.match(error.message, /secrets 文件 .*keys\/db\.password 不存在/);
    await rejectsWithCode(client.environment({ cwd: repo }), "environment_not_found");
    await rejectsWithCode(client.create({ ...caller, directory: repo }), "compose_invalid");
    await rejectsWithCode(client.environment(caller), "environment_not_found");
    assert.equal(existsSync(path.dirname(file)), false, "宿主机上不该多出目录");
    // 文件有了，同一个 up 就往下走到准备镜像
    mkdirSync(path.dirname(file));
    writeFileSync(file, "x\n");
    await rejectsWithCode(client.up({ cwd: repo, environment: {} }), "runtime_unavailable");
    await rejectsWithCode(client.environment({ cwd: repo }), "environment_not_found");
  });

  test("同一个服务既挂目录、又挂这个目录里的文件：up 和 create 在准备镜像、登记环境之前就报错，不留登记", async () => {
    const repo = gitRepo(
      "dir-and-file",
      'services:\n  box:\n    image: alpine:3.20\n    volumes: ["./conf:/conf", "./conf/app.json:/etc/app.json"]\n',
    );
    mkdirSync(path.join(repo, "conf"));
    writeFileSync(path.join(repo, "conf/app.json"), "{}\n");
    const caller = { name: "codeos/dir-and-file", owner: "codeos" };
    const error = await rejectsWithCode(client.up({ cwd: repo, environment: {} }), "compose_unsupported");
    assert.match(error.message, /同时挂了目录 .*conf 和它里面的文件 .*app\.json/);
    await rejectsWithCode(client.environment({ cwd: repo }), "environment_not_found");
    await rejectsWithCode(client.create({ ...caller, directory: repo }), "compose_unsupported");
    await rejectsWithCode(client.environment(caller), "environment_not_found");
    // 只挂文件就往下走到准备镜像
    writeFileSync(
      path.join(repo, "compose.yaml"),
      'services:\n  box:\n    image: alpine:3.20\n    volumes: ["./conf/app.json:/etc/app.json"]\n',
    );
    await rejectsWithCode(client.up({ cwd: repo, environment: {} }), "runtime_unavailable");
  });

  test("create 的名字格式不对：bad_request", async () => {
    const repo = gitRepo("bad-name", "services:\n  app:\n    image: alpine:3.20\n");
    await rejectsWithCode(
      client.create({ name: "No Slash", owner: "codeos", directory: repo }),
      "bad_request",
    );
  });

  test("subscribe：生效后回调，取消时以 signal.reason 拒绝，napboxd 不受影响", async () => {
    const controller = new AbortController();
    let subscribed = false;
    const reason = new Error("不要了");
    const subscription = client.subscribe({
      owner: "codeos",
      names: ["codeos/a"],
      onSubscribed: () => {
        subscribed = true;
        controller.abort(reason);
      },
      onEvent: () => assert.fail("没有环境，不该有事件"),
      signal: controller.signal,
    });
    await assert.rejects(subscription, (error) => error === reason);
    assert.equal(subscribed, true);
    await client.status();
  });

  test("已经取消的 signal：不发请求，直接拒绝", async () => {
    const reason = new Error("已取消");
    await assert.rejects(
      client.subscribe({ onEvent: () => {}, signal: AbortSignal.abort(reason) }),
      (error) => error === reason,
    );
  });

  test("onSubscribed 抛错：调用以那个错误结束", async () => {
    const boom = new Error("回调出错");
    await assert.rejects(
      client.subscribe({
        onSubscribed: () => {
          throw boom;
        },
        onEvent: () => {},
      }),
      (error) => error === boom,
    );
  });
});

describe("真实 napboxd：没运行、退出、被强杀", () => {
  const support = supportDir("lifecycle");
  const log = path.join(work, "lifecycle.log");
  const client = new NapboxClient({ socketPath: path.join(support, "napboxd.sock") });

  test("从没运行过：daemon_unavailable，说明不会替它启动，也确实没启动", async () => {
    const error = await rejectsWithCode(client.status(), "daemon_unavailable");
    assert.match(error.message, /不会启动/);
    assert.equal(existsSync(path.join(support, "napboxd.lock")), false);
  });

  test("流式方法同样报 daemon_unavailable", async () => {
    await rejectsWithCode(client.subscribe({ onEvent: () => {} }), "daemon_unavailable");
  });

  test("正常退出：subscribe 以 daemon_unavailable 结束，之后调用也是", async () => {
    const daemon = await startDaemon(support, log);
    let subscribed = false;
    const subscription = client.subscribe({
      onSubscribed: () => {
        subscribed = true;
      },
      onEvent: () => {},
    });
    const ended = rejectsWithCode(subscription, "daemon_unavailable");
    await waitUntil("订阅生效", () => subscribed);
    await daemon.stop("SIGTERM");
    const error = await ended;
    assert.match(error.message, /不一定没做/);
    await rejectsWithCode(client.status(), "daemon_unavailable");
  });

  test("被强杀：subscribe 同样结束；留下的 socket 文件也报 daemon_unavailable；能再启动", async () => {
    const daemon = await startDaemon(support, log);
    let subscribed = false;
    const subscription = client.subscribe({
      onSubscribed: () => {
        subscribed = true;
      },
      onEvent: () => {},
    });
    const ended = rejectsWithCode(subscription, "daemon_unavailable");
    await waitUntil("订阅生效", () => subscribed);
    await daemon.stop("SIGKILL");
    await ended;
    assert.equal(existsSync(client.socketPath), true, "强杀后 socket 文件应该还在");
    await rejectsWithCode(client.status(), "daemon_unavailable");
    const again = await startDaemon(support, log);
    assert.equal((await again.client.status()).pid, again.process.pid);
    await again.stop("SIGTERM");
  });

  test("socket 路径太长：daemon_unavailable，不会连到别处", async () => {
    const long = new NapboxClient({ socketPath: path.join(work, "x".repeat(200), "napboxd.sock") });
    await rejectsWithCode(long.status(), "daemon_unavailable");
  });
});

describe("默认的 socket 路径", () => {
  test("和 napboxd 一样按 NAPBOX_SUPPORT_DIR", () => {
    const saved = process.env.NAPBOX_SUPPORT_DIR;
    try {
      process.env.NAPBOX_SUPPORT_DIR = "/tmp/somewhere";
      assert.equal(new NapboxClient().socketPath, "/tmp/somewhere/napboxd.sock");
      process.env.NAPBOX_SUPPORT_DIR = "";
      assert.match(new NapboxClient().socketPath, /Library\/Application Support\/napbox\/napboxd\.sock$/);
    } finally {
      if (saved === undefined) delete process.env.NAPBOX_SUPPORT_DIR;
      else process.env.NAPBOX_SUPPORT_DIR = saved;
    }
  });
});

describe("假服务端：真实 napboxd 发不出来的回应", () => {
  /** 起一个按 reply 回话的服务端，把收到的第一行交给 reply */
  async function withServer(
    reply: (socket: Socket, request: string) => void,
    body: (client: NapboxClient) => Promise<void>,
  ): Promise<void> {
    const socketPath = path.join(work, "fake.sock");
    rmSync(socketPath, { force: true });
    const server = createServer((socket) => {
      socket.on("error", () => {});
      socket.setEncoding("utf8");
      socket.once("data", (request) => reply(socket, request as string));
    });
    await new Promise<void>((resolve) => server.listen(socketPath, resolve));
    try {
      await body(new NapboxClient({ socketPath }));
    } finally {
      server.close();
    }
  }
  const status = {
    version: "0.1.4",
    pid: 1,
    startedAt: "2026-11-08T00:00:00Z",
    environments: [],
  };

  /** 调用一次，返回实际发出的 params。回个错误结束这次调用 */
  async function paramsSent(call: (client: NapboxClient) => Promise<unknown>): Promise<unknown> {
    let params: unknown;
    await withServer(
      (socket, request) => {
        params = (JSON.parse(request) as { params: unknown }).params;
        const error = { code: "internal_error", message: "够了" };
        socket.write(`${JSON.stringify({ id: 1, error })}\n`);
      },
      (client) => rejectsWithCode(call(client), "internal_error").then(() => {}),
    );
    return params;
  }

  test("up 实际发出的请求：files、profiles、build 不写和传 undefined 都是空的，给了就原样发", async () => {
    const base = { cwd: "/r", environment: { A: "1" } };
    const empty = { ...base, files: [], profiles: [], build: false };
    assert.deepEqual(await paramsSent((c) => c.up(base)), empty);
    assert.deepEqual(await paramsSent((c) => c.up({ ...base, files: undefined, profiles: undefined, build: undefined })), empty);
    const given = { ...base, files: ["a.yaml"], profiles: ["p"], build: true };
    assert.deepEqual(await paramsSent((c) => c.up(given)), given);
  });

  test("create 实际发出的请求：可选字段不写和传 undefined 都是空的，egress 不发；给了就原样发", async () => {
    const base = { name: "codeos/x", owner: "codeos", directory: "/r" };
    const empty = { ...base, files: [], profiles: [], environment: {} };
    assert.deepEqual(await paramsSent((c) => c.create(base)), empty);
    assert.deepEqual(
      await paramsSent((c) =>
        c.create({ ...base, files: undefined, profiles: undefined, environment: undefined, egress: undefined }),
      ),
      empty,
    );
    const given = { ...base, files: ["a.yaml"], profiles: ["p"], environment: { A: "1" }, egress: "none" as const };
    assert.deepEqual(await paramsSent((c) => c.create(given)), given);
  });

  test("不是 JSON：protocol_error", async () => {
    await withServer(
      (socket) => socket.write("hello\n"),
      (client) => rejectsWithCode(client.status(), "protocol_error").then(() => {}),
    );
  });

  test("字段对不上（版本差太多）：protocol_error", async () => {
    await withServer(
      (socket) => socket.write(`${JSON.stringify({ id: 1, result: { version: 1 } })}\n`),
      async (client) => {
        const error = await rejectsWithCode(client.status(), "protocol_error");
        assert.match(error.message, /版本/);
      },
    );
  });

  test("多出来的字段不管：不比版本，能用就继续用", async () => {
    await withServer(
      (socket) =>
        socket.write(`${JSON.stringify({ id: 1, result: { ...status, memory: 1 }, later: true })}\n`),
      async (client) => {
        const result = await client.status();
        assert.deepEqual(result, status);
      },
    );
  });

  test("不认识的错误码原样带回", async () => {
    await withServer(
      (socket) =>
        socket.write(`${JSON.stringify({ id: 1, error: { code: "from_the_future", message: "新版的" } })}\n`),
      async (client) => {
        const error = await rejectsWithCode(client.status(), "from_the_future");
        assert.equal(error.message, "新版的");
        assert.equal((errorCodes as readonly string[]).includes(error.code), false);
      },
    );
  });

  test("id 不对：protocol_error；id 0 的错误是 napboxd 解析不了请求，原样带回", async () => {
    await withServer(
      (socket) => socket.write(`${JSON.stringify({ id: 7, result: status })}\n`),
      (client) => rejectsWithCode(client.status(), "protocol_error").then(() => {}),
    );
    await withServer(
      (socket) =>
        socket.write(`${JSON.stringify({ id: 0, error: { code: "bad_request", message: "坏请求" } })}\n`),
      (client) => rejectsWithCode(client.status(), "bad_request").then(() => {}),
    );
  });

  test("普通方法收到流式内容：protocol_error", async () => {
    await withServer(
      (socket) => socket.write(`${JSON.stringify({ id: 1, subscribed: true })}\n`),
      (client) => rejectsWithCode(client.status(), "protocol_error").then(() => {}),
    );
  });

  test("没给结果就断开：普通方法和流式方法都是 daemon_unavailable", async () => {
    await withServer(
      (socket) => socket.end(),
      (client) => rejectsWithCode(client.status(), "daemon_unavailable").then(() => {}),
    );
    const target = { name: "a/b", owner: "a" };
    await withServer(
      (socket) => {
        const output = { stream: "stdout", data: Buffer.from("half").toString("base64") };
        socket.end(`${JSON.stringify({ id: 1, output })}\n`);
      },
      async (client) => {
        const seen: string[] = [];
        await rejectsWithCode(
          client.exec({
            target,
            service: "s",
            command: ["c"],
            onOutput: (o) => {
              seen.push(Buffer.from(o.data).toString());
            },
          }),
          "daemon_unavailable",
        );
        assert.deepEqual(seen, ["half"]);
      },
    );
  });

  test("最后一行没写完就断开：daemon_unavailable，不当成结果", async () => {
    await withServer(
      (socket) => socket.end(JSON.stringify({ id: 1, result: status })),
      (client) => rejectsWithCode(client.status(), "daemon_unavailable").then(() => {}),
    );
  });

  test("一个字节一个字节地到，多字节字符也不坏", async () => {
    const message = "中文说明🙂";
    const line = Buffer.from(`${JSON.stringify({ id: 1, error: { code: "bad_request", message } })}\n`);
    await withServer(
      async (socket) => {
        for (const byte of line) {
          socket.write(Buffer.from([byte]));
          await delay(0);
        }
      },
      async (client) => {
        const error = await rejectsWithCode(client.status(), "bad_request");
        assert.equal(error.message, message);
      },
    );
  });

  test("subscribe 收到不认识的事件类型：protocol_error，订阅结束", async () => {
    const event = { at: "2026-11-08T00:00:00Z", environment: "a/b", type: "from_the_future" };
    await withServer(
      (socket) => {
        socket.write(`${JSON.stringify({ id: 1, subscribed: true })}\n`);
        socket.write(`${JSON.stringify({ id: 1, event })}\n`);
      },
      (client) => rejectsWithCode(client.subscribe({ onEvent: () => {} }), "protocol_error").then(() => {}),
    );
  });

  test("exec 的标准输入本身出错：以那个错误结束，不当成 napboxd 的问题", async () => {
    const boom = new Error("读不了输入");
    await withServer(
      () => {}, // 一直不回话，只有标准输入出错才能结束
      async (client) => {
        await assert.rejects(
          client.exec({
            target: { name: "a/b", owner: "a" },
            service: "s",
            command: ["c"],
            // biome-ignore lint/correctness/useYield: 就是要在给出内容之前出错
            stdin: (async function* () {
              throw boom;
            })(),
            onOutput: () => {},
          }),
          (error) => error === boom,
        );
      },
    );
  });

  test("回调返回 Promise 时等它完成再读下一条", async () => {
    const event = (environment: string) => ({
      id: 1,
      event: { at: "2026-11-08T00:00:00Z", environment, type: "destroyed" },
    });
    const order: string[] = [];
    await withServer(
      (socket) => {
        socket.write(`${JSON.stringify({ id: 1, subscribed: true })}\n`);
        socket.write(`${JSON.stringify(event("a/1"))}\n${JSON.stringify(event("a/2"))}\n`);
        socket.end(`${JSON.stringify({ id: 1, result: {} })}\n`);
      },
      (client) =>
        client.subscribe({
          onSubscribed: async () => {
            await delay(20);
            order.push("subscribed");
          },
          onEvent: async (e) => {
            await delay(20);
            order.push(e.environment);
          },
        }),
    );
    assert.deepEqual(order, ["subscribed", "a/1", "a/2"]);
  });

  test("错误类型能用 instanceof 判断", () => {
    assert.ok(new NapboxError("x", "y") instanceof Error);
  });
});
