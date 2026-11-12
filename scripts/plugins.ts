// 生成 Claude Code 插件里带版本号的文件和 marketplace 条目（skill、README 是手写的，在 plugins/claude 下）。
// 发布的插件用 scripts/server-launcher.mjs 从 npm 装固定版本；--dev 生成一份直接运行这个仓库的插件，发布前试用。
//
// 用法：node scripts/plugins.ts [--dev <目录>]
import { cp, mkdir, readFile, writeFile } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";

const root = fileURLToPath(new URL("../", import.meta.url));
const REPOSITORY = "https://github.com/coffeecoproject/napbox";
const DESCRIPTION =
  "给 coding agent 用的 Mac 本地开发环境：每个 worktree 一套隔离的数据库和后端服务，端口不冲突，闲置自动休眠，不依赖 Docker。";

const json = (value: unknown) => `${JSON.stringify(value, null, 2)}\n`;

export const launcher = async (template: string, version: string) => {
  const text = await readFile(path.join(root, "scripts", template), "utf8");
  return `// 由 scripts/plugins.ts 从 scripts/${template} 生成。\n${text.replace("__VERSION__", JSON.stringify(version))}`;
};

const hooks = (command: string) => {
  const hook = { type: "command", command, timeout: 30 };
  return json({
    description: "会话开始和压缩后告诉 agent 端口；已接入的项目拦下 docker compose up。",
    hooks: {
      SessionStart: [{ hooks: [hook] }],
      PreToolUse: [{ matcher: "Bash", hooks: [hook] }],
    },
  });
};

interface Launch {
  server: { command: string; args: string[] };
  hook: string;
}

/** 插件目录里要生成的文件，路径相对于插件目录 */
function pluginFiles(version: string, launch: Launch): Record<string, string> {
  return {
    ".claude-plugin/plugin.json": json({
      name: "napbox",
      displayName: "napbox",
      version,
      description: DESCRIPTION,
      author: { name: "The napbox Authors", url: REPOSITORY },
      homepage: REPOSITORY,
      repository: REPOSITORY,
      license: "Apache-2.0",
      keywords: ["docker-compose", "worktree", "dev-environment", "mcp", "macos"],
    }),
    // alwaysLoad：工具列表每一轮都在，不用先搜索
    ".mcp.json": json({ mcpServers: { napbox: { ...launch.server, alwaysLoad: true } } }),
    "hooks/hooks.json": hooks(launch.hook),
  };
}

async function writeAll(directory: string, files: Record<string, string>) {
  for (const [name, content] of Object.entries(files)) {
    const file = path.join(directory, name);
    await mkdir(path.dirname(file), { recursive: true });
    await writeFile(file, content);
  }
}

/** 发布用的全部生成文件，路径相对于仓库根目录 */
export async function generatedFiles(version: string): Promise<Record<string, string>> {
  const plugin = pluginFiles(version, {
    server: { command: "node", args: ["${CLAUDE_PLUGIN_ROOT}/server.mjs"] },
    hook: 'node "${CLAUDE_PLUGIN_ROOT}/hooks/napbox.mjs"',
  });
  const files: Record<string, string> = {
    ".claude-plugin/marketplace.json": json({
      $schema: "https://anthropic.com/claude-code/marketplace.schema.json",
      name: "napbox",
      description: "napbox for Claude Code.",
      owner: { name: "The napbox Authors", url: REPOSITORY },
      plugins: [
        { name: "napbox", source: "./plugins/claude", description: DESCRIPTION, category: "development" },
      ],
    }),
    "plugins/claude/server.mjs": await launcher("server-launcher.mjs", version),
    "plugins/claude/hooks/napbox.mjs": await launcher("hook-launcher.mjs", version),
  };
  for (const [name, content] of Object.entries(plugin)) files[`plugins/claude/${name}`] = content;
  return files;
}

async function main() {
  const { version } = JSON.parse(await readFile(path.join(root, "package.json"), "utf8"));
  const devIndex = process.argv.indexOf("--dev");
  if (devIndex < 0) {
    await writeAll(root, await generatedFiles(version));
    return;
  }
  const directory = path.resolve(process.argv[devIndex + 1] as string);
  const cli = path.join(root, "src/cli.ts");
  await cp(path.join(root, "plugins/claude/skills"), path.join(directory, "skills"), { recursive: true });
  await writeAll(
    directory,
    pluginFiles(version, {
      server: { command: process.execPath, args: [cli, "mcp"] },
      hook: `"${process.execPath}" "${cli}" hook`,
    }),
  );
  process.stdout.write(`${directory}\n`);
}

if (process.argv[1] === fileURLToPath(import.meta.url)) await main();
