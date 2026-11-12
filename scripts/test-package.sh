#!/bin/bash
# 打包和安装的全流程，照用户装插件时的路径走一遍（DESIGN.md 第 4 节）。真的注册 launchd 服务、起虚拟机。
# 用隔离的 HOME 和 NAPBOX_SUPPORT_DIR；launchd 服务用另一个名字，测完注销，不碰正式的登录项。
#
#   scripts/test-package.sh
#
# 第一次下载约 700MB 的内核包。设 NAPBOX_TEST_KERNEL=<已解出的 vmlinux-6.18.35-197> 时跳过下载（改了 Prepare 后不要设）。
# 要能上外网，要先停掉正在用的 napboxd（环境 IP 相同），不要和别的测试同时跑。
set -uo pipefail
source "$(dirname "$0")/lib.sh"
cd "$root" || exit 1
[ -x node_modules/.bin/tsc ] || { echo "先在仓库根目录运行 pnpm install"; exit 1; }
if pgrep -x napboxd >/dev/null; then
    echo "有 napboxd 在运行，先停掉它再测（两边会分到同一个环境 IP）"
    exit 1
fi
node scripts/pack.ts || { echo "打包失败"; exit 1; }
node --test --test-reporter=spec --test-concurrency=1 test/package.test.ts
