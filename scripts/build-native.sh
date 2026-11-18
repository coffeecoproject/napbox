#!/bin/bash
# 编译 napboxd 和 napbox，并给 napboxd 自己签名（只带虚拟化权限）；再编译网络小容器的程序 napbox-guard，
# 和建数据卷、构建缓存用的 mke2fs、debugfs（e2fsprogs）。
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
# 网络小容器的程序：Linux arm64 静态程序，放在 napboxd 旁边。用本机的 Go，不自动下载别的版本
(cd "$root/guard" && GOTOOLCHAIN=local GOOS=linux GOARCH=arm64 CGO_ENABLED=0 go build -trimpath -ldflags=-s -o "$bin/napbox-guard" .)

# 数据卷和构建缓存用 e2fsprogs 的 mke2fs 建（native/Sources/NapboxRuntime/DataDisk.swift），去掉 lost+found 用它的
# debugfs：从固定版本的源码编译 macOS 版，连同它自带的 mke2fs.conf 放在 napboxd 旁边。源码包按 sha256 校验后留着，
# 发布时原样放进包里（mke2fs、debugfs 是 GPLv2，scripts/pack.ts）。编译结果按版本留在 native/.build 下，下次直接用
e2fsprogs_version=1.47.4
e2fsprogs_sha256=da274408bebbfd13a5a2fc3cfc66e3ffff17c48534673aa67f88d49b99123b96
e2fsprogs="$root/native/.build/e2fsprogs-$e2fsprogs_version"
e2fsprogs_tarball="$e2fsprogs/e2fsprogs-$e2fsprogs_version.tar.gz"
if [ ! -x "$e2fsprogs/build/misc/mke2fs" ] || [ ! -x "$e2fsprogs/build/debugfs/debugfs" ]; then
    rm -rf "$e2fsprogs/src" "$e2fsprogs/build"
    mkdir -p "$e2fsprogs/src" "$e2fsprogs/build"
    if ! echo "$e2fsprogs_sha256  $e2fsprogs_tarball" | shasum -a 256 -c - >/dev/null 2>&1; then
        curl -fsSL -o "$e2fsprogs_tarball" \
            "https://mirrors.edge.kernel.org/pub/linux/kernel/people/tytso/e2fsprogs/v$e2fsprogs_version/e2fsprogs-$e2fsprogs_version.tar.gz"
        echo "$e2fsprogs_sha256  $e2fsprogs_tarball" | shasum -a 256 -c - >/dev/null \
            || { echo "e2fsprogs-$e2fsprogs_version.tar.gz 的 sha256 不对" >&2; rm -f "$e2fsprogs_tarball"; exit 1; }
    fi
    tar -xzf "$e2fsprogs_tarball" -C "$e2fsprogs/src" --strip-components=1
    # 只要 mke2fs、debugfs 和它们用的库；源码路径同样换掉
    (cd "$e2fsprogs/build" &&
        CFLAGS="-O2 -ffile-prefix-map=$e2fsprogs=/e2fsprogs" ../src/configure --disable-nls --disable-fuse2fs \
            --disable-e2initrd-helper --disable-defrag --disable-tdb --disable-uuidd --without-libarchive \
            --disable-imager --disable-resizer >/dev/null &&
        make -j"$(sysctl -n hw.ncpu)" libs >/dev/null &&
        make -j"$(sysctl -n hw.ncpu)" -C misc mke2fs >/dev/null &&
        make -j"$(sysctl -n hw.ncpu)" -C debugfs debugfs >/dev/null)
fi
cp "$e2fsprogs/build/misc/mke2fs" "$e2fsprogs/build/debugfs/debugfs" "$bin/"
cp "$e2fsprogs/build/misc/mke2fs.conf" "$bin/mke2fs.conf"
[ "$config" = release ] && strip -S "$bin/mke2fs" "$bin/debugfs"
codesign -f -s - "$bin/mke2fs" "$bin/debugfs"
echo "$bin"
