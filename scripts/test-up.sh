#!/bin/bash
# napbox up 的端到端测试：真的起虚拟机。照真实项目的样子准备一份 compose：
#   db    postgres，带 healthcheck 和命名卷
#   seed  一次性服务，等 db 健康后用服务名 db 连上去写一行（测 hosts、依赖顺序）
#   web   有端口、没有 healthcheck 的服务，等 seed 成功跑完才启动；启动时报告根文件系统是新的还是沿用的
#   probe 连上它的端口就得到一个 shell，在环境里执行命令（测出网规则）
# 在临时 git 仓库和临时 napbox 目录（NAPBOX_SUPPORT_DIR）里跑，不碰别的项目。镜像库和内核链接到
# ~/Library/Application Support/napbox 里已有的，不重新下载。要起虚拟机，所以不放进 test-native.sh；
# 改了 NapboxRuntime 或端口代理后手动跑。用法：scripts/test-up.sh
set -uo pipefail
source "$(dirname "$0")/lib.sh"
build_native
real="$HOME/Library/Application Support/napbox"

# 正在用的 napboxd 会分配同一段 IP，测试时不能同时运行
if NAPBOX_SUPPORT_DIR="$real" "$napbox" status >/dev/null 2>&1; then
    echo "正在用的 napboxd 在运行，先停掉它再测（两边会分到同一个环境 IP）"
    exit 1
fi
for need in "$real/images" "$real/kernel/vmlinux" "$real/runc"; do
    [ -e "$need" ] || { echo "缺 $need：先用正常的 napboxd 跑一次 up，把镜像、内核和 runc 准备好（napbox setup）"; exit 1; }
done
command -v psql >/dev/null || { echo "要用 psql 检查数据库"; exit 1; }

work="$(mktemp -d -t napbox-up)"
export NAPBOX_SUPPORT_DIR="$work/support"
mkdir -p "$NAPBOX_SUPPORT_DIR"
ln -s "$real/images" "$NAPBOX_SUPPORT_DIR/images"
ln -s "$real/kernel" "$NAPBOX_SUPPORT_DIR/kernel"
ln -s "$real/runc" "$NAPBOX_SUPPORT_DIR/runc"
sock="$NAPBOX_SUPPORT_DIR/napboxd.sock"
repo="$work/demo"
daemon=""
cleanup() {
    [ -n "$daemon" ] && kill -TERM "$daemon" 2>/dev/null && wait "$daemon" 2>/dev/null
    # 有失败时留着整个目录（napboxd 日志、各服务日志、web_says.log）查原因
    if [ "$failed" -ne 0 ]; then echo "测试目录留着：$work"; return; fi
    rm -rf "$work" # 链接只删链接本身，不会删到链接指向的镜像库
}
trap cleanup EXIT

# 汇总并退出；有失败时附上 napboxd 日志和 web_says.log
finish() {
    summary && exit 0
    echo "napboxd 日志："; cat "$work/napboxd.log"; echo "web_says.log："; cat "$work/web_says.log" 2>/dev/null
    exit 1
}
start_daemon() {
    "$napboxd" >>"$work/napboxd.log" 2>&1 &
    daemon=$!
    for _ in $(seq 1 50); do "$napbox" status >/dev/null 2>&1 && return 0; sleep 0.2; done
    return 1
}
stop_daemon() { kill -TERM "$daemon"; wait "$daemon"; code=$?; daemon=""; }
port_of() { jq -r ".ports[] | select(.service == \"$1\") | .hostPort" <<<"$up"; }
# 经端口代理连一个服务，输出它回的第一行。每次的结果（用时、超时还是被断开）记进 web_says.log，失败时查。
# 最多等 30 秒：连接进来时环境可能还在停（status 已经是休眠），要先等它停完再唤醒；机器忙时唤醒本身也要
# 3–4 秒。2026-11-07 实测碰到过停 2 秒加唤醒 4.1 秒，超过了原来的 5 秒
web_says() { python3 -I -c '
import socket, sys, time
port, log = int(sys.argv[1]), sys.argv[2]
start = time.time()
def note(what):
    with open(log, "a") as f:
        f.write("%s 端口 %d：%s，用了 %.2f 秒\n" % (time.strftime("%H:%M:%S"), port, what, time.time() - start))
try:
    s = socket.create_connection(("127.0.0.1", port), timeout=30)
    data = s.recv(100)
except Exception as e:
    note("出错 %r" % e); sys.exit(1)
note("回了 %r" % data if data else "连上后被断开，什么都没回")
print(data.decode().strip())' "$1" "$work/web_says.log" 2>/dev/null; }
# 在 probe 容器里执行一条 shell 命令，输出它的结果
in_env() { python3 -I -c '
import socket, sys
s = socket.create_connection(("127.0.0.1", int(sys.argv[1])), timeout=30)
s.sendall(sys.argv[2].encode() + b"\n"); s.shutdown(socket.SHUT_WR)
out = b""
while True:
    d = s.recv(4096)
    if not d: break
    out += d
print(out.decode().strip())' "$probe" "$1" 2>&1; }
# 在环境里连 地址 端口，输出 通 或 不通
reach() { in_env "nc -z -w 3 $1 $2 && echo 通 || echo 不通"; }
sql() { PGCONNECT_TIMEOUT=5 PGPASSWORD=t psql -h 127.0.0.1 -p "$1" -U t -d t -Atc "$2" 2>&1; }
write_compose() { # write_compose <web 的消息> [闲置几分钟休眠]
    cat >"$repo/compose.yaml" <<YAML
x-napbox: {idle_minutes: ${2:-30}}
services:
  db:
    image: postgres:17-alpine
    environment: {POSTGRES_USER: t, POSTGRES_PASSWORD: t, POSTGRES_DB: t}
    ports: ["127.0.0.1:5432:5432"]
    volumes: [data:/var/lib/postgresql/data]
    healthcheck: {test: ["CMD", "pg_isready", "-U", "t"], interval: 1s, retries: 30}
  seed:
    image: postgres:17-alpine
    environment: {PGPASSWORD: t}
    entrypoint: ["sh", "-c", "psql -h db -U t -d t -c 'create table if not exists seeded(x int); insert into seeded values (1)'"]
    depends_on: {db: {condition: service_healthy}}
  web:
    image: alpine:3.20
    environment: {MSG: $1}
    command: ["sh", "-c", "if [ -f /marker ]; then s=reused; else s=fresh; fi; touch /marker; while true; do echo \"\$\$s \$\$MSG\" | nc -l -p 8080; done"]
    ports: ["8080"]
    # sh 作为容器里的主进程不处理 SIGTERM（Docker 下也一样），停的时候等满 stop_grace_period 再强制结束
    stop_grace_period: 1s
    depends_on: {seed: {condition: service_completed_successfully}}
  probe:
    image: alpine:3.20
    # 启动时先输出 300 行，测 logs 默认只给最后 200 行
    command: ["sh", "-c", "seq 1 300; while true; do nc -l -p 9000 -e sh; done"]
    ports: ["9000"]
    stop_grace_period: 1s
volumes:
  data:
YAML
}

mkdir -p "$repo"
git -C "$repo" init -q
write_compose v1

echo "第一次 up"
start_daemon || { echo "napboxd 没起来"; cat "$work/napboxd.log"; exit 1; }
up="$(cd "$repo" && "$napbox" up)"; code=$?
check "up 成功" test "$code" -eq 0
# 第一次 up 不成功，后面全是连带的失败
[ "$code" -eq 0 ] || { echo "$up"; finish; }
db=$(port_of db); web=$(port_of web); probe=$(port_of probe)
check "分到三个端口" test -n "$db" -a -n "$web" -a -n "$probe"
check "web 经代理回话，根文件系统是新的" test "$(web_says "$web")" = "fresh v1"
check "seed 等 db 健康后用服务名连上并写入" test "$(sql "$db" 'select count(*) from seeded')" = "1"
check "写了 .napbox/ports.json" test -f "$repo/.napbox/ports.json"
check ".git/info/exclude 里有 .napbox/" grep -qx ".napbox/" "$repo/.git/info/exclude"

echo "再次 up（在运行、定义没变）"
again="$(cd "$repo" && "$napbox" up)"
check "端口不变" test "$(jq -c .ports <<<"$again")" = "$(jq -c .ports <<<"$up")"
check "没有重启（seed 没再跑）" test "$(sql "$db" 'select count(*) from seeded')" = "1"

state_is() { test "$("$napbox" status | jq -r '.environments[0].state')" = "$1"; }
# 最近一次启动以来的 db 日志里有 postgres 正常关闭的记录：收到 SIGINT 是 fast shutdown（SIGTERM 是 smart，
# 被强制结束则什么都没有），最后是 database system is shut down
db_shut_down_cleanly() {
    local last
    last="$(awk '/^----- napbox 启动/ { buf = "" } { buf = buf $0 "\n" } END { printf "%s", buf }' "$NAPBOX_SUPPORT_DIR"/environments/*/logs/db.log)"
    grep -q "received fast shutdown request" <<<"$last" && grep -q "database system is shut down" <<<"$last"
}

echo "napboxd 重启"
stop_daemon
check "SIGTERM 退出码 0" test "$code" -eq 0
check "退出前记下 seed 已经跑完" test "$(jq -c '.environments[0].completedServices' "$NAPBOX_SUPPORT_DIR/state.json")" = '["seed"]'
check "退出时按镜像的 STOPSIGNAL 停 postgres，正常关闭" db_shut_down_cleanly
start_daemon
check "重启后环境是休眠" state_is sleeping
check "连接进来自动唤醒，沿用根文件系统" test "$(web_says "$web")" = "reused v1"
check "唤醒后在运行" state_is running
check "唤醒时没有重新执行 seed，数据卷里的数据还在" test "$(sql "$db" 'select count(*) from seeded')" = "1"
again="$(cd "$repo" && "$napbox" up)"
check "唤醒后再 up：在运行、定义没变，直接返回" test "$(jq -c .ports <<<"$again")" = "$(jq -c .ports <<<"$up")" -a "$(sql "$db" 'select count(*) from seeded')" = "1"

echo "改了 compose 再 up"
write_compose v2
up="$(cd "$repo" && "$napbox" up)" || echo "$up"
check "web 的定义变了，根文件系统重建" test "$(web_says "$web")" = "fresh v2"
check "端口不变" test "$(port_of web)" = "$web"
check "显式 up 和 Docker 一样会再跑一次 seed" test "$(sql "$db" 'select count(*) from seeded')" = "2"

echo "出网规则"
# 宿主机上监听 0.0.0.0 的服务：没有规则时环境经网关或宿主机的局域网 IP 都能连到
hostport=$(python3 -I -c 'import socket; s=socket.socket(); s.bind(("", 0)); print(s.getsockname()[1])')
python3 -I -c 'import socket,sys,time; s=socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1); s.bind(("0.0.0.0", int(sys.argv[1]))); s.listen(8); time.sleep(600)' "$hostport" &
hostsvc=$!
# 先确认它在监听：否则下面的"不通"可能只是它还没起来
host_listening() { nc -z 127.0.0.1 "$hostport" 2>/dev/null; }
for _ in $(seq 1 50); do host_listening && break; sleep 0.1; done
check "宿主机上的服务在监听（对照）" host_listening
# 宿主机自己的所有 IPv4 地址：网关（bridge100）、局域网、Clash TUN 网卡（198.18.0.1，不在私有网段里）等
hostaddrs="$(ifconfig | awk '/inet / && $2 != "127.0.0.1" {print $2}')"
# 对外网发一个 HTTP 请求，3 秒后才发出去：期间切换出网模式，看已经建立的连接还能不能收到回应
# 后台跑，标准输入输出都不接 probe 的连接，in_env 马上返回。发完请求再等 3 秒：busybox 的 nc 读到
# 标准输入结束就关连接，等不到回应
http_later() { in_env "{ (sleep 3; printf 'GET / HTTP/1.0\\r\\nHost: one.one.one.one\\r\\n\\r\\n'; sleep 3) | nc -w 5 1.1.1.1 80 >/tmp/http.out 2>&1; } </dev/null >/dev/null 2>&1 &" >/dev/null; }
check "status 里新环境是 open" test "$("$napbox" status | jq -r '.environments[0].egress')" = "open"
check "项目的服务没有 NET_ADMIN，改不了规则" test "$(in_env 'echo $(( 0x$(awk "/CapEff/ {print \$2}" /proc/self/status) >> 12 & 1 ))')" = "0"
check "open：连不到宿主机（网关）上的服务" test "$(reach 192.168.64.1 "$hostport")" = "不通"
for a in $hostaddrs; do
    check "open：经宿主机的地址 $a 也连不到" test "$(reach "$a" "$hostport")" = "不通"
done
check "open：能连外网" test "$(reach 1.1.1.1 80)" = "通"
# open 和 none 用同一条命令查 DNS，open 下通就说明 none 下不通是规则挡的
dns="nslookup one.one.one.one >/dev/null 2>&1 && echo 通 || echo 不通"
check "open：DNS 能解析" test "$(in_env "$dns")" = "通"
http_later; sleep 7
check "open：外网请求收到回应" grep -q "HTTP/" <<<"$(in_env 'cat /tmp/http.out')"
http_later; sleep 1 # 等连接建立起来再切
switched="$(cd "$repo" && "$napbox" egress none)"
check "切到 none" test "$(jq -r .egress <<<"$switched")" = "none"
sleep 7
check "none：切换前建立的出网连接断了，收不到回应" test -z "$(in_env 'grep HTTP/ /tmp/http.out')"
check "none：连不到外网" test "$(reach 1.1.1.1 80)" = "不通"
check "none：DNS 也不通" test "$(in_env "$dns")" = "不通"
check "none：连不到宿主机上的服务" test "$(reach 192.168.64.1 "$hostport")" = "不通"
check "none：环境内服务互连照常" test "$(reach db 5432)" = "通"
check "none：宿主机经端口代理连进来照常" grep -q " v2$" <<<"$(web_says "$web")"
(cd "$repo" && "$napbox" sleep >/dev/null)
switched="$(cd "$repo" && "$napbox" egress open)"
check "休眠时切回 open：只改登记，环境还在休眠" test "$(jq -r '.state + " " + .egress' <<<"$switched")" = "sleeping open"
check "唤醒后按 open 加规则：能连外网" test "$(reach 1.1.1.1 80)" = "通"
kill "$hostsvc" 2>/dev/null; wait "$hostsvc" 2>/dev/null

echo "napbox sleep 和唤醒"
# 开一个连接挂着：发 PostgreSQL 的 SSLRequest，收到回应后不关，看休眠时会不会被断开
python3 -I -c '
import socket, struct, sys, time
s = socket.create_connection(("127.0.0.1", int(sys.argv[1])), timeout=20)
s.sendall(struct.pack("!ii", 8, 80877103)); s.recv(1)
print("opened", flush=True)
print("closed" if s.recv(1) == b"" else "data")
' "$db" >"$work/holder.out" 2>&1 &
holder=$!
for _ in $(seq 1 50); do grep -q opened "$work/holder.out" && break; sleep 0.1; done
slept="$(cd "$repo" && "$napbox" sleep)"
check "sleep 后是休眠" test "$(jq -r .state <<<"$slept")" = "sleeping"
wait "$holder"
check "休眠时断开了现有连接" grep -q closed "$work/holder.out"
check "休眠时 postgres 正常关闭" db_shut_down_cleanly
start=$(python3 -I -c 'import time; print(time.time())')
said="$(web_says "$web")"
echo "    唤醒到 web 回话 $(python3 -I -c "import time,sys; print(round(time.time()-float(sys.argv[1]),2))" "$start") 秒"
check "连接进来自动唤醒" test "$said" = "reused v2"
check "唤醒时没有重新执行 seed" test "$(sql "$db" 'select count(*) from seeded')" = "2"
"$napbox" status >/dev/null; (cd "$repo" && "$napbox" sleep >/dev/null)
check "psql 直接连休眠的环境也会唤醒" test "$(sql "$db" 'select count(*) from seeded')" = "2"

echo "env、logs、exec、reset"
nb() { (cd "$repo" && "$napbox" "$@"); }
code_of() { jq -r .error.code <<<"$1"; }
eval "$(nb env)"
check "napbox env 能直接 eval" test "${NAPBOX_WEB_8080:-}" = "127.0.0.1:$web" -a "${NAPBOX_DB_5432:-}" = "127.0.0.1:$db"
# seed 跑过两次（第一次 up、改了 compose 再 up），之后唤醒时跳过，只写了启动分隔行
check "logs --tail 1 只有最后一行" test "$(nb logs seed --tail 1 | grep -c '^----- napbox 启动')" = 1 -a "$(nb logs seed --tail 1 | wc -l | tr -d ' ')" = 1
check "logs --tail all 是整个文件" test "$(nb logs seed --tail all | grep -c '^INSERT 0 1')" = 2
check "logs 默认只给最后 200 行（probe 一启动就输出 300 行）" test "$(nb logs probe | wc -l | tr -d ' ')" = 200 -a "$(nb logs probe | tail -1)" = 300
check "logs --tail all 给全部" test "$(nb logs probe --tail all | grep -cx '[0-9]*')" -ge 300
# 只取标准错误：错误 JSON 要写在那里，不和日志内容混在一起
check "logs 不存在的服务报 service_not_found（写到标准错误）" test "$(code_of "$(nb logs nope 2>&1 >/dev/null)")" = service_not_found
nb sleep >/dev/null
out="$(nb exec db -- psql -U t -d t -Atc 'select count(*) from seeded')"
check "exec 在休眠的环境里先唤醒再执行" test "$out" = "2" -a "$(state_is running && echo yes)" = yes
nb exec probe -- sh -c 'echo out; echo err >&2; exit 7' >"$work/exec.out" 2>"$work/exec.err"; code=$?
check "exec 分开转回输出和错误输出，退出码原样" test "$(cat "$work/exec.out")" = out -a "$(cat "$work/exec.err")" = err -a "$code" = 7
check "exec 把标准输入转给命令" test "$(echo 'select 40 + 2' | nb exec db -- psql -U t -d t -At)" = 42
check "exec 这次没启动的一次性服务报 service_failed（写到标准错误）" test "$(code_of "$(nb exec seed -- true 2>&1 >/dev/null)")" = service_failed
check "exec 不存在的服务报 service_not_found（写到标准错误）" test "$(code_of "$(nb exec nope -- true 2>&1 >/dev/null)")" = service_not_found
# 命令行被结束（连接断开）时，容器里这条命令和它的子进程都要结束，不能留下孤儿
running_in_probe() { nb exec probe -- pgrep -f "sleep $1" >/dev/null 2>&1; }
gone_from_probe() { for _ in $(seq 1 25); do running_in_probe "$1" || return 0; sleep 0.2; done; return 1; }
gone_from_probe_marker() { for _ in $(seq 1 25); do nb exec probe -- pgrep -f "$1" >/dev/null 2>&1 || return 0; sleep 0.2; done; return 1; }
for sig in TERM KILL; do
    marker="77$(printf %02d "$(kill -l "$sig")").5"
    (cd "$repo" && exec "$napbox" exec probe -- sh -c "sleep $marker; echo done") >/dev/null 2>&1 &
    cli=$!
    for _ in $(seq 1 50); do running_in_probe "$marker" && break; sleep 0.2; done
    check "exec 命令跑起来了（SIG$sig 前）" running_in_probe "$marker"
    kill "-$sig" "$cli"
    wait "$cli" 2>/dev/null
    check "命令行被 SIG$sig 结束后，容器里的 sh 和子进程都结束了" gone_from_probe "$marker"
done
# 走命令行时输出经过同一个有上限的缓冲：读得慢时 napboxd 的内存不涨，内容不少。这里只在跑命令时看 napboxd 涨了多少
peak_growth() { # peak_growth <命令...>：涨了多少 KB 放进 growth
    local base sample peak p
    base="$(ps -o rss= -p "$daemon")"; peak="$base"
    "$@" & p=$!
    while kill -0 "$p" 2>/dev/null; do
        sample="$(ps -o rss= -p "$daemon")"
        [ "${sample:-0}" -gt "$peak" ] && peak="$sample"
        sleep 0.1
    done
    wait "$p"
    growth=$((peak - base))
}
slow_flood() { # 不停输出，读得慢，读 5 秒就关掉管道
    (cd "$repo" && exec "$napbox" exec probe -- yes cli-flood) 2>/dev/null | python3 -I -c '
import sys, time
end = time.time() + 5
while time.time() < end:
    sys.stdin.buffer.read(65536)
    time.sleep(0.01)
'
}
peak_growth slow_flood
echo "  命令行 yes 读得慢：napboxd 涨了 $((growth / 1024))MB"
check "exec 走命令行不停输出、读得慢：napboxd 内存不涨（不超过 64MB）" test "$growth" -le 65536
check "读的一方关掉管道后，容器里的命令结束了" gone_from_probe_marker cli-flood
slow_digest() { # 读得慢，输出字节数和摘要
    python3 -I -c '
import hashlib, sys, time
h = hashlib.sha256(); n = 0
while True:
    b = sys.stdin.buffer.read(65536)
    if not b: break
    h.update(b); n += len(b); time.sleep(0.002)
print(n, h.hexdigest())
'
}
seq_digest="$(python3 -I -c '
import hashlib
b = ("\n".join(str(i) for i in range(1, 3000001)) + "\n").encode()
print(len(b), hashlib.sha256(b).hexdigest())
')"
check "exec 走命令行约 23MB 输出、读得慢：一个字节不少" test "$(nb exec probe -- seq 1 3000000 | slow_digest)" = "$seq_digest"

echo "健康检查超时"
wh="$work/wt-health"
git -C "$repo" worktree add -q "$wh"
cat >"$wh/compose.yaml" <<'YAML'
services:
  checked:
    image: alpine:3.20
    command: ["sh", "-c", "sleep 4; touch /tmp/ok; exec sleep 100000"]
    # 前面几次都卡在子进程 sleep 上等到超时：/tmp/tried 证明确实超时过，不是一次就过
    healthcheck: {test: ["CMD-SHELL", "test -f /tmp/ok || { touch /tmp/tried; sleep 8881; echo late; }"], interval: 1s, timeout: 1s, retries: 10}
    stop_grace_period: 1s
YAML
whup="$(cd "$wh" && "$napbox" up)"
check "健康检查超时过几次后环境就绪" test "$(jq -r .state <<<"$whup")" = running
check "健康检查确实超时过" bash -c 'cd "$1" && "$2" exec checked -- test -f /tmp/tried' _ "$wh" "$napbox"
check "超时的健康检查连子进程一起结束，没有留下" bash -c 'cd "$1" && ! "$2" exec checked -- pgrep -f "sleep 8881" >/dev/null' _ "$wh" "$napbox"
(cd "$wh" && "$napbox" down >/dev/null)

reset="$(nb reset data)"
check "reset 后环境在运行" test "$(jq -r .state <<<"$reset")" = running
check "reset 后数据卷是空的，seed 重新跑过：只有一行" test "$(sql "$db" 'select count(*) from seeded')" = "1"
reset_kept() {
    local f; f="$(grep -l '"reason" : "napbox reset data"' "$NAPBOX_SUPPORT_DIR"/recycled/*/recycled.json | head -1)"
    test -n "$f" -a -f "$(dirname "$f")/volumes/data.ext4"
}
check "旧数据卷移到 recycled，记下原因" reset_kept
check "reset 不存在的数据卷报 volume_not_found" test "$(code_of "$(nb reset nope)")" = volume_not_found
# 和调用方的 create 不同（下面「休眠后再 create」）
nb sleep >/dev/null
check "休眠后显式 up 会重跑一次性服务" test "$(nb up | jq -r .state)" = running -a "$(sql "$db" 'select count(*) from seeded')" = "2"

echo "worktree 删掉后自动回收（和下面的闲置休眠一起等）"
git -C "$repo" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
wt="$work/wt-gone"
git -C "$repo" worktree add -q "$wt"
cat >"$wt/compose.yaml" <<'YAML'
services:
  app:
    image: alpine:3.20
    command: ["sh", "-c", "while true; do echo hi | nc -l -p 7000; done"]
    ports: ["7000"]
    stop_grace_period: 1s
YAML
wtup="$(cd "$wt" && "$napbox" up)"
check "worktree 里的环境起来了" test "$(jq -r '.name + " " + .state' <<<"$wtup")" = "demo/wt-gone running"
wtport=$(jq -r '.ports[0].hostPort' <<<"$wtup")
check "worktree 里的环境经端口代理回话（对照：下面查端口放开）" test "$(web_says "$wtport")" = "hi"
# 跟着它的日志：环境回收时 logs -f 结束，在标准错误说明原因。要等它连上、收到最后一行（启动分隔）再删
# worktree，否则 napboxd 处理请求时 worktree 已经不在了
(cd "$wt" && exec "$napbox" logs -f app --tail 1) >"$work/gone-follow.out" 2>"$work/gone-follow.err" &
gonefollower=$!
for _ in $(seq 1 50); do grep -q '^----- napbox 启动' "$work/gone-follow.out" && break; sleep 0.1; done
check "logs -f 连上了（对照：下面查结束）" grep -q '^----- napbox 启动' "$work/gone-follow.out"
git -C "$repo" worktree remove --force "$wt" # 有没提交的 compose.yaml，要 --force

echo "restart 和 logs -f（和下面的闲置休眠一起等）"
wr="$work/wt-restart"
git -C "$repo" worktree add -q "$wr"
cat >"$wr/compose.yaml" <<'YAML'
x-napbox: {idle_minutes: 1}
services:
  keeper:
    image: alpine:3.20
    command: ["sh", "-c", "echo start >> /data/starts; exec sleep 100000"]
    volumes: [data:/data]
    stop_grace_period: 1s
  # crash 就绪（进程在运行）以后、slow 还没健康时退出：每次都落在"别的服务还在启动"的那段里
  crash:
    image: alpine:3.20
    command: ["sh", "-c", "sleep 1; exit 3"]
    restart: on-failure:2
  slow:
    image: alpine:3.20
    command: ["sh", "-c", "sleep 3; touch /tmp/ok; exec sleep 100000"]
    healthcheck: {test: ["CMD", "test", "-f", "/tmp/ok"], interval: 1s, retries: 10}
    stop_grace_period: 1s
volumes:
  data:
YAML
wrup="$(cd "$wr" && "$napbox" up)"
check "restart 测试环境起来了" test "$(jq -r .state <<<"$wrup")" = running
# 从现在起跟着 keeper 的日志：整个环境每重启一次，日志里多一行启动分隔
(cd "$wr" && exec "$napbox" logs -f keeper --tail 0) >"$work/follow.out" 2>&1 &
follower=$!

echo "闲置休眠（闲置 1 分钟）"
write_compose v3 1
up="$(cd "$repo" && "$napbox" up)" || echo "$up"
check "唤醒时跳过的 seed 也能正常停下、下次照常挂载（up 成功）" test "$(jq -r .state <<<"$up")" = "running"
if state_is running; then
    for _ in $(seq 1 100); do state_is sleeping && break; sleep 1; done
    check "1 分钟没有数据往来后自动休眠" state_is sleeping
else
    check "1 分钟没有数据往来后自动休眠（up 没成功，没法测）" false
fi
# 这时 wt-restart 环境还在跑（bridge100 不拆）：环境的 MAC 不固定的话，宿主机的 ARP 缓存还指着旧虚拟机，
# 转发会连接超时（2026-11-07 实测）
check "闲置休眠后连接进来照样唤醒（另一个环境同时在跑）" test "$(web_says "$web")" = "reused v3"
wr_status() { "$napbox" status | jq -c "[.environments[] | select(.name == \"demo/wt-restart\")][0] | $1"; }
for _ in $(seq 1 30); do [ "$(wr_status '[.serviceExits[].restart]')" = '["restarting","restarting","gave_up"]' ] && break; sleep 1; done
check "on-failure:2：退出码 3 时两次整个环境重启，第三次不再重启" test "$(wr_status '[.serviceExits[] | .service + ":" + (.exitCode|tostring) + ":" + .restart]')" = '["crash:3:restarting","crash:3:restarting","crash:3:gave_up"]'
check "logs -f 跟到了两次重启的新日志" test "$(grep -c '^----- napbox 启动' "$work/follow.out")" = 2
# 最后一次重启（gave_up 之前那次）以后过了 80 秒：没人占着的话早就闲置休眠了（闲置 1 分钟，每 10 秒查一次）。
# 这之前不能 exec：exec 结束也算一次活动，闲置会从那时重新算
gaveup="$(wr_status '.serviceExits[-1].at' | tr -d '"')"
python3 -I -c 'import datetime,sys,time; t=datetime.datetime.fromisoformat(sys.argv[1].replace("Z","+00:00")).timestamp(); time.sleep(max(0, t + 80 - time.time()))' "$gaveup"
check "logs -f 跟着期间环境不闲置休眠" test "$(wr_status .state)" = '"running"'
check "整个环境重启了两次：keeper 一共启动 3 次（经 exec 查数据卷）" test "$(cd "$wr" && "$napbox" exec keeper -- wc -l /data/starts | awk '{print $1}')" = 3
kill "$follower" 2>/dev/null; wait "$follower" 2>/dev/null
(cd "$wr" && "$napbox" down >/dev/null)
git -C "$repo" worktree remove --force "$wr"
wt_registered() { test "$("$napbox" status | jq '[.environments[] | select(.name == "demo/wt-gone")] | length')" != 0; }
for _ in $(seq 1 40); do wt_registered || break; sleep 2; done
check "worktree 删掉后，在运行的环境被回收" test "$("$napbox" status | jq '[.environments[] | select(.name == "demo/wt-gone")] | length')" = 0
check "它的端口放开了" python3 -I -c 'import socket,sys; s=socket.socket(); sys.exit(0 if s.connect_ex(("127.0.0.1", int(sys.argv[1]))) != 0 else 1)' "$wtport"
check "数据移到 recycled，记下回收原因" grep -q '"reason" : "worktree 删掉了' "$NAPBOX_SUPPORT_DIR"/recycled/*/recycled.json
# 没回收的话 logs -f 不会自己结束，不能干等
wt_registered && kill "$gonefollower" 2>/dev/null
wait "$gonefollower"; code=$?
check "跟着日志的 logs -f 正常结束，标准错误说明环境回收了" test "$code" -eq 0 -a "$(cat "$work/gone-follow.err")" = "napbox logs 结束：环境 demo/wt-gone 回收了"
check "另一个环境不受影响" test "$("$napbox" status | jq -c '[.environments[].name]')" = '["demo/main"]'

echo "down"
down="$(cd "$repo" && "$napbox" down)"
check "释放三个端口" test "$(jq -r '.releasedPorts | length' <<<"$down")" = "3"
# 看还有没有程序在监听（不用试绑定：刚转发过的连接让端口处在 TIME_WAIT，不带 SO_REUSEADDR 会绑不上）
check "端口确实放开了" python3 -I -c 'import socket,sys; s=socket.socket(); sys.exit(0 if s.connect_ex(("127.0.0.1", int(sys.argv[1]))) != 0 else 1)' "$db"
check "数据移到 recycled" test -d "$(jq -r .keptDataAt <<<"$down")"
check ".napbox 目录删掉了" test ! -e "$repo/.napbox"
check "status 里没有环境了" test "$("$napbox" status | jq '.environments | length')" = "0"

echo "调用方持有的环境"
# 和 CodeOS 的 Goal 副本一样：git clone --no-local 出来的独立仓库，不是 worktree，工作副本和验收副本的目录都叫 repo
git clone -q --no-local "$repo" "$work/goal/work/repo"
git clone -q --no-local "$repo" "$work/goal/acceptance/repo"
copy="$(cd "$work/goal/work/repo" && pwd -P)"
accept="$(cd "$work/goal/acceptance/repo" && pwd -P)"
write_copy_compose() {
    cat >"$1/compose.yaml" <<'YAML'
services:
  # 一次性服务：唤醒时跳过
  init:
    image: alpine:3.20
    command: ["sh", "-c", "echo done"]
  # 按端口判断就绪；回话的内容来自调用方给的变量
  web:
    image: alpine:3.20
    environment: {MSG: "${GREETING}"}
    command: ["sh", "-c", "while true; do echo \"$$MSG\" | nc -l -p 8080; done"]
    ports: ["8080"]
    stop_grace_period: 1s
  # 按 healthcheck 判断就绪
  ready:
    image: alpine:3.20
    command: ["sh", "-c", "touch /tmp/ok; exec sleep 100000"]
    healthcheck: {test: ["CMD", "test", "-f", "/tmp/ok"], interval: 1s, retries: 10}
    stop_grace_period: 1s
  # /tmp/die 出现后退出，测运行中服务退出的事件
  crasher:
    image: alpine:3.20
    command: ["sh", "-c", "while [ ! -f /tmp/die ]; do sleep 0.2; done; exit 4"]
    stop_grace_period: 1s
YAML
}
write_copy_compose "$copy"; write_copy_compose "$accept"
# rpc 的 params：create <名字> <目录> [多余的字段（JSON）]
create_params() {
    local extra="${3:-}"; [ -n "$extra" ] || extra='{}'
    jq -nc --arg name "$1" --arg dir "$2" --argjson extra "$extra" '{name: $name, owner: "codeos", directory: $dir, files: [], profiles: [], environment: {GREETING: "hello"}} + $extra'
}
work_target='{"target":{"name":"codeos/goal-1-work","owner":"codeos"}}'
accept_target='{"target":{"name":"codeos/goal-1-acceptance","owner":"codeos"}}'
subscribe_to "$work/events.out" '{"owner":"codeos"}'
check "订阅事件生效" test "$?" -eq 0
sub=$subscriber
created="$(rpc create "$(create_params codeos/goal-1-work "$copy" '{"egress":"none"}')")"
check "create 起来了，持有方和出网模式对" test "$(jq -r '.result | "\(.name) \(.owner) \(.state) \(.egress)"' <<<"$created")" = "codeos/goal-1-work codeos running none"
workport=$(jq -r '.result.ports[] | select(.service == "web") | .hostPort' <<<"$created")
check "返回端口和环境变量" test "$(jq -r '.result.variables.NAPBOX_WEB_8080' <<<"$created")" = "127.0.0.1:$workport"
check "调用方给的变量进了 compose" test "$(web_says "$workport")" = hello
check "代码副本里不写 .napbox" test ! -e "$copy/.napbox"
check "代码副本的 .git/info/exclude 不动" sh -c "! grep -qx '.napbox/' '$copy/.git/info/exclude'"
acreated="$(rpc create "$(create_params codeos/goal-1-acceptance "$accept")")"
check "目录同样叫 repo 的另一份副本也能建，不撞名" test "$(jq -r '.result | "\(.name) \(.state) \(.egress)"' <<<"$acreated")" = "codeos/goal-1-acceptance running open"
aport=$(jq -r '.result.ports[] | select(.service == "web") | .hostPort' <<<"$acreated")
check "两份副本的端口不同" test "$aport" != "$workport"
check "副本里 napbox up 被拒绝" test "$(cd "$copy" && "$napbox" up | jq -r .error.code)" = owner_mismatch
runs_of() { rpc runs "$1" | jq -c "$2"; }
check "定义没变再 create：不重启（运行记录还是一条），端口不变" test "$(rpc create "$(create_params codeos/goal-1-work "$copy")" | jq -r '.result.ports[] | select(.service == "web") | .hostPort')" = "$workport" -a "$(runs_of "$work_target" '.result.runs | length')" = 1
check "再 create 时换出网模式：只换规则，不重启" test "$(rpc create "$(create_params codeos/goal-1-work "$copy" '{"egress":"open"}')" | jq -r '.result.egress')" = open -a "$(runs_of "$work_target" '.result.runs | length')" = 1
check "按名字切出网模式" test "$(rpc egress "$(jq -nc --argjson t "$work_target" '$t + {mode: "none"}')" | jq -r .result.egress)" = none
check "按名字休眠" test "$(rpc sleep "$work_target" | jq -r .result.state)" = sleeping
check "按名字唤醒，等就绪后返回" test "$(rpc wake "$work_target" | jq -r .result.state)" = running
check "休眠再唤醒后 egress 还是 none" test "$(rpc environment "$work_target" | jq -r .result.egress)" = none
check "按名字 exec：退出码原样" test "$(rpc exec "$(jq -nc --argjson t "$work_target" '$t + {service: "web", command: ["sh", "-c", "exit 5"]}')" | jq -r .result.exitCode)" = 5
check "按名字 exec，持有方不对被拒绝" test "$(rpc exec '{"target":{"name":"codeos/goal-1-work","owner":"other"},"service":"web","command":["true"]}' | jq -r .error.code)" = owner_mismatch

echo "运行记录"
runs="$(rpc runs "$work_target")"
service_of() { jq -c ".result.runs[$1].services[] | select(.service == \"$2\")" <<<"$runs"; }
check "两条记录：up 和唤醒，都成功" test "$(jq -c '[.result.runs[] | [.purpose, .error]]' <<<"$runs")" = '[["up",null],["wake",null]]'
check "记下定义摘要，唤醒沿用同一份" test "$(jq -r '.result.runs[0].definitionDigest' <<<"$runs" | cut -c1-7)" = "sha256:" -a "$(jq -r '.result.runs[0].definitionDigest' <<<"$runs")" = "$(jq -r '.result.runs[1].definitionDigest' <<<"$runs")"
check "记下这次的出网模式" test "$(jq -c '[.result.runs[].egress]' <<<"$runs")" = '["none","none"]'
check "记下分配到的端口" test "$(jq -r '.result.runs[0].ports[] | select(.service == "web") | .hostPort' <<<"$runs")" = "$workport"
check "记下镜像和 digest" test "$(service_of 0 web | jq -r '.image + " " + (.digest | .[0:7]) + " " + (.platformDigest | .[0:7])')" = "docker.io/library/alpine:3.20 sha256: sha256:"
check "按 healthcheck 判断就绪" test "$(service_of 0 ready | jq -r .readiness)" = healthcheck
check "按端口判断就绪" test "$(service_of 0 web | jq -r .readiness)" = port
check "没有端口和 healthcheck 的按进程判断" test "$(service_of 0 crasher | jq -r .readiness)" = process
check "记下启动和就绪的时间，就绪不早于启动" test "$(service_of 0 ready | jq -r '.startedAt <= .readyAt')" = true
check "唤醒时一次性服务跳过，没有启动时间" test "$(service_of 1 init | jq -r '"\(.skipped) \(.startedAt)"')" = "true null"
# 起不来的环境：运行记录和事件都要记下
mkdir -p "$work/goal/bad/repo"; bad="$(cd "$work/goal/bad/repo" && pwd -P)"
cat >"$bad/compose.yaml" <<'YAML'
services:
  sick:
    image: alpine:3.20
    command: ["sleep", "100000"]
    healthcheck: {test: ["CMD", "false"], interval: 1s, retries: 2}
    stop_grace_period: 1s
YAML
bad_target='{"target":{"name":"codeos/goal-2-bad","owner":"codeos"}}'
check "healthcheck 没通过：create 报 healthcheck_timeout" test "$(rpc create "$(jq -nc --arg dir "$bad" '{name: "codeos/goal-2-bad", owner: "codeos", directory: $dir, files: [], profiles: [], environment: {}}')" | jq -r .error.code)" = healthcheck_timeout
check "失败的那次也有运行记录，带原因和走到的部分" test "$(rpc runs "$bad_target" | jq -r '.result.runs[0] | "\(.error.code) \(.services[0].service) \(.services[0].startedAt != null) \(.services[0].readyAt)"')" = "healthcheck_timeout sick true null"
check "明确唤醒不看冷却，马上再试一次（第二条记录）" test "$(rpc wake "$bad_target" | jq -r .error.code)" = healthcheck_timeout -a "$(rpc runs "$bad_target" | jq -c '[.result.runs[].purpose]')" = '["up","wake"]'
check "销毁起不来的环境" test "$(rpc down "$bad_target" | jq -r .result.name)" = codeos/goal-2-bad

echo "休眠后再 create、起环境之前就失败"
# 用验收副本，不影响下面按顺序检查的工作副本事件
check "休眠验收副本" test "$(rpc sleep "$accept_target" | jq -r .result.state)" = sleeping
rewoken="$(rpc create "$(create_params codeos/goal-1-acceptance "$accept" '{"egress":"none"}')")"
check "休眠后定义没变再 create：起来了，换了出网模式，端口不变" test "$(jq -r --argjson p "$aport" '.result | "\(.state) \(.egress) \(.ports[] | select(.service == "web") | .hostPort == $p)"' <<<"$rewoken")" = "running none true"
last_run() { rpc runs "$accept_target" | jq -c ".result.runs[-1] | $1"; }
check "按唤醒处理：运行记录是 wake，这次的出网模式是 none" test "$(last_run '[.purpose, .egress, .error]')" = '["wake","none",null]'
check "一次性服务没有重跑" test "$(last_run '.services[] | select(.service == "init") | [.skipped, .startedAt]')" = '[true,null]'
digest_before="$(last_run .definitionDigest)"
# 定义变了要重启，但镜像那步就失败（本地没有，又不许拉）：准备好了才停旧环境，所以它还在跑
{ cat "$accept/compose.yaml"; printf '  missing:\n    image: napbox-test/not-here:1\n    pull_policy: never\n'; } >"$accept/compose.next"; mv "$accept/compose.next" "$accept/compose.yaml"
check "定义变了但准备失败：create 报错" test "$(rpc create "$(create_params codeos/goal-1-acceptance "$accept")" | jq -r .error.code)" = image_unavailable
start_failed() { jq -c 'select(.event.environment == "codeos/goal-1-acceptance" and .event.type == "start_failed") | .event' "$work/events.out"; }
for _ in $(seq 1 50); do [ -n "$(start_failed)" ] && break; sleep 0.1; done
check "准备失败也发 start_failed，runId 对得上运行记录" test "$(start_failed | jq -r '"\(.purpose) \(.error.code) \(.runId)"')" = "up image_unavailable $(last_run .id | jq -r .)"
check "准备失败也留运行记录：带错误和这次要跑的定义，没有走到任何服务" test "$(last_run '[.purpose, .error.code, (.definitionDigest != '"$digest_before"'), (.services | length)]')" = '["up","image_unavailable",true,0]'
check "旧环境还在跑、还能连" test "$(rpc environment "$accept_target" | jq -r .result.state)" = running -a "$(web_says "$aport")" = hello
check "lastError 记下这次失败的原因" test "$(rpc environment "$accept_target" | jq -r '.result.lastError // "" | contains("not-here")')" = true
runs_count="$(runs_of "$accept_target" '.result.runs | length')"
write_copy_compose "$accept"
restored="$(rpc create "$(create_params codeos/goal-1-acceptance "$accept")")"
check "登记的定义没变：改回原来的 compose 再 create 不重启" test "$(jq -r .result.state <<<"$restored")" = running -a "$(runs_of "$accept_target" '.result.runs | length')" = "$runs_count"
check "确认环境正常后 lastError 清掉了" test "$(jq -r .result.lastError <<<"$restored")" = null -a "$(rpc environment "$accept_target" | jq -r .result.lastError)" = null
# 准备成功了才停旧环境，但新环境起不来：旧环境跑完的一次性服务不能留在登记里，不然之后唤醒会错误地跳过
completed_of_accept() { jq -c '.environments[] | select(.name == "codeos/goal-1-acceptance") | .completedServices' "$NAPBOX_SUPPORT_DIR/state.json"; }
check "（前提）登记里有旧环境跑完的 init" test "$(completed_of_accept)" = '["init"]'
cp "$accept/compose.yaml" "$work/accept-compose.good"
{ cat "$accept/compose.yaml"; printf '  sick:\n    image: alpine:3.20\n    command: ["sleep", "100000"]\n    healthcheck: {test: ["CMD", "false"], interval: 1s, retries: 2}\n    stop_grace_period: 1s\n'; } >"$accept/compose.next"; mv "$accept/compose.next" "$accept/compose.yaml"
check "定义变了、新环境起不来：create 报 healthcheck_timeout" test "$(rpc create "$(create_params codeos/goal-1-acceptance "$accept")" | jq -r .error.code)" = healthcheck_timeout
check "这时环境停了" test "$(rpc environment "$accept_target" | jq -r .result.state)" = sleeping
check "登记里不留旧环境跑完的一次性服务" test "$(completed_of_accept)" = '[]'
cp "$work/accept-compose.good" "$accept/compose.yaml"
check "改回去再 create：定义又变了，重新起来，一次性服务重跑" test "$(rpc create "$(create_params codeos/goal-1-acceptance "$accept")" | jq -r .result.state)" = running -a "$(last_run '[.purpose, (.services[] | select(.service == "init") | .skipped)]')" = '["up",false]'

echo "同时创建两个新环境、写了 build 的新环境"
for side in a b; do
    mkdir -p "$work/race/$side/repo"
    cat >"$work/race/$side/repo/compose.yaml" <<'YAML'
services:
  web:
    image: alpine:3.20
    environment: {MSG: "${GREETING}"}
    command: ["sh", "-c", "while true; do echo \"$$MSG\" | nc -l -p 8080; done"]
    ports: ["8080"]
    stop_grace_period: 1s
YAML
done
race_dir() { (cd "$work/race/$1/repo" && pwd -P); }
# 名字不同就不在同一个队列里，会一起走到分配地址（修之前 5 轮全部分到同一个 IP）
rpc create "$(create_params race/a "$(race_dir a)" '{"owner":"race"}')" >"$work/race/a.out" & race_a=$!
rpc create "$(create_params race/b "$(race_dir b)" '{"owner":"race"}')" >"$work/race/b.out" & race_b=$!
wait "$race_a" "$race_b"
race_ip() { jq -r ".environments[] | select(.name == \"race/$1\") | .ip" "$NAPBOX_SUPPORT_DIR/state.json"; }
race_port() { jq -r '.result.ports[0].hostPort' "$work/race/$1.out"; }
check "同时创建：两个都起来了" test "$(jq -r .result.state "$work/race/a.out") $(jq -r .result.state "$work/race/b.out")" = "running running"
check "同时创建：IP 不同" test -n "$(race_ip a)" -a "$(race_ip a)" != "$(race_ip b)"
check "同时创建：端口不同" test "$(race_port a)" != "$(race_port b)"
check "同时创建：两个都能连" test "$(web_says "$(race_port a)") $(web_says "$(race_port b)")" = "hello hello"
for side in a b; do rpc down "{\"target\":{\"name\":\"race/$side\",\"owner\":\"race\"}}" >/dev/null; done
mkdir -p "$work/race/built/repo"; printf 'services:\n  app:\n    build: .\n' >"$work/race/built/repo/compose.yaml"
built="$(rpc create "$(create_params race/built "$(race_dir built)" '{"owner":"race"}')")"
check "写了 build 但没有 Dockerfile：报 image_build_failed，说清是哪个文件" test "$(jq -r .error.code <<<"$built")" = image_build_failed -a "$(jq -r '.error.message | contains("Dockerfile") and contains("不存在")' <<<"$built")" = true
check "没起来的新环境不留登记" test "$("$napbox" status | jq -r '[.environments[].name] | index("race/built")')" = null

echo "restart: always 的服务以退出码 0 退出"
mkdir -p "$work/race/always/repo"
cat >"$work/race/always/repo/compose.yaml" <<'YAML'
services:
  # 每次启动往卷里记一行，然后以退出码 0 退出：always 要再起，不算跑完
  job:
    image: alpine:3.20
    command: ["sh", "-c", "echo run >> /data/runs; sleep 2; exit 0"]
    restart: always
    volumes: ["data:/data"]
    stop_grace_period: 1s
  # 对照：on-failure 以退出码 0 退出不重启，算跑完
  once:
    image: alpine:3.20
    command: ["true"]
    restart: on-failure
  keeper:
    image: alpine:3.20
    command: ["sleep", "100000"]
    volumes: ["data:/data"]
    stop_grace_period: 1s
volumes:
  data: {}
YAML
always_target='{"target":{"name":"race/always","owner":"race"}}'
check "always 的环境起来了" test "$(rpc create "$(create_params race/always "$(race_dir always)" '{"owner":"race"}')" | jq -r .result.state)" = running
# 用 exec 的退出码读行数（rpc 只看结果那一行）。环境可能正在重启，读不到时算 0
job_runs() { rpc exec "$(jq -nc --argjson t "$always_target" '$t + {service: "keeper", command: ["sh", "-c", "exit $(wc -l < /data/runs)"]}')" | jq -r '.result.exitCode // 0'; }
for _ in $(seq 1 80); do [ "$(job_runs)" -ge 3 ] && break; sleep 0.5; done
check "退出码 0 退出后真的再跑（至少跑了 3 次）" test "$(job_runs)" -ge 3
restart_run() { rpc runs "$always_target" | jq -c "[.result.runs[] | select(.purpose == \"$1\")][-1].services[] | select(.service == \"$2\") | .skipped"; }
check "重启时 always 的服务没有跳过" test "$(restart_run restart job)" = false
check "重启时 on-failure 退出码 0 的服务跳过" test "$(restart_run restart once)" = true
rpc sleep "$always_target" >/dev/null
check "休眠时登记里只算真正跑完的" test "$(jq -c '.environments[] | select(.name == "race/always") | .completedServices' "$NAPBOX_SUPPORT_DIR/state.json")" = '["once"]'
check "休眠后唤醒" test "$(rpc wake "$always_target" | jq -r .result.state)" = running
check "唤醒时 always 的服务也不跳过" test "$(restart_run wake job)" = false
rpc down "$always_target" >/dev/null

echo "事件"
rpc exec "$(jq -nc --argjson t "$work_target" '$t + {service: "crasher", command: ["touch", "/tmp/die"]}')" >/dev/null
crasher_exited() { test -n "$(jq -c 'select(.event.environment == "codeos/goal-1-work" and .event.service == "crasher")' "$work/events.out")"; }
for _ in $(seq 1 50); do crasher_exited && break; sleep 0.2; done
check "按名字销毁，持有方不对被拒绝" test "$(rpc down '{"target":{"name":"codeos/goal-1-work","owner":"other"}}' | jq -r .error.code)" = owner_mismatch
wdown="$(rpc down "$work_target")"
check "按名字销毁，释放端口" test "$(jq -r '.result.releasedPorts | index('"$workport"') != null' <<<"$wdown")" = true
check "运行记录随数据移到 recycled" test -f "$(jq -r .result.keptDataAt <<<"$wdown")/runs.json"
work_destroyed() { test -n "$(jq -c 'select(.event.environment == "codeos/goal-1-work" and .event.type == "destroyed")' "$work/events.out")"; }
for _ in $(seq 1 50); do work_destroyed && break; sleep 0.1; done
events_of() { jq -c "select(.event.environment == \"$1\") | .event | [.type, (.purpose // .sleepReason // .service // .reason)] + (if .exitCode != null then [.exitCode, .restart] else [] end)" "$work/events.out" | paste -sd, -; }
check "事件的顺序和内容（起好、一次性服务退出、休眠、唤醒、服务退出、销毁）" test "$(events_of codeos/goal-1-work)" = '["started","up"],["service_exited","init",0,"none"],["slept","request"],["started","wake"],["service_exited","crasher",4,"none"],["destroyed","codeos 销毁"]'
check "started 带运行记录的 id，对得上" test "$(jq -r 'select(.event.environment == "codeos/goal-1-work" and .event.type == "started") | .event.runId' "$work/events.out" | head -1)" = "$(jq -r '.result.runs[0].id' <<<"$runs")"
check "起不来时发 start_failed，带 healthcheck 的错误码" test "$(jq -r 'select(.event.environment == "codeos/goal-2-bad" and .event.type == "start_failed") | .event.error.code' "$work/events.out" | head -1)" = healthcheck_timeout
check "另一份副本不受影响" test "$(rpc environment "$accept_target" | jq -r .result.state)" = running
check "销毁另一份" test "$(rpc down "$accept_target" | jq -r .result.name)" = codeos/goal-1-acceptance
kill "$sub" 2>/dev/null; wait "$sub" 2>/dev/null

echo "登记的端口被别的程序占了"
mkdir -p "$work/race/port/repo"
write_port_compose() {
    cat >"$work/race/port/repo/compose.yaml" <<'YAML'
services:
  web:
    image: alpine:3.20
    environment: {MSG: "${GREETING}"}
    command: ["sh", "-c", "while true; do echo \"$$MSG\" | nc -l -p 8080; done"]
    ports: ["8080"]
    stop_grace_period: 1s
YAML
}
write_port_compose
port_target='{"target":{"name":"race/port","owner":"race"}}'
port_create() { rpc create "$(create_params race/port "$(race_dir port)" '{"owner":"race"}')"; }
held="$(jq -r '.result.ports[0].hostPort' <<<"$(port_create)")"
stop_daemon
python3 -I -c '
import socket, sys
s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("127.0.0.1", int(sys.argv[1]))); s.listen(8)
while True:
    c, _ = s.accept(); c.sendall(b"intruder\n"); c.close()
' "$held" &
occupant=$!
for _ in $(seq 1 50); do [ "$(web_says "$held")" = intruder ] && break; sleep 0.1; done
start_daemon
subscribe_to "$work/events-port.out" '{"owner":"race"}'; port_sub=$subscriber
check "休眠的环境 create：报 port_unavailable，不起环境" test "$(port_create | jq -r .error.code)" = port_unavailable -a "$(rpc environment "$port_target" | jq -r .result.state)" = sleeping
check "明确 wake 也报 port_unavailable" test "$(rpc wake "$port_target" | jq -r .error.code)" = port_unavailable
check "留运行记录：wake，带错误，没有走到任何服务" test "$(rpc runs "$port_target" | jq -c '.result.runs[-1] | [.purpose, .error.code, (.services | length)]')" = '["wake","port_unavailable",0]'
for _ in $(seq 1 50); do grep -q start_failed "$work/events-port.out" && break; sleep 0.1; done
check "发 start_failed" test "$(jq -r 'select(.event.type == "start_failed") | .event.error.code' "$work/events-port.out" | head -1)" = port_unavailable
check "连这个端口到的是占用方，不是环境" test "$(web_says "$held")" = intruder
kill "$occupant" 2>/dev/null; wait "$occupant" 2>/dev/null
kill "$port_sub" 2>/dev/null; wait "$port_sub" 2>/dev/null
recovered="$(port_create)"
check "占用方走了再 create：起来了，错误清掉" test "$(jq -r '"\(.result.state) \(.result.lastError)"' <<<"$recovered")" = "running null"
check "端口恢复监听，连到环境" test "$(web_says "$held")" = hello

echo "napboxd 退出"
term_daemon() { # 发 SIGTERM，等它退出，用时放进 elapsed；30 秒还没退就强制结束
    local begun; begun=$(date +%s)
    kill -TERM "$daemon"
    for _ in $(seq 1 60); do kill -0 "$daemon" 2>/dev/null || break; sleep 0.5; done
    elapsed=$(($(date +%s) - begun))
    kill -KILL "$daemon" 2>/dev/null
    wait "$daemon" 2>/dev/null; daemon=""
}
for side in stop-a stop-b; do
    mkdir -p "$work/race/$side/repo"
    cat >"$work/race/$side/repo/compose.yaml" <<'YAML'
services:
  # 不理 SIGTERM，要等满 stop_grace_period 才被强制结束
  stubborn:
    image: alpine:3.20
    command: ["sh", "-c", "trap '' TERM; while :; do sleep 1; done"]
    stop_grace_period: 6s
YAML
    rpc create "$(create_params "race/$side" "$(race_dir "$side")" '{"owner":"race"}')" >/dev/null
done
term_daemon
check "各环境同时停：两个各等 6 秒的环境，总共不到 11 秒（用了 ${elapsed} 秒）" test "$elapsed" -lt 11
start_daemon
for side in stop-a stop-b; do rpc down "{\"target\":{\"name\":\"race/$side\",\"owner\":\"race\"}}" >/dev/null; done
# 假的镜像仓库：接受连接但不回应，拉镜像一直卡着。不联网，也不往镜像库里放东西
python3 -I -c '
import socket, sys
s = socket.socket(); s.bind(("127.0.0.1", 0)); s.listen(16)
open(sys.argv[1], "w").write(str(s.getsockname()[1]))
held = []
while True:
    c, _ = s.accept(); held.append(c)
    open(sys.argv[2], "a").write("hit\n")
' "$work/race/registry.port" "$work/race/registry.hits" &
registry=$!
for _ in $(seq 1 50); do [ -s "$work/race/registry.port" ] && break; sleep 0.1; done
check "（前提）环境在跑" test "$(port_create | jq -r .result.state)" = running
digest_before="$(rpc runs "$port_target" | jq -r '.result.runs[-1].definitionDigest')"
printf '  pending:\n    image: 127.0.0.1:%s/napbox-test/hang:1\n' "$(cat "$work/race/registry.port")" >>"$work/race/port/repo/compose.yaml"
port_create >/dev/null 2>&1 & pending=$!
for _ in $(seq 1 100); do [ -s "$work/race/registry.hits" ] && break; sleep 0.1; done
check "（前提）拉镜像卡住了" test -s "$work/race/registry.hits" -a "$(kill -0 "$pending" 2>/dev/null && echo alive)" = alive
check "拉镜像期间旧环境还能连" test "$(web_says "$held")" = hello
term_daemon
check "退出不等卡住的拉镜像（用了 ${elapsed} 秒）" test "$elapsed" -lt 15
wait "$pending" 2>/dev/null
kill "$registry" 2>/dev/null; wait "$registry" 2>/dev/null
start_daemon
write_port_compose
check "登记的定义没变：改回去再 create 按唤醒起来" test "$(port_create | jq -r .result.state)" = running -a "$(rpc runs "$port_target" | jq -c '.result.runs[-1] | [.purpose, .definitionDigest == "'"$digest_before"'"]')" = '["wake",true]'
check "销毁" test "$(rpc down "$port_target" | jq -r .result.name)" = race/port

echo "napboxd 被强杀"
# 虚拟机随 napboxd 一起没了，来不及把内存里的内容写回磁盘。磁盘没开日志时，跑 25 秒以内被强杀的环境
# 2026-11-08 实测 12 轮全部起不来（根文件系统不一致，写 resolv.conf 失败），重试也不恢复；所以这里跑 8 秒就杀
mkdir -p "$work/race/crash/repo"
cat >"$work/race/crash/repo/compose.yaml" <<'YAML'
services:
  crashy:
    image: alpine:3.20
    volumes: ["crash-data:/data"]
    # 不停地在根文件系统和数据卷上建文件、删文件，不主动写回磁盘
    command: ["sh", "-c", "i=0; while true; do i=$$((i+1)); echo $$i >/tmp/f$$((i%50)); rm -f /tmp/f$$(((i+25)%50)); echo $$i >/data/f$$((i%50)); rm -f /data/f$$(((i+25)%50)); sleep 0.02; done"]
    stop_grace_period: 1s
volumes:
  crash-data:
YAML
crash_target='{"target":{"name":"race/crash","owner":"race"}}'
crash_create() { rpc create "$(create_params race/crash "$(race_dir crash)" '{"owner":"race"}')" | jq -r '.result.state // .error.message'; }
# 环境的每块磁盘（根文件系统、数据卷）的超级块，输出“名字 有没有日志 错误数”
crash_disks() {
    local dir; dir="$(dirname "$(dirname "$(find "$NAPBOX_SUPPORT_DIR/environments" -name crashy.ext4)")")"
    python3 -I -c '
import struct, sys
for path in sys.argv[1:]:
    with open(path, "rb") as f:
        f.seek(1024); block = f.read(1024)
    compat = struct.unpack_from("<I", block, 0x5c)[0]
    errors = struct.unpack_from("<I", block, 0x194)[0]
    print(path.split("/")[-1], "journal" if compat & 4 else "no-journal", errors)
' "$dir"/rootfs/*.ext4 "$dir"/volumes/*.ext4
}
crash_write() { # 在这个目录里建 300 个新文件，碰到磁盘不一致时会失败
    rpc exec "$(jq -nc --argjson t "$crash_target" --arg d "$1" '$t + {service: "crashy", command: ["sh", "-c", ("for i in $(seq 1 300); do echo x >" + $d + "/new$$_$i || exit 7; done")]}')" | jq -r '.result.exitCode // "error"'
}
check "环境起来了" test "$(crash_create)" = running
check "每块磁盘都开了日志（根文件系统、网络小容器、启动容器用的那块、数据卷）" test "$(crash_disks | awk '$2 == "journal" {n++} END {print n+0}')" = 4
for round in 1 2 3; do
    sleep 8
    kill -KILL "$daemon"; wait "$daemon" 2>/dev/null; daemon=""
    start_daemon
    woke="$(crash_create)"
    check "第 $round 轮：强杀后马上再 create，起来了（$woke）" test "$woke" = running
done
check "磁盘都没有记下错误" test "$(crash_disks | awk '$3 != 0 {n++} END {print n+0}')" = 0
check "根文件系统能写新文件" test "$(crash_write /tmp)" = 0
check "数据卷能写新文件" test "$(crash_write /data)" = 0
check "销毁" test "$(rpc down "$crash_target" | jq -r .result.name)" = race/crash

echo "刚建好的数据库被强杀"
# postgres 的入口脚本建好数据库后往 pg_hba.conf 追加放行外部连接的一行，不要求存盘。虚拟机里的内容最多 30 秒才写回，
# 不在就绪时存一次盘的话，这时被强杀这一行就丢了，宿主机再也连不上，健康检查还是通过
mkdir -p "$work/race/freshdb/repo"
cat >"$work/race/freshdb/repo/compose.yaml" <<'YAML'
services:
  db:
    image: postgres:17-alpine
    environment: {POSTGRES_USER: t, POSTGRES_PASSWORD: t, POSTGRES_DB: t}
    ports: ["5432"]
    volumes: [data:/var/lib/postgresql/data]
    healthcheck: {test: ["CMD", "pg_isready", "-U", "t"], interval: 1s, retries: 30}
    stop_grace_period: 1s
volumes:
  data:
YAML
freshdb_target='{"target":{"name":"race/freshdb","owner":"race"}}'
freshdb_create() { rpc create "$(create_params race/freshdb "$(race_dir freshdb)" '{"owner":"race"}')"; }
for round in 1 2; do
    freshdb="$(freshdb_create)"
    freshdb_port="$(jq -r '.result.ports[0].hostPort' <<<"$freshdb")"
    check "第 $round 轮：刚建好，宿主机连得上" test "$(sql "$freshdb_port" 'select 1')" = 1
    sleep 3
    kill -KILL "$daemon"; wait "$daemon" 2>/dev/null; daemon=""
    start_daemon
    check "第 $round 轮：强杀后再 create，起来了" test "$(freshdb_create | jq -r '.result.state // .error.message')" = running
    check "第 $round 轮：强杀后宿主机还连得上" test "$(sql "$freshdb_port" 'select 1')" = 1
    check "第 $round 轮：销毁" test "$(rpc down "$freshdb_target" | jq -r .result.name)" = race/freshdb
done
check "都销毁后 status 里没有环境了" test "$("$napbox" status | jq '.environments | length')" = "0"

echo "虚拟机意外没了"
# 用命令行、真实 postgres 走一遍：杀掉虚拟机进程后状态对得上，napbox up 能恢复，已提交的数据都在，自动唤醒不重跑一次性服务。
# 同名的还有 Docker 的虚拟化进程，绝不能碰：只杀打开了这份临时目录里文件的那一个，认不出来就不动手
own_vm() {
    local pid mine=() real_work
    real_work="$(cd "$work" && pwd -P)"
    for pid in $(pgrep -f com.apple.Virtualization.VirtualMachine); do
        lsof -p "$pid" 2>/dev/null | grep -qF "$real_work" && mine+=("$pid")
    done
    [ "${#mine[@]}" -eq 1 ] && echo "${mine[0]}"
}
kill_own_vm() { local pid; pid="$(own_vm)" && kill -KILL "$pid"; }
lost_state() { "$napbox" status | jq -r '.environments[0].state'; }
became_sleeping() { for _ in $(seq 1 30); do [ "$(lost_state)" = sleeping ] && return 0; sleep 0.1; done; return 1; }
lost_repo="$work/vm-lost"
mkdir -p "$lost_repo"
git init -q "$lost_repo"
cat >"$lost_repo/compose.yaml" <<'YAML'
services:
  db:
    image: postgres:17-alpine
    environment: {POSTGRES_USER: t, POSTGRES_PASSWORD: t, POSTGRES_DB: t}
    ports: ["5432"]
    volumes: [data:/var/lib/postgresql/data]
    healthcheck: {test: ["CMD", "pg_isready", "-U", "t"], interval: 1s, retries: 30}
    stop_grace_period: 1s
  seed:
    image: postgres:17-alpine
    environment: {PGPASSWORD: t}
    depends_on: {db: {condition: service_healthy}}
    command: ["psql", "-h", "db", "-U", "t", "-d", "t", "-c", "create table if not exists seeds(n int); insert into seeds values (1)"]
volumes:
  data:
YAML
lost_up() { (cd "$lost_repo" && "$napbox" up); }
lost_port="$(lost_up | jq -r '.ports[0].hostPort')"
check "起来了" test "$(lost_state)" = running
sql "$lost_port" 'create table kept(n int); insert into kept select generate_series(1, 1000)' >/dev/null
for _ in $(seq 1 50); do [ "$(sql "$lost_port" 'select count(*) from seeds' 2>/dev/null)" = 1 ] && break; sleep 0.2; done
check "一次性服务跑完了" test "$(sql "$lost_port" 'select count(*) from seeds')" = 1
kill_own_vm
check "虚拟机被杀后 3 秒内状态变成休眠" became_sleeping
check "status 里写了原因" sh -c '"$0" status | jq -r ".environments[0].lastError" | grep -q 虚拟机' "$napbox"
check "napbox up 能恢复" test "$(lost_up | jq -r '.state')" = running
check "已提交的数据都在" test "$(sql "$lost_port" 'select count(*) from kept')" = 1000
check "显式 up 和平时一样重跑一次性服务" test "$(sql "$lost_port" 'select count(*) from seeds')" = 2
kill_own_vm
check "再次被杀，又变成休眠" became_sleeping
sleep 11 # 过了冷却期
check "没人用就一直休眠" test "$(lost_state)" = sleeping
check "连接进来自动唤醒，数据都在" test "$(sql "$lost_port" 'select count(*) from kept')" = 1000
check "自动唤醒不重跑跑完的一次性服务" test "$(sql "$lost_port" 'select count(*) from seeds')" = 2
check "销毁" sh -c 'cd "$0" && "$1" down >/dev/null' "$lost_repo" "$napbox"

finish
