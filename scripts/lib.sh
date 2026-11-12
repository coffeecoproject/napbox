# test-native.sh 和 test-up.sh 共用的部分：编译、计数的 check、结尾的汇总。用 source 引入。
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# 编译（默认 debug 版），设好 bin、napboxd、napbox；编译失败时输出最后的编译信息并退出
build_native() {
    local out
    out="$("$root/scripts/build-native.sh" "${1:-debug}" 2>&1)" || { tail -40 <<<"$out"; echo "编译失败"; exit 1; }
    bin="$(tail -1 <<<"$out")"
    napboxd="$bin/napboxd"
    napbox="$bin/napbox"
}

passed=0 failed=0
check() { # check <说明> <命令...>：命令成功算通过
    local name="$1"; shift
    if "$@"; then passed=$((passed + 1)); echo "  通过  $name"
    else failed=$((failed + 1)); echo "  失败  $name（$(date +%H:%M:%S)）"; fi
}

# 输出通过、失败各几个；有失败时返回 1
summary() {
    echo
    echo "通过 $passed，失败 $failed"
    [ "$failed" -eq 0 ]
}

# 像调用方一样直接走 socket（要先设好 sock）。发一个请求，输出最后的回应（result 或 error 那一行）
rpc() { # rpc <方法> <params 的 JSON>
    python3 -I -c '
import json, socket, sys
s = socket.socket(socket.AF_UNIX)
s.connect(sys.argv[1])
s.sendall((json.dumps({"id": 1, "method": sys.argv[2], "params": json.loads(sys.argv[3])}) + "\n").encode())
for line in s.makefile():
    if "output" not in json.loads(line):
        print(line, end="")
        break
' "$sock" "$1" "$2"
}

# 后台订阅事件，每条回应一行写进文件，等订阅生效才返回；pid 放进 subscriber
subscribe_to() { # subscribe_to <文件> <params 的 JSON>
    python3 -I -u -c '
import json, socket, sys
s = socket.socket(socket.AF_UNIX)
s.connect(sys.argv[1])
s.sendall((json.dumps({"id": 1, "method": "subscribe", "params": json.loads(sys.argv[3])}) + "\n").encode())
with open(sys.argv[2], "w", buffering=1) as out:
    for line in s.makefile():
        out.write(line)
' "$sock" "$1" "$2" &
    subscriber=$!
    for _ in $(seq 1 50); do grep -q '"subscribed"' "$1" 2>/dev/null && return 0; sleep 0.1; done
    return 1
}
