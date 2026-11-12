// 包自己的位置和版本。发布后是 dist/agent/ 下的 .js，仓库里是 src/agent/ 下的 .ts，往上两层都是包的根目录。
import { readFileSync } from "node:fs";
import { homedir } from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

export const packageRoot = fileURLToPath(new URL("../../", import.meta.url));

export const packageVersion: string = JSON.parse(
  readFileSync(path.join(packageRoot, "package.json"), "utf8"),
).version;

/** 编译好的 napbox、napboxd、napbox-guard。发布的包在 native/ 下；仓库里没有，要用 NAPBOX_BIN 指向编译产物 */
export const nativeDirectory = (): string =>
  process.env.NAPBOX_BIN || path.join(packageRoot, "native");

/** 插件把固定版本的包装在这里。可以随时删，下次用到时重新安装；napboxd 不放这里 */
export const cacheDirectory = (): string => path.join(homedir(), "Library/Caches/napbox");
