// 文件变化通知和 develop.watch：真的起虚拟机，让真的 chokidar 收事件。从 scripts/test-client.sh watch 运行
// 镜像库用正在用的那份的 APFS 克隆（会往里写构建出来的镜像，正在用的不该被碰）。构建时的基础镜像由构建虚拟机
// 自己拉，还是要能访问 Docker Hub 和 npm。
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import {
  chmodSync,
  existsSync,
  lstatSync,
  mkdirSync,
  mkdtempSync,
  readdirSync,
  readFileSync,
  realpathSync,
  renameSync,
  rmSync,
  statSync,
  symlinkSync,
  utimesSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { after, afterEach, before, describe, test } from "node:test";
import type { NapboxClient } from "../src/client.ts";
import { type Daemon, delay, startBuilderAtRandomAddress, startDaemon, waitUntil } from "./support.ts";

const real = process.env.NAPBOX_REAL_SUPPORT_DIR;
if (!real) throw new Error("要用 scripts/test-client.sh watch 运行");

const work = realpathSync(mkdtempSync(path.join(tmpdir(), "nbx-watch-")));
const support = path.join(work, "support");
mkdirSync(support);
// cp -c：APFS 克隆，两边各改各的
execFileSync("cp", ["-c", "-R", path.join(real, "images"), path.join(support, "images")]);
symlinkSync(path.join(real, "kernel"), path.join(support, "kernel"));
symlinkSync(path.join(real, "runc"), path.join(support, "runc"));
const log = path.join(work, "napboxd.log");
startBuilderAtRandomAddress(support);

const COMPOSE = `services:
  w:
    image: node:22-alpine
    command: ["sh", "/tools/start.sh"]
    volumes:
      - ./src:/src
      - ./ro:/ro:ro
      - ./tools:/tools
    stop_grace_period: 1s
    x-napbox:
      keep_awake: true
  b:
    image: alpine:3.20
    command: ["sleep", "100000"]
    volumes:
      - ./src:/bsrc:ro
    stop_grace_period: 1s
    x-napbox:
      keep_awake: true
`;

// 真的 chokidar（vite、tsx watch、nodemon 都用它）。收到事件马上读文件，读到的是什么一起记下来
const START = `#!/bin/sh
mkdir -p /opt/w && cd /opt/w
[ -d node_modules/chokidar ] || { npm init -y >/dev/null && npm i --silent chokidar@4 >/tmp/npm.log 2>&1; }
cat > w.mjs <<'JS'
import chokidar from 'chokidar';
import { appendFile, readFileSync } from 'node:fs';
// 事件先攒在内存里，后台一批一批写，处理事件时不同步写挂载目录。同步写的话每条事件都要等一次写盘，
// 还各引出一次宿主机通知，chokidar 读一次 2000 个文件的目录会慢两三倍；超过 1 秒就撞上 chokidar 自己的毛病
// （两次读目录重叠，把刚加的文件误报成删除）
const pending = [];
let writing = false;
const flush = () => {
  if (writing || pending.length === 0) return;
  writing = true;
  appendFile('/tools/events.log', pending.splice(0).join(''), (error) => {
    if (error) throw error;
    writing = false;
    flush();
  });
};
const write = (o) => {
  pending.push(JSON.stringify({ at: Date.now(), ...o }) + '\\n');
  flush();
};
const read = (p) => { try { return readFileSync(p, 'utf8').slice(0, 200); } catch (e) { return e.code; } };
chokidar.watch(['/src', '/ro'], { ignoreInitial: true })
  .on('all', (event, p) => write({ event, path: p, content: read(p) }))
  .on('ready', () => write({ event: 'ready' }));
JS
exec node w.mjs
`;

interface WatchEvent {
  at: number;
  event: string;
  path?: string;
  content?: string;
}

let failed = false;
afterEach((t) => {
  if (t.passed === false) failed = true;
});
after(() => {
  if (failed) {
    console.log(`有失败，测试目录留着：${work}\nnapboxd 日志：\n${readFileSync(log, "utf8")}`);
  } else {
    rmSync(work, { recursive: true, force: true }); // 链接只删链接本身，不会删到内核
  }
});

describe("文件变化通知", { concurrency: false }, () => {
  let daemon: Daemon;
  let client: NapboxClient;
  const project = path.join(work, "demo");
  const src = path.join(project, "src");
  const ro = path.join(project, "ro");
  const eventsFile = path.join(project, "tools/events.log");
  const target = { cwd: project };

  function events(): WatchEvent[] {
    if (!existsSync(eventsFile)) return [];
    const text = readFileSync(eventsFile, "utf8");
    // 最后一行可能正写到一半
    return text
      .slice(0, text.lastIndexOf("\n") + 1)
      .split("\n")
      .filter(Boolean)
      .map((line) => JSON.parse(line) as WatchEvent);
  }

  const mark = () => events().length;

  /** 等到 mark 之后出现符合条件的事件，返回它 */
  async function waitEvent(from: number, what: string, match: (e: WatchEvent) => boolean, timeoutMs = 5_000): Promise<WatchEvent> {
    let found: WatchEvent | undefined;
    try {
      await waitUntil(
        what,
        () => {
          found = events().slice(from).find(match);
          return found !== undefined;
        },
        timeoutMs,
      );
    } catch (error) {
      assert.fail(`${error}\n收到的事件：${JSON.stringify(events().slice(from))}`);
    }
    return found as WatchEvent;
  }

  async function run(service: string, command: string): Promise<{ code: number; text: string }> {
    let text = "";
    const { exitCode } = await client.exec({
      target,
      service,
      command: ["sh", "-c", command],
      onOutput: (o) => {
        text += Buffer.from(o.data).toString();
      },
    });
    return { code: exitCode, text };
  }

  before(async () => {
    daemon = await startDaemon(support, log);
    client = daemon.client;
    mkdirSync(project, { recursive: true });
    execFileSync("git", ["init", "-q", project]);
    for (const dir of ["src/sub", "ro", "tools"]) mkdirSync(path.join(project, dir), { recursive: true });
    writeFileSync(path.join(project, "compose.yaml"), COMPOSE);
    writeFileSync(path.join(project, "tools/start.sh"), START);
    writeFileSync(path.join(src, "a.txt"), "v1\n");
    writeFileSync(path.join(src, "sub/b.txt"), "b\n");
    writeFileSync(path.join(ro, "r.txt"), "r1\n");
    writeFileSync(path.join(project, ".gitignore"), "tools/events.log\n");
    execFileSync("git", ["-C", project, "add", "-A"]);
    execFileSync("git", ["-C", project, "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qm", "x"]);
    await client.up({ cwd: project, environment: {} });
    await waitEvent(0, "chokidar 准备好", (e) => e.event === "ready", 180_000);
  });
  after(async () => {
    await client.down(target).catch(() => {});
    await daemon.stop("SIGTERM");
  });

  test("只改宿主机的文件：chokidar 收到，读到新内容，修改时间不变", async () => {
    const file = path.join(src, "a.txt");
    const from = mark();
    writeFileSync(file, "v2 longer than before\n");
    const modified = statSync(file).mtimeMs;
    const started = Date.now();
    const event = await waitEvent(from, "a.txt 的变化", (e) => e.event === "change" && e.path === "/src/a.txt");
    // 在宿主机这边量：虚拟机的时钟和宿主机差几百毫秒。每 100 毫秒看一次
    console.log(`  保存到看到事件不超过 ${Date.now() - started} 毫秒`);
    assert.equal(event.content, "v2 longer than before\n");
    assert.equal(statSync(file).mtimeMs, modified, "通知不能改文件的修改时间");
  });

  test("改名覆盖保存（编辑器和 agent 常见的写法）", async () => {
    const from = mark();
    writeFileSync(path.join(src, "a.tmp"), "atomic\n");
    renameSync(path.join(src, "a.tmp"), path.join(src, "a.txt"));
    const event = await waitEvent(from, "a.txt 变成新内容", (e) => e.path === "/src/a.txt" && e.content === "atomic\n");
    assert.ok(event.event === "add" || event.event === "change", event.event);
  });

  test("新建文件", async () => {
    const from = mark();
    writeFileSync(path.join(src, "sub/new.txt"), "new\n");
    const event = await waitEvent(from, "new.txt", (e) => e.event === "add" && e.path === "/src/sub/new.txt");
    assert.equal(event.content, "new\n");
  });

  test("删子目录里的文件", async () => {
    const from = mark();
    rmSync(path.join(src, "sub/new.txt"));
    await waitEvent(from, "删除", (e) => e.event === "unlink" && e.path === "/src/sub/new.txt");
  });

  test("删挂载根目录下的文件：也能收到，不留痕迹", async () => {
    writeFileSync(path.join(src, "rootfile.txt"), "x\n");
    await waitEvent(0, "rootfile 建好", (e) => e.event === "add" && e.path === "/src/rootfile.txt");
    const from = mark();
    rmSync(path.join(src, "rootfile.txt"));
    await waitEvent(from, "根目录下的删除", (e) => e.event === "unlink" && e.path === "/src/rootfile.txt");
    await delay(300);
    assert.deepEqual(readdirSync(src).filter((n) => n.startsWith(".napbox")), []);
  });

  test("新建多层目录", async () => {
    const from = mark();
    mkdirSync(path.join(src, "d1/d2"), { recursive: true });
    writeFileSync(path.join(src, "d1/d2/deep.txt"), "deep\n");
    const event = await waitEvent(from, "深层文件", (e) => e.event === "add" && e.path === "/src/d1/d2/deep.txt");
    assert.equal(event.content, "deep\n");
  });

  test("改名：旧的没了，新的有了", async () => {
    const from = mark();
    renameSync(path.join(src, "sub/b.txt"), path.join(src, "sub/b2.txt"));
    await waitEvent(from, "新名字", (e) => e.event === "add" && e.path === "/src/sub/b2.txt");
    await waitEvent(from, "旧名字", (e) => e.event === "unlink" && e.path === "/src/sub/b.txt");
  });

  test("只读挂载也收得到，服务仍然写不了", async () => {
    const file = path.join(ro, "r.txt");
    const from = mark();
    writeFileSync(file, "r2\n");
    const event = await waitEvent(from, "只读挂载的变化", (e) => e.event === "change" && e.path === "/ro/r.txt");
    assert.equal(event.content, "r2\n");

    for (const command of ["echo x > /ro/r.txt", "rm /ro/r.txt", "touch /ro/new.txt", "chmod 777 /ro/r.txt"]) {
      const { code, text } = await run("w", command);
      assert.notEqual(code, 0, `${command} 不该成功`);
      assert.match(text, /[Rr]ead-only/, command);
    }
    assert.notEqual((await run("w", "mount -o remount,rw /ro")).code, 0, "服务不能自己改成可写");
    assert.equal(readFileSync(file, "utf8"), "r2\n");
    assert.deepEqual(readdirSync(ro), ["r.txt"]);
  });

  test("同一个目录一个服务只读、一个可写：各是各的", async () => {
    assert.equal((await run("w", "echo from-w > /src/from-w.txt")).code, 0);
    assert.equal(readFileSync(path.join(src, "from-w.txt"), "utf8"), "from-w\n");
    const { code, text } = await run("b", "echo x > /bsrc/from-b.txt");
    assert.notEqual(code, 0);
    assert.match(text, /[Rr]ead-only/);
    assert.equal(existsSync(path.join(src, "from-b.txt")), false);
    rmSync(path.join(src, "from-w.txt"));
  });

  test("通知不会自己引起新的通知", async () => {
    await delay(1_000);
    const file = path.join(src, "a.txt");
    const from = mark();
    writeFileSync(file, "once\n");
    await waitEvent(from, "这次保存", (e) => e.path === "/src/a.txt" && e.content === "once\n");
    await delay(2_000);
    const changes = events().slice(from).filter((e) => e.path === "/src/a.txt");
    assert.equal(changes.length, 1, `一次保存只该有一个事件：${JSON.stringify(changes)}`);
  });

  test("服务自己写的文件：可能多一个事件，但不会没完没了", async () => {
    const from = mark();
    assert.equal((await run("w", "echo guest > /src/guest.txt")).code, 0);
    await waitEvent(from, "服务自己写", (e) => e.path === "/src/guest.txt");
    await delay(1_500);
    const settled = events().slice(from).filter((e) => e.path === "/src/guest.txt").length;
    assert.ok(settled <= 3, `事件太多：${settled}`);
    await delay(2_000);
    assert.equal(events().slice(from).filter((e) => e.path === "/src/guest.txt").length, settled, "事件还在增加");
    rmSync(path.join(src, "guest.txt"));
  });

  test(".git 里的变化不转发", async () => {
    mkdirSync(path.join(src, ".git"), { recursive: true });
    await delay(500);
    const from = mark();
    writeFileSync(path.join(src, ".git/index"), "x");
    await delay(1_500);
    assert.deepEqual(events().slice(from).filter((e) => e.path?.includes(".git/index")), []);
    // 对照：事件转发本身还是通的，上面不是因为别的原因没收到
    writeFileSync(path.join(src, "a.txt"), "after-git\n");
    await waitEvent(from, "对照", (e) => e.path === "/src/a.txt" && e.content === "after-git\n");
    rmSync(path.join(src, ".git"), { recursive: true });
  });

  test("符号链接：收到事件，不改到它指向的文件", async () => {
    const pointed = path.join(src, "pointed.txt");
    writeFileSync(pointed, "p\n");
    chmodSync(pointed, 0o600);
    await delay(500);
    const from = mark();
    symlinkSync("pointed.txt", path.join(src, "link.txt"));
    await waitEvent(from, "链接", (e) => e.path === "/src/link.txt");
    assert.equal(statSync(pointed).mode & 0o777, 0o600);
    assert.equal(lstatSync(path.join(src, "link.txt")).isSymbolicLink(), true);
    rmSync(path.join(src, "link.txt"));
    rmSync(pointed);
  });

  // 只看权限：chokidar 在修改时间没变、读过文件之后不报这种变化，真的 Linux 上也一样
  test("宿主机改权限：虚拟机里跟着变，权限不会被改回去", async () => {
    const file = path.join(src, "run.sh");
    writeFileSync(file, "#!/bin/sh\n");
    chmodSync(file, 0o644);
    await delay(500);
    assert.equal((await run("w", "stat -c %a /src/run.sh")).text.trim(), "644");
    chmodSync(file, 0o755);
    await delay(500);
    assert.equal((await run("w", "stat -c %a /src/run.sh")).text.trim(), "755");
    chmodSync(file, 0o700);
    await delay(500);
    assert.equal((await run("w", "stat -c %a /src/run.sh")).text.trim(), "700");
    chmodSync(file, 0o755);
    await delay(500);
    assert.equal(statSync(file).mode & 0o777, 0o755);
    rmSync(file);
  });

  test("一下子改很多文件（git checkout 这种）：全部收到，日志没有失败", async () => {
    const dir = path.join(src, "many");
    mkdirSync(dir);
    const count = 2000;
    const from = mark();
    const started = Date.now();
    for (let i = 0; i < count; i++) writeFileSync(path.join(dir, `f${i}.txt`), `${i}\n`);
    const added = () => events().slice(from).filter((e) => e.event === "add" && e.path?.startsWith("/src/many/"));
    await waitUntil(`${count} 个文件的事件`, () => added().length === count, 120_000);
    console.log(`  ${count} 个文件 ${Date.now() - started} 毫秒`);
    for (const e of added()) {
      assert.equal(e.content, `${path.basename(e.path as string).slice(1, -4)}\n`, `${e.path}`);
    }
    rmSync(dir, { recursive: true });
  });

  test("休眠时改的文件唤醒后是新的，之后的变化照样收到；日志里没有发送失败", async () => {
    const file = path.join(src, "a.txt");
    await client.sleep(target);
    writeFileSync(file, "while-asleep\n");
    await delay(500);
    const before = mark();
    await client.wake(target);
    await waitEvent(before, "chokidar 重新准备好", (e) => e.event === "ready", 60_000);
    assert.equal((await run("w", "cat /src/a.txt")).text, "while-asleep\n");
    const from = mark();
    writeFileSync(file, "after-wake\n");
    const event = await waitEvent(from, "唤醒后的变化", (e) => e.path === "/src/a.txt" && e.content === "after-wake\n");
    assert.equal(event.event, "change");
    assert.doesNotMatch(readFileSync(log, "utf8"), /文件变化通知/);
  });
});

// 服务不是 root：同步的文件要属于它，它才改得动
const DEVELOP_DOCKERFILE = `FROM alpine:3.20
COPY src /app/src
COPY pkg.json /app/pkg.json
RUN adduser -D -u 1234 dev && mkdir /app/real && ln -s real /app/linked && chown -R dev /app
USER dev
`;

const BARE_DOCKERFILE = `FROM alpine:3.20
RUN rm /etc/passwd /etc/group && mkdir /app && chown 4321:4322 /app
USER 4321:4322
`;

const DEVELOP_COMPOSE = `services:
  api:
    build: .
    command: ["sleep", "100000"]
    stop_grace_period: 1s
    x-napbox:
      keep_awake: true
    develop:
      watch:
        - {action: sync, path: ./src, target: /app/src, ignore: ["skip/", "*.log"]}
        - {action: rebuild, path: ./pkg.json}
        - {action: sync, path: ./init, target: /app/init, initial_sync: true}
        - {action: sync, path: ./noinit, target: /app/noinit}
        - {action: sync, path: ./via-link, target: /app/linked/sub}
        - {action: sync, path: ./only-py, target: /app/only-py, include: ["**/*.py"]}
        - {action: sync+restart, path: ./conf, target: /app/conf}
        - {action: sync+exec, path: ./hook, target: /app/hook, exec: {command: "sh -c 'echo run >> /tmp/hook.log'"}}
  # 镜像很早就建好了，宿主机的文件都比它新
  old-image:
    image: alpine:3.20
    command: ["sleep", "100000"]
    stop_grace_period: 1s
    volumes:
      - vol:/app/volbase/data
    develop:
      watch:
        - {action: sync, path: ./init, target: /app/init, initial_sync: true}
        - {action: sync, path: ./volbase, target: /app/volbase}
  # 用户写数字，镜像里没有 /etc/passwd
  bare:
    build: {context: ., dockerfile: Dockerfile.bare}
    command: ["sleep", "100000"]
    stop_grace_period: 1s
    develop:
      watch:
        - {action: sync, path: ./bare, target: /app/bare}
volumes:
  vol:
`;

describe("develop.watch", { concurrency: false }, () => {
  let daemon: Daemon;
  let client: NapboxClient;
  const project = path.join(work, "develop");
  const target = { cwd: project };
  const file = (name: string) => path.join(project, name);

  function write(name: string, content: string): void {
    mkdirSync(path.dirname(file(name)), { recursive: true });
    writeFileSync(file(name), content);
  }

  async function run(command: string, service = "api"): Promise<{ code: number; text: string }> {
    let text = "";
    const { exitCode } = await client.exec({
      target,
      service,
      command: ["sh", "-c", command],
      onOutput: (o) => {
        text += Buffer.from(o.data).toString();
      },
    });
    return { code: exitCode, text };
  }

  const read = async (where: string) => {
    const { code, text } = await run(`cat ${where} 2>&1`);
    return code === 0 ? text : undefined;
  };

  /** 等到容器里这个文件是这个内容（undefined 是没有这个文件） */
  async function waitFile(where: string, content: string | undefined, timeoutMs = 5_000): Promise<void> {
    let last: string | undefined;
    try {
      await waitUntil(
        `${where} 变成 ${content}`,
        async () => {
          last = await read(where);
          return last === content;
        },
        timeoutMs,
      );
    } catch (error) {
      assert.fail(`${error}，实际是 ${last}`);
    }
  }

  before(async () => {
    daemon = await startDaemon(support, log);
    client = daemon.client;
    mkdirSync(project, { recursive: true });
    execFileSync("git", ["init", "-q", project]);
    write("compose.yaml", DEVELOP_COMPOSE);
    write("Dockerfile", DEVELOP_DOCKERFILE);
    write("Dockerfile.bare", BARE_DOCKERFILE);
    write("bare/.keep", "");
    write("pkg.json", "v1\n");
    write("src/a.txt", "a1\n");
    write("src/del.txt", "del\n");
    write("init/i.txt", "from-host\n");
    write("noinit/n.txt", "from-host\n");
    write("conf/c.txt", "c1\n");
    write("hook/h.txt", "h1\n");
    execFileSync("git", ["-C", project, "add", "-A"]);
    execFileSync("git", ["-C", project, "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qm", "x"]);
    await client.up({ cwd: project, environment: {} });
  });
  after(async () => {
    await client.down(target).catch(() => {});
    await daemon.stop("SIGTERM");
  });

  test("起环境时：和 compose 一样，写了 initial_sync 的规则同步比镜像新的文件，没写的不动", async () => {
    assert.equal((await run("cat /app/init/i.txt", "old-image")).text, "from-host\n", "文件比镜像新");
    assert.equal(await read("/app/init/i.txt"), undefined, "文件比镜像旧，算镜像里已经有了");
    assert.equal(await read("/app/noinit/n.txt"), undefined);
    write("noinit/n2.txt", "changed\n");
    await waitFile("/app/noinit/n2.txt", "changed\n");
    assert.equal(await read("/app/noinit/n.txt"), undefined, "只同步变了的");
  });

  test("改文件、建文件和多层目录、删文件：都同步，保留权限", async () => {
    const started = Date.now();
    write("src/a.txt", "a2\n");
    await waitFile("/app/src/a.txt", "a2\n");
    console.log(`  保存到同步完 ${Date.now() - started} 毫秒`);
    write("src/d1/d2/deep.sh", "#!/bin/sh\n");
    chmodSync(file("src/d1/d2/deep.sh"), 0o755);
    await waitFile("/app/src/d1/d2/deep.sh", "#!/bin/sh\n");
    await waitUntil("权限同步", async () => (await run("stat -c %a /app/src/d1/d2/deep.sh")).text.trim() === "755", 5_000);
    rmSync(file("src/del.txt"));
    await waitFile("/app/src/del.txt", undefined);
    assert.equal((await client.environment(target)).watchError, undefined);
  });

  test("改名覆盖、搬进来的目录、删掉的目录", async () => {
    write("src/tmp-save", "atomic\n");
    renameSync(file("src/tmp-save"), file("src/a.txt"));
    await waitFile("/app/src/a.txt", "atomic\n");
    write("outside/x/y.txt", "moved\n");
    renameSync(file("outside/x"), file("src/moved"));
    await waitFile("/app/src/moved/y.txt", "moved\n");
    rmSync(file("src/moved"), { recursive: true });
    await waitFile("/app/src/moved/y.txt", undefined);
    assert.notEqual((await run("test -d /app/src/moved")).code, 0, "目录也要没了");
  });

  test("同步的文件和目录属于容器的用户，服务改得动", async () => {
    write("src/own/o.txt", "mine\n");
    await waitFile("/app/src/own/o.txt", "mine\n");
    assert.equal((await run("stat -c '%u:%g %a' /app/src/own /app/src/own/o.txt")).text, "1234:1234 755\n1234:1234 644\n");
    assert.equal((await run("echo more >> /app/src/own/o.txt && rm /app/src/own/o.txt && echo ok")).text, "ok\n");
  });

  test("用户写数字、镜像里没有 /etc/passwd 也能同步", async () => {
    write("bare/b.txt", "bare\n");
    await waitUntil("同步到 bare", async () => (await run("cat /app/bare/b.txt 2>&1", "bare")).text === "bare\n", 5_000);
    assert.equal((await run("stat -c '%u:%g' /app/bare/b.txt", "bare")).text, "4321:4322\n");
    assert.equal((await client.environment(target)).watchError, undefined);
  });

  test("只改权限也同步，已有的文件也按宿主机的", async () => {
    write("src/mode.sh", "#!/bin/sh\n");
    await waitFile("/app/src/mode.sh", "#!/bin/sh\n");
    assert.equal((await run("stat -c %a /app/src/mode.sh")).text, "644\n");
    chmodSync(file("src/mode.sh"), 0o755);
    await waitUntil("权限同步", async () => (await run("stat -c %a /app/src/mode.sh")).text === "755\n", 5_000);
  });

  test("空目录也同步，删了也没", async () => {
    mkdirSync(file("src/empty/inner"), { recursive: true });
    await waitUntil("空目录同步", async () => (await run("test -d /app/src/empty/inner")).code === 0, 5_000);
    assert.equal((await run("stat -c %u /app/src/empty/inner")).text, "1234\n");
    rmSync(file("src/empty"), { recursive: true });
    await waitUntil("空目录没了", async () => (await run("test -e /app/src/empty")).code !== 0, 5_000);
  });

  test("文件换成目录、目录换成文件", async () => {
    write("src/swap", "file\n");
    await waitFile("/app/src/swap", "file\n");
    rmSync(file("src/swap"));
    write("src/swap/inner.txt", "in-dir\n");
    await waitFile("/app/src/swap/inner.txt", "in-dir\n");
    rmSync(file("src/swap"), { recursive: true });
    write("src/swap", "file-again\n");
    await waitFile("/app/src/swap", "file-again\n");
    await delay(1_000); // 换掉目录的那批要处理完
    assert.equal((await client.environment(target)).watchError, undefined);
  });

  test("删不掉的不挡着别的文件：写照常，status 说明，下一批成功后清掉", async () => {
    write("noinit/gone.txt", "x\n"); // 目标目录是同步时建的，属于 root，服务删不掉里面的东西
    await waitFile("/app/noinit/gone.txt", "x\n");
    rmSync(file("noinit/gone.txt"));
    write("noinit/next.txt", "next\n");
    await waitFile("/app/noinit/next.txt", "next\n");
    await waitUntil("报出来", async () => /gone\.txt/.test((await client.environment(target)).watchError ?? ""), 5_000);
    write("src/after-gone.txt", "ok\n");
    await waitUntil("下一批成功后清掉", async () => (await client.environment(target)).watchError === undefined, 5_000);
  });

  test("管道文件不卡住同步", async () => {
    execFileSync("mkfifo", [file("src/pipe")]);
    write("src/after-pipe.txt", "ok\n");
    await waitFile("/app/src/after-pipe.txt", "ok\n");
    assert.notEqual((await run("test -e /app/src/pipe")).code, 0);
    rmSync(file("src/pipe"));
  });

  test("目标的上层是镜像里的符号链接：写到它指向的地方", async () => {
    write("via-link/l.txt", "through-link\n");
    await waitFile("/app/real/sub/l.txt", "through-link\n");
    assert.equal((await run("readlink /app/linked")).text, "real\n", "链接还是链接");
    assert.equal((await client.environment(target)).watchError, undefined);
  });

  test("只写了 include：目录下匹配的文件同步，唤醒时不会被当成删了", async () => {
    write("only-py/sub/a.py", "py\n");
    write("only-py/sub/b.ts", "ts\n");
    await waitFile("/app/only-py/sub/a.py", "py\n");
    assert.equal(await read("/app/only-py/sub/b.ts"), undefined);
    write("outside/moved/c.py", "moved\n");
    renameSync(file("outside/moved"), file("only-py/moved"));
    await waitFile("/app/only-py/moved/c.py", "moved\n");
    await client.sleep(target);
    await client.wake(target);
    assert.equal(await read("/app/only-py/sub/a.py"), "py\n");
    assert.equal(await read("/app/only-py/moved/c.py"), "moved\n");
  });

  test("目录被整个换掉：旧文件也没了", async () => {
    write("src/dist/old.js", "old\n");
    await waitFile("/app/src/dist/old.js", "old\n");
    write("outside/dist-new/new.js", "new\n");
    renameSync(file("src/dist"), file("outside/dist-old"));
    renameSync(file("outside/dist-new"), file("src/dist"));
    await waitFile("/app/src/dist/new.js", "new\n");
    await waitFile("/app/src/dist/old.js", undefined);
  });

  test("落在卷下面的路径：写进卷里，删也删卷里的（和 compose 一样）", async () => {
    const inOld = (command: string) => run(command, "old-image");
    write("volbase/data/v.txt", "in-volume\n");
    await waitUntil("写进卷", async () => (await inOld("cat /app/volbase/data/v.txt 2>&1")).text === "in-volume\n", 5_000);
    assert.match((await inOld("grep ' /app/volbase/data ' /proc/mounts")).text, /app\/volbase\/data/, "确实是个挂载");
    rmSync(file("volbase/data/v.txt"));
    await waitUntil("从卷里删", async () => (await inOld("test -e /app/volbase/data/v.txt")).code !== 0, 5_000);
    assert.equal((await client.environment(target)).watchError, undefined);
  });

  test("保留修改时间；很长的路径也对；临时的包不留在容器里", async () => {
    const deep = `src/${"long-directory-name/".repeat(8)}${"f".repeat(120)}.txt`;
    write(deep, "deep\n");
    await waitFile(`/app/${deep}`, "deep\n");
    utimesSync(file("src/a.txt"), new Date("2024-05-06T07:08:09Z"), new Date("2024-05-06T07:08:09Z"));
    await waitUntil("时间同步", async () => (await run("date -u -r /app/src/a.txt +%Y%m%d%H%M%S")).text === "20240506070809\n", 5_000);
    assert.equal((await run("ls -a / | grep -c napbox-sync")).text, "0\n");
    rmSync(file("src/long-directory-name"), { recursive: true });
    await waitUntil("长路径删掉", async () => (await run("test -e /app/src/long-directory-name")).code !== 0, 5_000);
  });

  test("同步和 exec 同时进行：exec 不受影响（框架压缩包接口的重复关闭不能再出现）", async () => {
    const execs = (async () => {
      for (let i = 0; i < 60; i++) assert.equal((await run("echo ok")).text, "ok\n");
    })();
    for (let i = 0; i < 12; i++) {
      write(`src/concurrent/c${i}.txt`, `${i}\n`);
      await delay(600); // 过了合并等待，每次都是单独一批
    }
    await execs;
    await waitFile("/app/src/concurrent/c11.txt", "11\n");
    assert.equal((await client.environment(target)).watchError, undefined);
  });

  test("符号链接照样是链接", async () => {
    symlinkSync("a.txt", file("src/link.txt"));
    await waitUntil("链接同步", async () => (await run("readlink /app/src/link.txt")).text.trim() === "a.txt", 5_000);
    assert.equal((await client.environment(target)).watchError, undefined);
  });

  test("ignore、.git 和编辑器临时文件不同步", async () => {
    write("src/skip/s.txt", "x\n");
    write("src/x.log", "x\n");
    write("src/.a.txt.swp", "x\n");
    write("src/.git/config", "x\n");
    write("src/after.txt", "control\n");
    await waitFile("/app/src/after.txt", "control\n"); // 对照：同一批的别的文件同步了
    for (const name of ["skip/s.txt", "x.log", ".a.txt.swp", ".git/config"]) {
      assert.equal(await read(`/app/src/${name}`), undefined, name);
    }
  });

  test("sync+exec：同步后跑一次命令，一批变化只跑一次", async () => {
    write("hook/h2.txt", "2\n");
    write("hook/h3.txt", "3\n");
    await waitFile("/app/hook/h3.txt", "3\n");
    await waitFile("/tmp/hook.log", "run\n");
    await delay(1_000);
    assert.equal(await read("/tmp/hook.log"), "run\n");
  });

  test("sync+restart：同步后整个环境重启，同步的还在", async () => {
    const before = (await client.runs(target)).runs.length;
    write("conf/c.txt", "c2\n");
    await waitUntil("环境重启", async () => (await client.runs(target)).runs.length > before, 30_000);
    await waitUntil("重启后在跑", async () => (await client.environment(target)).state === "running", 30_000);
    assert.equal(await read("/app/conf/c.txt"), "c2\n");
    write("src/after-restart.txt", "yes\n");
    await waitFile("/app/src/after-restart.txt", "yes\n"); // 重启后还在听
  });

  test("同一批有 sync+exec 和 sync+restart：重启后 exec 在新环境里跑", async () => {
    const lines = async () => Number((await run("wc -l < /tmp/hook.log")).text.trim());
    const before = (await client.runs(target)).runs.length;
    const executed = await lines();
    write("hook/both.txt", "1\n");
    write("conf/both.txt", "1\n");
    await waitUntil("环境重启", async () => (await client.runs(target)).runs.length > before, 30_000);
    await waitUntil("重启后在跑", async () => (await client.environment(target)).state === "running", 30_000);
    await waitUntil("exec 跑了", async () => (await lines()) === executed + 1, 10_000);
  });

  test("休眠期间改了 sync+restart 的文件：唤醒后服务重启，读到新的", async () => {
    await client.sleep(target);
    const before = (await client.runs(target)).runs.length;
    write("conf/c.txt", "asleep-conf\n");
    await client.wake(target);
    assert.equal(await read("/app/conf/c.txt"), "asleep-conf\n");
    await waitUntil("环境又重启一次", async () => (await client.runs(target)).runs.length > before + 1, 30_000);
    await waitUntil("重启后在跑", async () => (await client.environment(target)).state === "running", 30_000);
    assert.equal(await read("/app/conf/c.txt"), "asleep-conf\n");
    const settled = (await client.runs(target)).runs.length;
    await delay(1_500);
    assert.equal((await client.runs(target)).runs.length, settled, "不会一直重启");
  });

  test("休眠期间的变化：唤醒返回时已经同步好了", async () => {
    await client.sleep(target);
    write("src/a.txt", "asleep\n");
    write("src/new-asleep.txt", "new\n");
    rmSync(file("src/after.txt"));
    await client.wake(target);
    assert.equal((await client.environment(target)).watchError, undefined);
    assert.equal(await read("/app/src/a.txt"), "asleep\n");
    assert.equal(await read("/app/src/new-asleep.txt"), "new\n");
    assert.equal(await read("/app/src/after.txt"), undefined);
  });

  test("rebuild：改依赖文件后重新构建、环境重启，之后还能同步", async () => {
    const before = (await client.runs(target)).runs.length;
    write("pkg.json", "v2\n");
    await waitUntil("环境重启", async () => (await client.runs(target)).runs.length > before, 120_000);
    await waitFile("/app/pkg.json", "v2\n", 30_000);
    assert.equal((await client.environment(target)).watchError, undefined);
    assert.equal(await read("/app/src/a.txt"), "asleep\n", "新镜像里是当时的文件");
    write("src/a.txt", "after-rebuild\n");
    await waitFile("/app/src/a.txt", "after-rebuild\n");
  });

  test("rebuild 失败：旧环境接着跑，status 说明原因；修好后自己恢复", async () => {
    write("Dockerfile", "FROM alpine:3.20\nRUN exit 7\n");
    write("pkg.json", "v3\n");
    await waitUntil("报出失败", async () => (await client.environment(target)).watchError !== undefined, 120_000);
    const info = await client.environment(target);
    assert.equal(info.state, "running");
    assert.match(info.watchError ?? "", /构建/);
    assert.equal(await read("/app/pkg.json"), "v2\n");
    write("src/during-failure.txt", "ok\n");
    await waitFile("/app/src/during-failure.txt", "ok\n");
    assert.match((await client.environment(target)).watchError ?? "", /构建/, "同步成功不代表镜像是新的，报错要留着");

    write("Dockerfile", DEVELOP_DOCKERFILE);
    write("pkg.json", "v4\n");
    await waitFile("/app/pkg.json", "v4\n", 120_000);
    assert.equal((await client.environment(target)).watchError, undefined);
  });

  test("一批几百个文件", async () => {
    const started = Date.now();
    for (let i = 0; i < 300; i++) write(`src/many/f${i}.txt`, `${i}\n`);
    await waitFile("/app/src/many/f299.txt", "299\n", 60_000);
    await waitUntil("全部同步", async () => (await run("ls /app/src/many | wc -l")).text.trim() === "300", 60_000);
    console.log(`  300 个文件 ${Date.now() - started} 毫秒`);
    assert.equal(await read("/app/src/many/f7.txt"), "7\n");
    assert.equal((await client.environment(target)).watchError, undefined);
  });

  test("down 之后不再有动静，日志里没有出错", async () => {
    await client.down(target);
    const logged = readFileSync(log, "utf8").length;
    write("src/after-down.txt", "x\n");
    await delay(1_500);
    const after = readFileSync(log, "utf8");
    assert.doesNotMatch(after, /发文件变化通知失败/);
    assert.doesNotMatch(after.slice(logged), /develop\.watch|重新构建/, "down 之后还在同步");
  });
});
