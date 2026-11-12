// 钩子靠它判断 agent 是不是真的要运行 docker compose up：误拦和漏拦都在这里测。
import assert from "node:assert/strict";
import { test } from "node:test";
import { composeSubcommand, isDockerRun, simpleCommands, startsOwnService } from "../src/agent/shell-command.ts";

const subcommands = (command: string) =>
  simpleCommands(command).flatMap(({ argv }) => composeSubcommand(argv) ?? []);

test("认得各种写法的 docker compose 子命令", () => {
  for (const [command, expected] of [
    ["docker compose up", "up"],
    ["docker compose up -d --wait", "up"],
    ["docker-compose start", "start"],
    ["docker compose -f a.yml -p x run api sh", "run"],
    ["docker compose --file=a.yml up", "up"],
    ["docker --context prod compose up", "up"],
    ["/usr/local/bin/docker compose up", "up"],
    ["FOO=1 docker compose up", "up"],
    ["sudo -u me docker compose up", "up"],
    ["env A=1 docker compose up", "up"],
    ["timeout 30 docker compose up", "up"],
    ["cd server && docker compose up", "up"],
    ["npm i; docker compose up", "up"],
    ["true || docker compose up", "up"],
    ["(docker compose up)", "up"],
    ["echo $(docker compose up)", "up"],
    ["bash -lc 'docker compose up -d'", "up"],
    ['sh -c "cd x && docker compose up"', "up"],
    ["do\\\ncker compose up", "up"],
    ["docker compose ps", "ps"],
  ] as const) {
    assert.deepEqual(subcommands(command), [expected], command);
  }
});

test("只是提到它、或者别的 docker 命令，都不算", () => {
  for (const command of [
    'git commit -m "docker compose up"',
    "git commit -m 'fix: docker compose up 失败'",
    "echo docker compose up",
    "grep -r 'docker compose up' docs",
    "# docker compose up",
    "docker ps",
    "docker run postgres",
    "docker build .",
    "docker compose",
    "docker compose up --help",
    "cat docker-compose.yml",
    "ls docker-compose",
  ]) {
    const found = subcommands(command).filter((sub) => ["up", "start", "run"].includes(sub));
    assert.deepEqual(found, [], command);
  }
});

test("docker run：直接起一个容器", () => {
  const found = (command: string) => simpleCommands(command).some(({ argv }) => isDockerRun(argv));
  for (const command of [
    "docker run postgres",
    "docker run -d --rm -p 5432 -e POSTGRES_PASSWORD=x postgres:17",
    "docker --context prod run alpine true",
    "/usr/local/bin/docker run alpine",
    "sudo docker run alpine",
    "cd x && docker run alpine",
    "bash -c 'docker run alpine'",
    "id=$(docker run -d redis)",
    "docker container run -d redis",
    "docker --context prod container run alpine true",
  ]) {
    assert.equal(found(command), true, command);
  }
  for (const command of [
    "docker container ls",
    "docker container exec db run",
    "docker container run --help",
    "docker compose run api sh",
    "docker-compose run api",
    "docker ps",
    "docker exec db run",
    "docker run --help",
    "echo docker run postgres",
    'git commit -m "docker run 改成 napbox"',
    "npm run dev",
  ]) {
    assert.equal(found(command), false, command);
  }
});

test("记下命令之前的 cd", () => {
  const [compose] = simpleCommands("cd a/b && cd ../c; docker compose up");
  assert.deepEqual(compose?.cds, ["a/b", "../c"]);
  const [inShell] = simpleCommands("cd a && bash -c 'cd b && docker compose up'");
  assert.deepEqual(inShell?.cds, ["a", "b"]);
  const [dynamic] = simpleCommands('cd "$HOME" && docker compose up');
  assert.deepEqual(dynamic?.cds, []);
});

test("自己起服务的命令", () => {
  const service = (command: string) => startsOwnService(simpleCommands(command)[0]?.argv ?? []);
  assert.equal(service("postgres -D data"), "postgres");
  assert.equal(service("redis-server --port 6380"), "redis-server");
  assert.equal(service("pg_ctl -D data start"), "pg_ctl");
  assert.equal(service("minio server /data"), "minio server");
  assert.equal(service("brew services start postgresql@17"), "brew services");
  assert.equal(service("postgres --version"), undefined);
  assert.equal(service("pg_ctl -D data status"), undefined);
  assert.equal(service("minio --help"), undefined);
  assert.equal(service("brew services list"), undefined);
  assert.equal(service("psql -h localhost"), undefined);
  assert.equal(service("npm run dev"), undefined);
});
