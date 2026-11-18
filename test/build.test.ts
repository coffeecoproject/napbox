// 镜像构建（compose 的 build）：真的起构建虚拟机、从 Docker Hub 拉基础镜像。从 scripts/test-client.sh build 运行。
// 镜像库也用临时的（不链接正在用的）：构建会往里写镜像、清理没人用的内容，正在用的镜像库不该被碰。内核只读着用。
import assert from "node:assert/strict";
import { execFileSync, spawnSync } from "node:child_process";
import {
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  realpathSync,
  rmSync,
  statSync,
  symlinkSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { after, afterEach, before, describe, test } from "node:test";
import { NapboxClient } from "../src/client.ts";
import { type Daemon, rejectsWithCode, startBuilderAtRandomAddress, startDaemon, waitUntil } from "./support.ts";

const real = process.env.NAPBOX_REAL_SUPPORT_DIR;
if (!real) throw new Error("要用 scripts/test-client.sh build 运行");

const work = realpathSync(mkdtempSync(path.join(tmpdir(), "nbx-build-")));
const support = path.join(work, "support");
mkdirSync(support);
symlinkSync(path.join(real, "kernel"), path.join(support, "kernel"));
symlinkSync(path.join(real, "runc"), path.join(support, "runc"));
startBuilderAtRandomAddress(support);
const log = path.join(work, "napboxd.log");

const DOCKERFILE = `FROM alpine:3.20 AS base
ARG ARG1=default
RUN apk add --no-cache curl >/dev/null && echo "$ARG1" > /arg.txt
FROM base AS final
COPY . /ctx
RUN echo final > /target.txt && cp /ctx/marker.txt /marker.txt && cd /ctx && find . -type f | sort > /list.txt
FROM base AS unused
RUN echo unused > /target.txt
`;

// 专门考 Docker 的忽略规则：后面的规则优先，! 能把被排除目录下的文件放回来
const DOCKERIGNORE = `# 注释不算规则
.git
.claude

**/.env
**/.env.*
!**/.env.example
!**/.env.*.example
**/node_modules
secret.txt
docs/*
!docs/keep.md
/only-root.txt
other/sub-ignored.txt
`;

const LIST = [
  "./.claude/worktrees/a/.env.providers.example",
  "./.dockerignore",
  "./.env.example",
  "./Dockerfile",
  "./apps/x/.env.example",
  "./apps/x/main.ts",
  "./compose.yaml",
  "./docs/keep.md",
  "./marker.txt",
  "./other/Dockerfile",
  "./other/Dockerfile.dockerignore",
  "./other/a.txt",
  "./other/b.txt",
  "./sub/only-root.txt",
];

const COMPOSE = `services:
  app:
    image: nbx-test-app:local
    build:
      context: .
      target: final
      args: {ARG1: from-compose}
    command: ["sleep", "100000"]
    stop_grace_period: 1s
  worker:
    image: nbx-test-app:local
    command: ["sleep", "100000"]
    stop_grace_period: 1s
  named-ignore:
    build:
      context: .
      dockerfile: other/Dockerfile
    command: ["sleep", "100000"]
    stop_grace_period: 1s
  plain:
    image: alpine:3.20
    command: ["sleep", "100000"]
    stop_grace_period: 1s
`;

function fixture(dir: string): void {
  mkdirSync(dir, { recursive: true });
  execFileSync("git", ["init", "-q", dir]);
  const files: Record<string, string> = {
    "compose.yaml": COMPOSE,
    Dockerfile: DOCKERFILE,
    ".dockerignore": DOCKERIGNORE,
    "marker.txt": "v1\n",
    ".claude/worktrees/a/file.txt": "x",
    ".claude/worktrees/a/.env.providers.example": "x",
    ".env": "x",
    ".env.local": "x",
    ".env.example": "x",
    "apps/x/.env": "x",
    "apps/x/.env.example": "x",
    "apps/x/node_modules/p/i.js": "x",
    "apps/x/main.ts": "x",
    "secret.txt": "x",
    "docs/a.md": "x",
    "docs/keep.md": "x",
    "only-root.txt": "x",
    "sub/only-root.txt": "x",
    "other/a.txt": "x",
    "other/b.txt": "x",
    // 和 Dockerfile 同名的忽略文件优先于根目录的 .dockerignore
    "other/Dockerfile": "FROM alpine:3.20\nCOPY . /ctx\nRUN cd /ctx && find . -type f | sort > /list.txt\n",
    "other/Dockerfile.dockerignore": "*\n!other/a.txt\n",
  };
  for (const [name, content] of Object.entries(files)) {
    const file = path.join(dir, name);
    mkdirSync(path.dirname(file), { recursive: true });
    writeFileSync(file, content);
  }
  execFileSync("git", ["-C", dir, "add", "-A", "-f"]);
  execFileSync("git", ["-C", dir, "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qm", "x"]);
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

/** 用 mke2fs 建的标准 ext4（DataDisk）：有目录索引和元数据校验。框架的 EXT4.Formatter 建的两样都没有 */
function assertStandardExt4(file: string): void {
  const debugfs = path.join(process.env.NAPBOX_BIN ?? "", "debugfs");
  const stats = execFileSync(debugfs, ["-R", "stats", file], { stdio: ["ignore", "pipe", "ignore"] }).toString();
  const features = stats.match(/^Filesystem features:\s*(.*)$/m)?.[1]?.split(/\s+/) ?? [];
  assert.ok(features.includes("dir_index"), `${file}：${features.join(" ")}`);
  assert.ok(features.includes("metadata_csum"), `${file}：${features.join(" ")}`);
}

describe("镜像构建", { concurrency: false }, () => {
  let daemon: Daemon;
  let client: NapboxClient;
  const main = path.join(work, "demo");
  const target = { cwd: main };

  before(async () => {
    daemon = await startDaemon(support, log);
    client = daemon.client;
    fixture(main);
  });
  after(async () => {
    await daemon.stop("SIGTERM");
  });

  async function output(cwd: string, service: string, command: string): Promise<string> {
    let text = "";
    const { exitCode } = await client.exec({
      target: { cwd },
      service,
      command: ["sh", "-c", command],
      onOutput: (o) => {
        text += Buffer.from(o.data).toString();
      },
    });
    assert.equal(exitCode, 0, `${command}：${text}`);
    return text;
  }

  /** 构建虚拟机在不在：它开着时占着缓存卷 */
  function builderRunning(): boolean {
    return spawnSync("lsof", [path.join(support, "builder/cache.ext4")]).status === 0;
  }

  /** 这个服务的构建日志（build 定义相同的服务只有第一个有） */
  function buildLog(name: string): string {
    const logs = path.join(support, "builder/logs");
    const dirs = execFileSync("find", [logs, "-name", `${name}.log`]).toString().trim().split("\n").filter(Boolean);
    assert.equal(dirs.length, 1, `${name}.log 应该只有一份：${dirs.join("、")}`);
    return dirs[0] ?? "";
  }

  test("第一次 up：先构建再起，忽略规则、target、args 和 Docker 一样；image 相同的服务共用构建结果", async () => {
    const info = await client.up({ cwd: main, environment: {} });
    assert.equal(info.state, "running");
    assert.equal((await output(main, "app", "cat /marker.txt")).trim(), "v1");
    assert.equal((await output(main, "worker", "cat /marker.txt")).trim(), "v1");
    assert.equal((await output(main, "app", "cat /target.txt")).trim(), "final");
    assert.equal((await output(main, "app", "cat /arg.txt")).trim(), "from-compose");
    assert.deepEqual((await output(main, "app", "cat /list.txt")).trim().split("\n"), LIST);
    assert.deepEqual((await output(main, "named-ignore", "cat /list.txt")).trim().split("\n"), ["./other/a.txt"]);
    // build 定义相同只构建一次，worker 没有写 build，也没有自己的构建日志
    assert.equal(existsSync(path.join(path.dirname(buildLog("app")), "worker.log")), false);
    assert.equal(builderRunning(), false, "构建完虚拟机就关了");
  });

  test("构建缓存卷是标准格式的 ext4：有目录索引（dir_index）", () => {
    assertStandardExt4(path.join(support, "builder/cache.ext4"));
  });

  test("镜像已有时再 up 不重新构建，打进镜像的还是旧内容（和 Docker 一样）", async () => {
    const before = statSync(buildLog("app")).mtimeMs;
    const runs = (await client.runs(target)).runs.length;
    writeFileSync(path.join(main, "marker.txt"), "v2\n");
    await client.up({ cwd: main, environment: {} });
    assert.equal(statSync(buildLog("app")).mtimeMs, before);
    assert.equal((await client.runs(target)).runs.length, runs);
    assert.equal((await output(main, "app", "cat /marker.txt")).trim(), "v1");
  });

  test("休眠再唤醒不构建，用现成的镜像", async () => {
    const before = statSync(buildLog("app")).mtimeMs;
    await client.sleep(target);
    await client.wake(target);
    assert.equal(statSync(buildLog("app")).mtimeMs, before);
    assert.equal((await output(main, "app", "cat /marker.txt")).trim(), "v1");
  });

  test("up --build：内容变了就换镜像、重启环境；拉来的镜像不受清理影响", async () => {
    const runs = (await client.runs(target)).runs.length;
    await client.up({ cwd: main, environment: {}, build: true });
    assert.equal((await output(main, "app", "cat /marker.txt")).trim(), "v2");
    assert.equal((await client.runs(target)).runs.length, runs + 1);
    assert.equal((await output(main, "plain", "cat /etc/alpine-release")).trim().startsWith("3.20"), true);
    // 这时 worktree 里已经有 napbox 自己写的 .napbox/ports.json：它不进构建，项目的两种忽略文件照样生效
    assert.equal(existsSync(path.join(main, ".napbox/ports.json")), true);
    assert.deepEqual((await output(main, "app", "cat /list.txt")).trim().split("\n"), LIST);
    assert.deepEqual((await output(main, "named-ignore", "cat /list.txt")).trim().split("\n"), ["./other/a.txt"]);
  });

  test("up --build：内容没变就不重启，容器里写的东西还在", async () => {
    await output(main, "app", "echo kept > /kept.txt");
    const before = statSync(buildLog("app")).mtimeMs;
    const runs = (await client.runs(target)).runs.length;
    await client.up({ cwd: main, environment: {}, build: true });
    assert.notEqual(statSync(buildLog("app")).mtimeMs, before);
    assert.equal((await client.runs(target)).runs.length, runs);
    assert.equal((await output(main, "app", "cat /kept.txt")).trim(), "kept");
  });

  test("构建失败：报 image_build_failed，带构建输出和日志路径；在跑的环境不受影响，修好后能再建", async () => {
    const dockerfile = path.join(main, "Dockerfile");
    writeFileSync(dockerfile, `FROM alpine:3.20 AS final\nRUN echo 故意失败 && exit 7\n`);
    const error = await rejectsWithCode(client.up({ cwd: main, environment: {}, build: true }), "image_build_failed");
    assert.match(error.message, /故意失败/);
    assert.match(error.message, /builder\/logs\/.*app\.log/);
    assert.equal((await client.environment(target)).state, "running");
    assert.equal((await output(main, "app", "cat /marker.txt")).trim(), "v2");
    writeFileSync(dockerfile, DOCKERFILE);
    await client.up({ cwd: main, environment: {}, build: true });
    assert.equal((await client.environment(target)).lastError, undefined);
  });

  test("create 带 confine：构建照常（构建虚拟机只共享代码目录本身）；Dockerfile 是指出去的符号链接就不构建", async () => {
    const dir = path.join(work, "confined-build");
    const outside = path.join(work, "confined-build-outside");
    mkdirSync(path.join(dir, "app"), { recursive: true });
    mkdirSync(outside, { recursive: true });
    execFileSync("git", ["init", "-q", dir]);
    writeFileSync(path.join(outside, "Dockerfile"), "FROM alpine:3.20\n");
    writeFileSync(path.join(dir, "compose.yaml"), 'services:\n  app:\n    build: ./app\n    command: ["sleep", "100000"]\n    stop_grace_period: 1s\n');
    writeFileSync(path.join(dir, "app/Dockerfile"), "FROM alpine:3.20\nCOPY a.txt /a.txt\n");
    writeFileSync(path.join(dir, "app/a.txt"), "confined\n");
    const target = { name: "codeos/confined-build", owner: "codeos" };
    assert.equal((await client.create({ ...target, directory: dir, confine: true })).confined, true);
    let text = "";
    await client.exec({ target, service: "app", command: ["cat", "/a.txt"], onOutput: (o) => void (text += Buffer.from(o.data).toString()) });
    assert.equal(text, "confined\n");
    await client.down(target, { discardData: true });
    rmSync(path.join(dir, "app/Dockerfile"));
    symlinkSync(path.join(outside, "Dockerfile"), path.join(dir, "app/Dockerfile"));
    await rejectsWithCode(client.create({ ...target, directory: dir, confine: true }), "path_outside_directory");
  });

  test("Dockerfile 或目录不存在：不开虚拟机，直接说清楚", async () => {
    const dir = path.join(work, "missing");
    mkdirSync(dir);
    execFileSync("git", ["init", "-q", dir]);
    writeFileSync(path.join(dir, "compose.yaml"), "services:\n  a:\n    build: .\n    command: [\"true\"]\n");
    const error = await rejectsWithCode(client.up({ cwd: dir, environment: {} }), "image_build_failed");
    assert.match(error.message, /Dockerfile .* 不存在/);
    await rejectsWithCode(client.environment({ cwd: dir }), "environment_not_found");
  });

  test("两个 worktree 同时构建：排队完成，各用各的镜像", async () => {
    const other = path.join(work, "demo-other");
    execFileSync("git", ["-C", main, "worktree", "add", "-q", "-b", "other", other]);
    writeFileSync(path.join(other, "marker.txt"), "other\n");
    writeFileSync(path.join(main, "marker.txt"), "main\n");
    await Promise.all([
      client.up({ cwd: main, environment: {}, build: true }),
      client.up({ cwd: other, environment: {}, build: true }),
    ]);
    assert.equal((await output(main, "app", "cat /marker.txt")).trim(), "main");
    assert.equal((await output(other, "app", "cat /marker.txt")).trim(), "other");
    await client.down({ cwd: other });
  });

  /** 起一个卡在 RUN 里、带着外网连接的构建，等它跑到那一步。返回包一层：async 函数直接返回 promise 会等它结束 */
  async function buildInProgress(cwd: string, service: string): Promise<{ up: Promise<unknown> }> {
    writeFileSync(
      path.join(cwd, "Dockerfile"),
      `FROM alpine:3.20\nRUN echo holding-${Date.now()} && (nc 1.1.1.1 443 < /dev/zero > /dev/null 2>&1 &) ; sleep 300\n`,
    );
    writeFileSync(path.join(cwd, "compose.yaml"), `services:\n  ${service}:\n    build: .\n    command: ["true"]\n`);
    const up = client.up({ cwd, environment: {}, build: true }).catch((error: unknown) => error);
    await waitUntil("构建跑到 RUN", () => {
      const logs = execFileSync("find", [path.join(support, "builder/logs"), "-name", `${service}.log`]).toString().trim();
      return logs !== "" && readFileSync(logs, "utf8").includes("holding-");
    }, 120_000);
    assert.equal(builderRunning(), true, "构建虚拟机应该开着");
    return { up };
  }

  async function restart(): Promise<void> {
    daemon = await startDaemon(support, log);
    client = daemon.client;
  }

  function holdProject(name: string): string {
    const dir = path.join(work, name);
    mkdirSync(dir);
    execFileSync("git", ["init", "-q", dir]);
    return dir;
  }

  /** 构建还能上网：装包要真的出去 */
  async function buildsWithNetwork(cwd: string): Promise<void> {
    writeFileSync(path.join(cwd, "Dockerfile"), `FROM alpine:3.20\nRUN echo ${Date.now()} && apk add --no-cache curl\n`);
    writeFileSync(path.join(cwd, "compose.yaml"), "services:\n  hold:\n    build: .\n    command: [\"sleep\", \"100000\"]\n    stop_grace_period: 1s\n");
    await client.up({ cwd, environment: {}, build: true });
    assert.equal((await output(cwd, "hold", "which curl")).trim(), "/usr/bin/curl");
    await client.down({ cwd });
  }

  test("构建中 napboxd 收到 SIGTERM：很快退出，重启后还能构建、能上网", async () => {
    const dir = holdProject("hold-term");
    const { up } = await buildInProgress(dir, "hold-term");
    const started = Date.now();
    await daemon.stop("SIGTERM");
    assert.ok(Date.now() - started < 30_000, `退出用了 ${Date.now() - started} 毫秒`);
    assert.equal(((await up) as { code?: string }).code, "daemon_unavailable");
    assert.match(readFileSync(path.join(support, "builder/engine.log"), "utf8"), /stopping server/, "引擎收到了信号");
    assert.doesNotMatch(readFileSync(log, "utf8"), /没有退出，直接关虚拟机/, "构建还在跑时引擎也要先退出");
    await restart();
    await waitUntil("虚拟机退出", () => !builderRunning());
    await buildsWithNetwork(dir);
  });

  test("构建中 napboxd 被强杀：重启后还能构建、能上网", async () => {
    const dir = holdProject("hold-kill");
    const { up } = await buildInProgress(dir, "hold-kill");
    await daemon.stop("SIGKILL");
    assert.equal(((await up) as { code?: string }).code, "daemon_unavailable");
    await waitUntil("虚拟机退出", () => !builderRunning());
    await restart();
    await buildsWithNetwork(dir);
  });

  test("down：构建出来的镜像和日志都删掉，再 up 重新构建", async () => {
    const reference = path.dirname(buildLog("app"));
    await client.down(target);
    assert.equal(existsSync(reference), false);
    writeFileSync(path.join(main, "marker.txt"), "after-down\n");
    await client.up({ cwd: main, environment: {} });
    assert.equal((await output(main, "app", "cat /marker.txt")).trim(), "after-down");
    assert.equal((await output(main, "plain", "cat /etc/alpine-release")).trim().startsWith("3.20"), true);
    await client.down(target);
  });
});

// 命名卷带镜像内容时不常见但会碰到的文件：硬链接（pnpm 装的依赖全是）、带 setuid 位的程序、文件的 capabilities、
// 粘滞位目录，还有镜像里挂载路径本身是符号链接。拉来的镜像里凑不齐，自己构建一个。
// 管道、设备文件不考：框架解包镜像时就跳过了它们，容器里本来就没有。
describe("新的命名卷带上自建镜像里的特殊文件", { concurrency: false }, () => {
  const dir = path.join(work, "special");
  const target = { cwd: dir };
  let daemon: Daemon;
  let client: NapboxClient;

  before(async () => {
    daemon = await startDaemon(support, log);
    client = daemon.client;
    mkdirSync(dir, { recursive: true });
    execFileSync("git", ["init", "-q", dir]);
    writeFileSync(
      path.join(dir, "Dockerfile"),
      `FROM alpine:3.20
RUN apk add --no-cache libcap >/dev/null
RUN mkdir -p /data/sub /data/sticky /real/dir \\
 && echo one > /data/first && ln /data/first /data/sub/second && ln /data/first /data/third \\
 && cp /bin/busybox /data/suid && chown 1000:1000 /data/suid && chmod 6755 /data/suid \\
 && chmod 1777 /data/sticky \\
 && cp /bin/busybox /data/capped && setcap cap_net_raw+ep /data/capped \\
 && echo inside > /real/dir/file && chown -R 1000:1000 /real && ln -s /real/dir /via-link
`,
    );
    const service = (name: string, volumes: string) => `  ${name}:
    image: nbx-test-special:local
    build: {context: .}
    command: ["sleep", "100000"]${volumes}
    stop_grace_period: 1s
`;
    writeFileSync(
      path.join(dir, "compose.yaml"),
      `services:\n${service("seeded", '\n    volumes: ["data:/data", "linked:/via-link"]')}${service("plain", "")}volumes:\n  data:\n  linked:\n`,
    );
    await client.up({ cwd: dir, environment: {} });
  });
  after(async () => {
    await client.down(target).catch(() => {});
    await daemon.stop("SIGTERM");
  });

  async function sh(service: string, command: string): Promise<string> {
    let text = "";
    const { exitCode } = await client.exec({
      target,
      service,
      command: ["sh", "-c", command],
      onOutput: (o) => {
        text += Buffer.from(o.data).toString();
      },
    });
    assert.equal(exitCode, 0, `${service} 里 ${command}：${text}`);
    return text;
  }
  /** 每一项的属主、权限（含 setuid、粘滞位）、类型、硬链接数、修改时间，文件再加大小 */
  const listing = async (service: string, directory: string) =>
    (await sh(service, `cd ${directory} && find . -print0 | sort -z | xargs -0 stat -c '%n|%u:%g|%a|%F|%h|%Y|%s'`))
      .trimEnd()
      .split("\n")
      .map((line) => (line.split("|")[3] === "directory" ? line.slice(0, line.lastIndexOf("|")) : line));

  test("硬链接还是同一个文件，setuid 位、粘滞位、属主都和镜像里一样", async () => {
    const want = await listing("plain", "/data");
    assert.deepEqual(await listing("seeded", "/data"), want);
    // 确认镜像里真有这些，比的不是两边都没有
    const kind = (name: string) => want.find((line) => line.startsWith(`./${name}|`))?.split("|") ?? [];
    assert.deepEqual([kind("first")[4], kind("sub/second")[4], kind("third")[4]], ["3", "3", "3"]);
    assert.deepEqual(kind("suid").slice(1, 3), ["1000:1000", "6755"]);
    assert.equal(kind("sticky")[2], "1777");
    assert.match(await sh("seeded", "mount | grep ' /data '"), /^\/dev\/vd/);
    // 三个名字是同一个文件：改一个，另外两个跟着变，占的也是同一个 inode
    assert.equal((await sh("seeded", "stat -c %i /data/first /data/sub/second /data/third | sort -u | wc -l")).trim(), "1");
    await sh("seeded", "echo changed > /data/third");
    assert.equal(await sh("seeded", "cat /data/first /data/sub/second"), "changed\nchanged\n");
  });

  test("文件的 capabilities 带过来（存在扩展属性里）", async () => {
    const want = await sh("plain", "getcap /data/capped");
    assert.match(want, /capped cap_net_raw[=+]ep/);
    assert.equal(await sh("seeded", "getcap /data/capped"), want);
  });

  test("镜像里挂载路径是符号链接：卷挂在链接指向的目录上，带的是那个目录的内容和属主", async () => {
    assert.equal(await sh("plain", "readlink /via-link"), "/real/dir\n");
    assert.equal(await sh("seeded", "readlink /via-link"), "/real/dir\n");
    assert.match(await sh("seeded", "mount | grep ' /real/dir '"), /^\/dev\/vd/);
    assert.equal(await sh("seeded", "cat /via-link/file /real/dir/file"), "inside\ninside\n");
    assert.equal(await sh("seeded", "stat -c '%u:%g' /real/dir /real/dir/file"), "1000:1000\n1000:1000\n");
  });
});

// 镜像在 Dockerfile 里声明了 VOLUME、compose 没在那个路径挂东西的：和 Docker 一样给一块匿名卷，不写进根文件系统。
// 匿名卷跟着服务走（docker compose 重建容器时默认沿用旧容器的匿名卷）：镜像不再声明的移到 recycled，服务删了的留到 down。
describe("镜像声明的 VOLUME：没挂东西的路径给匿名卷", { concurrency: false }, () => {
  const dir = path.join(work, "anonymous");
  const target = { cwd: dir };
  let daemon: Daemon;
  let client: NapboxClient;

  const dockerfile = (volumes: string) => `FROM alpine:3.20
RUN mkdir -p /vol/sub /other \\
 && echo seed > /vol/sub/seed.txt && chown -R 1234:2345 /vol && chmod 750 /vol && chmod 640 /vol/sub/seed.txt \\
 && echo other > /other/o.txt
VOLUME ${volumes}
`;
  // keeper 什么都没挂：两个声明的路径都给匿名卷。covered 在同样的路径上挂了命名卷和绑定目录：不另建匿名卷。
  // nested 只在 /vol 下面挂了绑定目录：/vol 照样给匿名卷，绑定目录挂在它上面看得见（框架和 Docker 一样按层数从浅到深挂）
  // keeper：on 照常；profile 放进没启用的 profile；off 从 compose 里删掉
  const compose = (keeperEnv: string, keeper: "on" | "profile" | "off" = "on") => `services:
${keeper !== "off" ? `  keeper:
    image: nbx-test-anon:local
    build: {context: .}
    environment: {V: "${keeperEnv}"}${keeper === "profile" ? `\n    profiles: ["extra"]` : ""}
    command: ["sleep", "100000"]
    stop_grace_period: 1s
` : ""}  covered:
    image: nbx-test-anon:local
    build: {context: .}
    command: ["sleep", "100000"]
    volumes: ["data:/vol", "./host-other:/other"]
    stop_grace_period: 1s
  nested:
    image: nbx-test-anon:local
    build: {context: .}
    command: ["sleep", "100000"]
    volumes: ["./plugins:/vol/plugins"]
    stop_grace_period: 1s
volumes:
  data:
`;

  before(async () => {
    daemon = await startDaemon(support, log);
    client = daemon.client;
    mkdirSync(path.join(dir, "host-other"), { recursive: true });
    mkdirSync(path.join(dir, "plugins"), { recursive: true });
    writeFileSync(path.join(dir, "plugins/p.txt"), "plugin\n");
    execFileSync("git", ["init", "-q", dir]);
    writeFileSync(path.join(dir, "Dockerfile"), dockerfile('["/vol", "/other"]'));
    writeFileSync(path.join(dir, "compose.yaml"), compose("1"));
    await client.up({ cwd: dir, environment: {} });
  });
  after(async () => {
    await client.down(target).catch(() => {});
    await daemon.stop("SIGTERM");
  });

  async function sh(service: string, command: string): Promise<string> {
    let text = "";
    const { exitCode } = await client.exec({
      target,
      service,
      command: ["sh", "-c", command],
      onOutput: (o) => {
        text += Buffer.from(o.data).toString();
      },
    });
    assert.equal(exitCode, 0, `${service} 里 ${command}：${text}`);
    return text;
  }
  /** 各环境的数据卷文件里，名字以 prefix 开头的（完整路径，排好序） */
  function volumeFiles(prefix: string): string[] {
    const environments = path.join(support, "environments");
    if (!existsSync(environments)) return [];
    return execFileSync("find", [environments, "-path", "*/volumes/*", "-name", `${prefix}*.ext4`]).toString().trim().split("\n").filter(Boolean).sort();
  }
  const keeperVolumes = () => volumeFiles("_anon_keeper_");

  test("第一次 up：没挂东西的两个路径各有一块匿名卷，带着镜像里的内容、属主和权限", async () => {
    assert.equal(keeperVolumes().length, 2);
    assert.match(await sh("keeper", "mount | grep ' /vol '"), /^\/dev\/vd/);
    assert.match(await sh("keeper", "mount | grep ' /other '"), /^\/dev\/vd/);
    assert.equal(await sh("keeper", "cat /vol/sub/seed.txt /other/o.txt"), "seed\nother\n");
    assert.equal(await sh("keeper", "stat -c '%u:%g %a' /vol /vol/sub/seed.txt"), "1234:2345 750\n1234:2345 640\n");
  });

  test("同一路径挂了命名卷或绑定目录的服务不另建匿名卷", async () => {
    assert.deepEqual(volumeFiles("_anon_covered_"), []);
    assert.match(await sh("covered", "mount | grep ' /vol '"), /^\/dev\/vd/);
    assert.equal(await sh("covered", "cat /vol/sub/seed.txt"), "seed\n");
    // 绑定目录是宿主机上的空目录：看到的是它，不是镜像里的内容
    assert.equal(await sh("covered", "ls -A /other"), "");
  });

  test("只在声明的路径下面挂了绑定目录：上层照样给匿名卷，下面的绑定目录不被盖住", async () => {
    assert.equal(volumeFiles("_anon_nested_").length, 2);
    assert.match(await sh("nested", "mount | grep ' /vol '"), /^\/dev\/vd/);
    assert.equal(await sh("nested", "cat /vol/sub/seed.txt /vol/plugins/p.txt"), "seed\nplugin\n");
  });

  test("匿名卷也是标准格式的 ext4：有目录索引（dir_index）", () => {
    assert.equal(keeperVolumes().length, 2);
    for (const file of keeperVolumes()) assertStandardExt4(file);
  });

  test("写进匿名卷的数据：休眠唤醒、根文件系统重建后都还在", async () => {
    await sh("keeper", "echo mine > /vol/mine.txt");
    await client.sleep(target);
    await client.wake(target);
    assert.equal(await sh("keeper", "cat /vol/mine.txt"), "mine\n");
    writeFileSync(path.join(dir, "compose.yaml"), compose("2"));
    await client.up({ cwd: dir, environment: {} });
    const keeper = (await client.runs(target)).runs.at(-1)?.services.find((s) => s.service === "keeper");
    assert.equal(keeper?.rootfs, "unpacked", "keeper 的定义变了，根文件系统应该重建");
    assert.equal(await sh("keeper", "cat /vol/mine.txt"), "mine\n");
    assert.equal(keeperVolumes().length, 2);
  });

  test("匿名卷不能单独 reset", async () => {
    const name = path.basename(keeperVolumes()[0] ?? "", ".ext4");
    assert.match(name, /^_anon_keeper_[0-9a-f]{12}$/);
    await rejectsWithCode(client.reset(target, [name]), "volume_not_found");
  });

  /** recycled 下留着的匿名卷文件的名字 */
  const recycledVolumes = () =>
    existsSync(path.join(support, "recycled"))
      ? execFileSync("find", [path.join(support, "recycled"), "-path", "*/volumes/*", "-name", "_anon_*.ext4"]).toString().trim().split("\n").filter(Boolean).map((f) => path.basename(f))
      : [];

  test("镜像不再声明某个路径：那块匿名卷移到 recycled 保留，别的照旧", async () => {
    const before = keeperVolumes();
    writeFileSync(path.join(dir, "Dockerfile"), dockerfile('["/vol"]'));
    await client.up({ cwd: dir, environment: {}, build: true });
    const after = keeperVolumes();
    assert.equal(after.length, 1);
    assert.ok(before.includes(after[0] ?? ""), "留下的是原来那块");
    const dropped = before.filter((file) => !after.includes(file)).map((file) => path.basename(file));
    assert.equal(dropped.length, 1);
    assert.ok(recycledVolumes().includes(dropped[0] ?? ""), `recycled 里应该有 ${dropped[0]}`);
    assert.equal(await sh("keeper", "cat /vol/mine.txt"), "mine\n");
    // /other 回到根文件系统里镜像的内容
    assert.match(await sh("keeper", "mount | grep ' /other ' || echo none"), /^none$/m);
    assert.equal(await sh("keeper", "cat /other/o.txt"), "other\n");
  });

  test("服务删了、换 profile 没启用：它的匿名卷留着（和 compose 留给孤立的容器一样），加回来照样用", async () => {
    const before = keeperVolumes();
    assert.equal(before.length, 1);
    for (const keeper of ["off", "profile"] as const) {
      writeFileSync(path.join(dir, "compose.yaml"), compose("2", keeper));
      await client.up({ cwd: dir, environment: {} });
      const started = (await client.runs(target)).runs.at(-1)?.services.map((s) => s.service) ?? [];
      assert.ok(started.includes("covered") && !started.includes("keeper"), `${keeper}：${started.join("、")}`);
      assert.deepEqual(keeperVolumes(), before, keeper);
    }
    writeFileSync(path.join(dir, "compose.yaml"), compose("2"));
    await client.up({ cwd: dir, environment: {} });
    assert.equal(await sh("keeper", "cat /vol/mine.txt"), "mine\n");
  });

  test("down 之后匿名卷跟着环境回收，再 up 是新的一块，带着镜像里的内容", async () => {
    await sh("keeper", "echo again > /vol/again.txt");
    const before = keeperVolumes();
    assert.equal(before.length, 1);
    await client.down(target);
    assert.deepEqual(keeperVolumes(), []);
    await client.up({ cwd: dir, environment: {} });
    assert.equal(await sh("keeper", "ls /vol/again.txt 2>/dev/null || echo gone"), "gone\n");
    assert.equal(await sh("keeper", "cat /vol/sub/seed.txt"), "seed\n");
  });
});
