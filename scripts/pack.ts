// 打 npm 包到 .pack/napbox-<版本>.tgz：编译好的 Swift 和 Go 程序（release）、编译成 JS 的 TypeScript、发布用的 package.json。
//
// 用法：node scripts/pack.ts
import { execFile as execFileCallback } from "node:child_process";
import { existsSync } from "node:fs";
import { chmod, copyFile, mkdir, readdir, readFile, rm, writeFile } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { promisify } from "node:util";
import { launcher } from "./plugins.ts";

const execFile = promisify(execFileCallback);
const root = fileURLToPath(new URL("../", import.meta.url));
const out = path.join(root, ".pack");
const target = path.join(out, "package");

const source = JSON.parse(await readFile(path.join(root, "package.json"), "utf8"));
const protocol = await readFile(path.join(root, "native/Sources/NapboxProtocol/Protocol.swift"), "utf8");
const swiftVersion = /static let current = "([^"]+)"/.exec(protocol)?.[1];
if (swiftVersion !== source.version) {
  throw new Error(`NapboxVersion.current 是 ${swiftVersion}，package.json 是 ${source.version}，要一致`);
}

await rm(out, { recursive: true, force: true });
await mkdir(path.join(target, "native"), { recursive: true });

process.stdout.write("编译原生程序（release）\n");
const { stdout } = await execFile(path.join(root, "scripts/build-native.sh"), ["release"], {
  maxBuffer: 1 << 26,
});
const products = stdout.trim().split("\n").at(-1) as string;
for (const name of ["napbox", "napboxd", "napbox-guard"]) {
  await copyFile(path.join(products, name), path.join(target, "native", name));
  await chmod(path.join(target, "native", name), 0o755);
}

for (const name of ["LICENSE", "NOTICE", "README.md", "README.zh-CN.md"]) {
  await copyFile(path.join(root, name), path.join(target, name));
}
await writeFile(path.join(target, "THIRD_PARTY_NOTICES.txt"), await thirdPartyNotices());

process.stdout.write("编译 TypeScript\n");
await execFile(
  path.join(root, "node_modules/.bin/tsc"),
  ["-p", path.join(root, "tsconfig.pack.json"), "--outDir", path.join(target, "dist")],
  { cwd: root },
);
await chmod(path.join(target, "dist/cli.js"), 0o755);
await writeFile(
  path.join(target, "dist/server-launcher.mjs"),
  await launcher("server-launcher.mjs", source.version),
);

await writeFile(
  path.join(target, "package.json"),
  `${JSON.stringify(
    {
      name: "napbox",
      version: source.version,
      description: source.description,
      type: "module",
      bin: { napbox: "dist/cli.js" },
      exports: { ".": { types: "./dist/index.d.ts", default: "./dist/index.js" } },
      files: ["dist", "native", "NOTICE", "THIRD_PARTY_NOTICES.txt", "README.zh-CN.md"],
      license: source.license,
      engines: source.engines,
      os: ["darwin"],
      cpu: ["arm64"],
      dependencies: source.dependencies,
      homepage: "https://github.com/coffeecoproject/napbox",
      repository: { type: "git", url: "git+https://github.com/coffeecoproject/napbox.git" },
      keywords: ["docker-compose", "worktree", "dev-environment", "mcp", "claude-code", "macos"],
    },
    null,
    2,
  )}\n`,
);
const packed = await execFile("npm", ["pack", "--pack-destination", out], { cwd: target });
process.stdout.write(`${path.join(out, packed.stdout.trim().split("\n").at(-1) as string)}\n`);

/** 打进包里的第三方代码的许可证和 NOTICE：Swift 包按 Package.resolved，napbox-guard 按实际链接的 Go 模块，再加 Go 标准库 */
async function thirdPartyNotices(): Promise<string> {
  const sections: string[] = [];
  const rule = "=".repeat(78);
  const add = async (title: string, ...directories: string[]) => {
    const files: string[] = [];
    for (const directory of directories) {
      for (const name of (await readdir(directory)).sort()) {
        if (/^(LICEN[CS]E|COPYING|NOTICES?|PATENTS)(\.(txt|md))?$/i.test(name)) files.push(path.join(directory, name));
      }
    }
    if (!files.some((file) => /^(LICEN[CS]E|COPYING)/i.test(path.basename(file)))) {
      throw new Error(`${title} 没有许可证文件（${directories.join("、")}）`);
    }
    for (const file of files) {
      const name = path.basename(file);
      const text = (await readFile(file, "utf8")).trimEnd();
      sections.push(`${rule}\n${title}: ${name}\n${rule}\n\n${text}\n`);
    }
  };
  const resolved = JSON.parse(await readFile(path.join(root, "native/Package.resolved"), "utf8"));
  for (const pin of resolved.pins) {
    const checkout = path.join(root, "native/.build/checkouts", path.basename(pin.location, ".git"));
    await add(`${pin.identity} ${pin.state.version ?? pin.state.revision} (${pin.location})`, checkout);
  }
  const go = { cwd: path.join(root, "guard"), env: { ...process.env, GOTOOLCHAIN: "local", GOOS: "linux", GOARCH: "arm64", CGO_ENABLED: "0" } };
  const format = "{{with .Module}}{{if not .Main}}{{.Path}} {{.Version}} {{.Dir}}{{end}}{{end}}";
  const { stdout: modules } = await execFile("go", ["list", "-deps", "-f", format, "."], go);
  for (const line of [...new Set(modules.trim().split("\n"))].sort()) {
    const [module, version, directory] = line.split(" ");
    await add(`${module} ${version}`, directory as string);
  }
  const { stdout: goEnv } = await execFile("go", ["env", "GOROOT", "GOVERSION"], go);
  const [goroot, goVersion] = goEnv.trim().split("\n");
  // Homebrew 装的 Go 把 LICENSE 放在 GOROOT 的上一层（PATENTS 还在 GOROOT 里）
  const goLicense = existsSync(path.join(goroot as string, "LICENSE")) ? [] : [path.dirname(goroot as string)];
  await add(`Go standard library (${goVersion})`, goroot as string, ...goLicense);
  return `Licenses and notices of the third-party software compiled into the programs in native/.\n\n${sections.join("\n")}`;
}
