// 插件把每个版本的包装进缓存目录（scripts/server-launcher.mjs）。一周没启动过的版本删掉，别的版本要用时重新安装。
import { readdir, rm, stat } from "node:fs/promises";
import path from "node:path";
import { cacheDirectory, packageVersion } from "./locations.ts";

const KEEP_MS = 7 * 24 * 60 * 60 * 1000;

export async function sweepCachedVersions() {
  const versions = path.join(cacheDirectory(), "versions");
  const names = await readdir(versions).catch(() => [] as string[]);
  for (const name of names) {
    if (name === packageVersion) continue;
    const directory = path.join(versions, name);
    const used = await stat(path.join(directory, "last-used")).catch(() => stat(directory));
    if (Date.now() - used.mtimeMs > KEEP_MS) await rm(directory, { recursive: true, force: true });
  }
}
