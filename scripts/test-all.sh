#!/bin/bash
# 发版前的整套测试，一条命令跑完：
#   scripts/test-all.sh
# 起虚拟机的几组（vm、build、watch、temp、test-up，最后 test-package）一个接一个跑：它们分到同一段环境 IP，不能同时跑。
# 不起虚拟机的两组（test-native 含 swift test、不带参数的 test-client）和它们同时跑：只在临时目录里起不开虚拟机的
# napboxd，用的端口是 384xx，napbox 分配的是 40000–49999，不会撞。test-package 要查没有任何 napboxd 在跑，
# 所以等这两组跑完再跑。
# 先编译好 debug、release 两份，把产物目录克隆到临时目录给各组用（NAPBOX_BUILT_DEBUG / NAPBOX_BUILT_RELEASE）：
# swift test 会在 native/.build 里重新编译，不能换掉别的组正在用的程序。
# 前提和各组一样：先停掉正在用的 napboxd，要能上外网。test-package 的 NAPBOX_TEST_KERNEL、NAPBOX_TEST_RUNC 照常传下去。
# 每组的输出写进日志目录，最后列出每组的结果和用时。
set -uo pipefail
source "$(dirname "$0")/lib.sh"
cd "$root" || exit 1
[ -x node_modules/.bin/tsc ] || { echo "先在仓库根目录运行 pnpm install"; exit 1; }
if pgrep -x napboxd >/dev/null; then
    echo "有 napboxd 在运行，先停掉它再测（起虚拟机的几组和它会分到同一个环境 IP）"
    exit 1
fi

began=$SECONDS
logs="$(mktemp -d -t napbox-all)"
echo "各组的输出在 $logs"

echo "编译"
for config in debug release; do
    out="$(scripts/build-native.sh "$config" 2>&1)" || { tail -40 <<<"$out"; echo "编译失败（$config）"; exit 1; }
    # 整个产物目录 APFS 克隆一份：napboxd 要用的 napbox-guard、mke2fs 这些都在它旁边，克隆马上好、不占空间
    cp -c -R "$(tail -1 <<<"$out")" "$logs/bin-$config"
done
export NAPBOX_BUILT_DEBUG="$logs/bin-debug" NAPBOX_BUILT_RELEASE="$logs/bin-release"
echo "  编译用了 $((SECONDS - began)) 秒"

group() { # group <名字> <命令...>：跑一组，输出写进 <名字>.log，结果和用时追加到 results
    local name="$1" start=$SECONDS code
    shift
    echo "开始 $name（$(date +%H:%M:%S)）"
    "$@" >"$logs/$name.log" 2>&1; code=$?
    echo "$name $code $((SECONDS - start))" >>"$logs/results"
    echo "结束 $name：$([ "$code" -eq 0 ] && echo 通过 || echo "失败，退出码 $code")，$((SECONDS - start)) 秒"
}

group native scripts/test-native.sh &
native=$!
group client scripts/test-client.sh &
client=$!
for name in vm build watch temp; do group "$name" scripts/test-client.sh "$name"; done
group up scripts/test-up.sh
wait "$native" "$client"
group package scripts/test-package.sh

echo
echo "组        结果   用时"
failed_groups=0
while read -r name code seconds; do
    printf '%-9s %s  %4d 秒\n' "$name" "$([ "$code" -eq 0 ] && echo 通过 || echo 失败)" "$seconds"
    [ "$code" -eq 0 ] || failed_groups=$((failed_groups + 1))
done <"$logs/results"
echo "整套用了 $((SECONDS - began)) 秒"
if [ "$failed_groups" -ne 0 ]; then
    echo "$failed_groups 组失败，看 $logs 里对应的 .log"
    exit 1
fi
rm -rf "$logs"
