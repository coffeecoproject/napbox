#!/bin/bash
# TypeScript 客户端的测试。用法：
#   scripts/test-client.sh      类型检查、和 Protocol.swift 的逐字段比较、真实 napboxd（不起虚拟机）。不到 1 分钟
#   scripts/test-client.sh vm   真的起虚拟机，把每个接口走一遍。约 5 分钟，要先停掉正在用的 napboxd，也不要和 test-up.sh 同时跑
#   scripts/test-client.sh build  真的构建镜像，约 5 分钟，要能访问 Docker Hub，前提和 vm 一样
#   scripts/test-client.sh watch  文件变化通知和 develop.watch，约 3 分钟，要能访问 Docker Hub 和 npm，前提和 vm 一样
#   scripts/test-client.sh temp   临时环境（up --temp）和 napbox run，命令行、客户端、MCP 工具都走，约 3 分钟（有一条要等 1 分钟闲置），前提和 vm 一样
# 每次都用临时的 NAPBOX_SUPPORT_DIR，不碰正在用的环境。改了 native/Sources/NapboxProtocol 或 src/ 后跑。
# 打包、安装、setup 的全流程在 scripts/test-package.sh。
set -uo pipefail
source "$(dirname "$0")/lib.sh"
cd "$root" || exit 1
[ -x node_modules/.bin/tsc ] || { echo "先在仓库根目录运行 pnpm install"; exit 1; }
# 调试版解镜像慢得不能用（DESIGN.md 第 2 节「镜像构建实测」），要解新镜像的这两组用正式版
if [ "${1:-}" = build ] || [ "${1:-}" = watch ]; then build_native release; else build_native; fi
export NAPBOX_BIN="$bin"

run_node_tests() { node --test --test-reporter=spec --test-concurrency=1 "$@"; }

if [ "${1:-}" = vm ] || [ "${1:-}" = build ] || [ "${1:-}" = watch ] || [ "${1:-}" = temp ]; then
    real="$HOME/Library/Application Support/napbox"
    # 正在用的 napboxd 会分配同一段 IP，测试时不能同时运行
    if NAPBOX_SUPPORT_DIR="$real" "$napbox" status >/dev/null 2>&1; then
        echo "正在用的 napboxd 在运行，先停掉它再测（两边会分到同一个环境 IP）"
        exit 1
    fi
    for need in "$real/images" "$real/kernel/vmlinux" "$real/runc"; do
        [ -e "$need" ] || { echo "缺 $need：先用正常的 napboxd 跑一次 up，把镜像、内核和 runc 准备好（napbox setup）"; exit 1; }
    done
    export NAPBOX_REAL_SUPPORT_DIR="$real"
    run_node_tests "test/$1.test.ts"
    exit $?
fi

node_modules/.bin/tsc --noEmit || { echo "类型检查失败"; exit 1; }
run_node_tests test/contract.test.ts test/client.test.ts test/shell-command.test.ts test/agent.test.ts
