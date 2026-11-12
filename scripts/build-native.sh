#!/bin/bash
# 编译 napboxd 和 napbox，并给 napboxd 自己签名（只带虚拟化权限）；再编译网络小容器的程序 napbox-guard。
# 用法：scripts/build-native.sh [debug|release]，最后一行输出产物目录（Swift 6.4 起是 native/.build/out/Products/<配置>/）
set -euo pipefail
config="${1:-debug}"
root="$(cd "$(dirname "$0")/.." && pwd)"
# 源码路径换成 /napbox 开头：程序里会留下依赖库源码的路径（断言、#file），发布的包里不能带本机目录
swift build --package-path "$root/native" -c "$config" \
    -Xswiftc -file-prefix-map -Xswiftc "$root/native=/napbox" -Xcc "-ffile-prefix-map=$root/native=/napbox"
bin="$(swift build --package-path "$root/native" -c "$config" --show-bin-path)"
# 正式版去掉调试符号：符号表里记着每个中间文件的本机路径。要在签名前做
[ "$config" = release ] && strip -S "$bin/napbox" "$bin/napboxd"
codesign -f -s - --entitlements "$root/native/napboxd.entitlements" "$bin/napboxd"
# 网络小容器的程序：Linux arm64 静态程序，放在 napboxd 旁边（DESIGN.md 第 6 节）。用本机的 Go，不自动下载别的版本
(cd "$root/guard" && GOTOOLCHAIN=local GOOS=linux GOARCH=arm64 CGO_ENABLED=0 go build -trimpath -ldflags=-s -o "$bin/napbox-guard" .)
echo "$bin"
