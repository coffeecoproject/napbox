#!/bin/bash
# 原生部分的测试：先跑单元测试（swift test），再跑 napboxd 和命令行的集成测试。
# 集成测试在临时目录里起独立的 napboxd（NAPBOX_SUPPORT_DIR），不碰正在用的那份。
# 用法：scripts/test-native.sh（会先编译 debug 版）
set -uo pipefail
source "$(dirname "$0")/lib.sh"
echo "单元测试"
# 按 swift test 的退出码判断：没编译过、一个测试都没跑起来也算失败
unit="$(swift test --package-path "$root/native" 2>&1)" || { tail -40 <<<"$unit"; echo "单元测试失败"; exit 1; }
echo "  $(grep -o 'Test run with .*' <<<"$unit" | tail -1)"
build_native

work="$(mktemp -d -t napbox-test)"
export NAPBOX_SUPPORT_DIR="$work/support"
sock="$NAPBOX_SUPPORT_DIR/napboxd.sock"
pids=()
cleanup() {
    for p in "${pids[@]}"; do kill "$p" 2>/dev/null; done
    rm -rf "$work"
}
trap cleanup EXIT

start_daemon() { # 后台起一份 napboxd，日志写到 $1；pid 放进 started
    "$napboxd" >"$1" 2>&1 &
    started=$!
    pids+=("$started")
}
wait_socket() { for _ in $(seq 1 50); do [ -S "$sock" ] && return 0; sleep 0.1; done; return 1; }
wait_exit() { # wait_exit <pid>：等它退出，退出码放进 code
    for _ in $(seq 1 50); do kill -0 "$1" 2>/dev/null || break; sleep 0.1; done
    wait "$1" 2>/dev/null; code=$?
}
is_json_error() { # is_json_error <输出> <错误码>
    [ "$(jq -r '.error.code' <<<"$1" 2>/dev/null)" = "$2" ]
}

echo "napboxd 不在时"
out="$("$napbox" status)"; code=$?
check "status 退出码 1" test "$code" -eq 1
check "status 输出 daemon_unavailable" is_json_error "$out" daemon_unavailable
# env 的输出给 eval 用，logs、exec 的输出是原样内容：出错时的 JSON 写到标准错误
out="$("$napbox" env 2>"$work/env.err")"; code=$?
check "env 退出码 1" test "$code" -eq 1
check "env 出错时标准输出是空的" test -z "$out"
check "env 的错误 JSON 写到标准错误" is_json_error "$(cat "$work/env.err")" daemon_unavailable

echo "命令写错"
out="$("$napbox" stauts)"; code=$?
check "退出码 1" test "$code" -eq 1
check "输出 usage_error" is_json_error "$out" usage_error
"$napbox" --help >/dev/null; code=$?
check "--help 退出码 0" test "$code" -eq 0

echo "启动"
start_daemon "$work/d1.log"; d1=$started
check "socket 出现" wait_socket
check "socket 权限 600" test "$(stat -f %Lp "$sock")" = 600
out="$("$napbox" status)"
check "status 返回 pid" test "$(jq -r .pid <<<"$out")" = "$d1"
check "status --text" grep -q "运行中" <<<"$("$napbox" status --text)"

echo "只运行一份"
start_daemon "$work/d2.log"; wait_exit "$started"
check "第二份退出码 1" test "$code" -eq 1
check "第二份说明已在运行" grep -q "已经有一份" "$work/d2.log"
check "第一份还能用" test "$(jq -r .pid <<<"$("$napbox" status)")" = "$d1"

echo "一个连接里多条请求（发完就关写端）"
replies="$(printf '%s\n' 'not json' '{"id":7,"method":"nope"}' '{"id":8,"method":"status"}' | nc -U "$sock")"
check "坏请求回 bad_request，id 0" test "$(sed -n 1p <<<"$replies" | jq -r '"\(.id) \(.error.code)"')" = "0 bad_request"
check "不认识的方法回 unknown_method" test "$(sed -n 2p <<<"$replies" | jq -r '"\(.id) \(.error.code)"')" = "7 unknown_method"
check "status 正常回应" test "$(sed -n 3p <<<"$replies" | jq -r '"\(.id) \(.result.pid)"')" = "8 $d1"

echo "连上就断、并发"
for _ in $(seq 1 20); do nc -U "$sock" </dev/null; done
check "连上就断 20 次后还在" kill -0 "$d1"
callers=(); for i in $(seq 1 20); do "$napbox" status >"$work/c$i.out" & callers+=($!); done; wait "${callers[@]}"
ok=0; for i in $(seq 1 20); do [ "$(jq -r .pid "$work/c$i.out" 2>/dev/null)" = "$d1" ] && ok=$((ok + 1)); done
check "同时 20 个 status 全部成功（$ok/20）" test "$ok" -eq 20

echo "SIGTERM"
kill -TERM "$d1"; wait_exit "$d1"
check "退出码 0" test "$code" -eq 0
check "socket 文件已删除" test ! -e "$sock"

echo "两份同时启动（5 轮）"
for r in 1 2 3 4 5; do
    start_daemon "$work/r$r-a.log"; a=$started
    start_daemon "$work/r$r-b.log"; b=$started
    wait_socket; sleep 0.3
    alive=(); for p in "$a" "$b"; do kill -0 "$p" 2>/dev/null && alive+=("$p"); done
    check "第 $r 轮只剩一份" test "${#alive[@]}" -eq 1
    check "第 $r 轮 status 连的是剩下那份" test "$(jq -r .pid <<<"$("$napbox" status)")" = "${alive[0]:-none}"
    check "第 $r 轮没有崩溃" sh -c "! grep -q 'Fatal error' '$work/r$r-a.log' '$work/r$r-b.log'"
    for p in "$a" "$b"; do kill -TERM "$p" 2>/dev/null; wait_exit "$p"; done
done

echo "状态文件和端口锁"
state="$NAPBOX_SUPPORT_DIR/state.json"
port_free() { # port_free <端口>：能在 0.0.0.0 上绑上说明没人占
    python3 -I -c 'import socket,sys; s=socket.socket(); s.bind(("0.0.0.0", int(sys.argv[1])))' "$1" 2>/dev/null
}
echo '{oops' >"$state"
start_daemon "$work/s1.log"; wait_exit "$started"
check "状态文件坏了：退出码 1" test "$code" -eq 1
check "状态文件坏了：说明原因、不覆盖" sh -c "grep -q '状态文件' '$work/s1.log' && grep -q '{oops' '$state'"
# 登记的 worktree 要真的在，否则启动时会被当成删掉了回收
fixrepo="$work/fixrepo"; git init -q "$fixrepo"; fixrepo="$(cd "$fixrepo" && pwd -P)"
cat >"$state" <<JSON
{"version":1,"environments":[{"name":"demo/main","project":"demo","mainRepository":"$fixrepo","worktree":"$fixrepo","owner":{"worktree":{}},"completedServices":[],"egress":"open",
 "ports":[{"service":"db","containerPort":5432,"hostPort":38431},{"service":"api","containerPort":3100,"hostPort":38432}]}]}
JSON
python3 -I -c 'import socket,time; s=socket.socket(); s.bind(("0.0.0.0", 38432)); s.listen(1); time.sleep(30)' &
holder=$!; pids+=("$holder"); sleep 0.3
start_daemon "$work/s2.log"; s2=$started
check "有登记时正常启动" wait_socket
port_taken() { ! port_free "$1"; }
check "登记的空闲端口被锁上" port_taken 38431
check "被占的端口记进日志" grep -q "38432 被别的程序占着" "$work/s2.log"
check "日志说明锁上几个" grep -q "锁上 1/2 个端口" "$work/s2.log"
kill -TERM "$s2"; wait_exit "$s2"; kill "$holder" 2>/dev/null
check "napboxd 退出后端口放开" port_free 38431
rm -f "$state"

echo "worktree 删掉后回收、保留期满的数据清理"
# 两个环境：demo/main 的 worktree 在；demo/gone 的 worktree 已经删掉（napboxd 没运行时删的）
cat >"$state" <<JSON
{"version":1,"environments":[
 {"name":"demo/main","project":"demo","mainRepository":"$fixrepo","worktree":"$fixrepo","owner":{"worktree":{}},"completedServices":[],"egress":"open","ports":[]},
 {"name":"demo/gone","project":"demo","mainRepository":"$fixrepo","worktree":"$work/gone-wt","owner":{"worktree":{}},"completedServices":[],"egress":"open",
  "ports":[{"service":"db","containerPort":5432,"hostPort":38441}]}]}
JSON
recycled="$NAPBOX_SUPPORT_DIR/recycled"
for d in old:8 new:1; do
    mkdir -p "$recycled/${d%%:*}"
    printf '{"name":"demo/%s","worktree":"/w","reason":"napbox down","recycledAt":"%s"}' "${d%%:*}" \
        "$(date -u -v-"${d##*:}"d +%Y-%m-%dT%H:%M:%SZ)" >"$recycled/${d%%:*}/recycled.json"
done
mkdir -p "$recycled/legacy" # 没有 recycled.json：不知道什么时候回收的
touch "$recycled/.DS_Store" # 不是目录，不管
start_daemon "$work/s3.log"; s3=$started
wait_socket
names="$("$napbox" status | jq -c '[.environments[].name]')"
check "worktree 删掉的环境被回收，还在的留着" test "$names" = '["demo/main"]'
check "启动时先锁上了 demo/gone 登记的端口（对照：下面查放开）" grep -q "锁上 1/1 个端口" "$work/s3.log"
check "日志说明回收原因" grep -q "demo/gone 的 worktree 删掉了（目录 $work/gone-wt 不在了），回收" "$work/s3.log"
check "回收的环境的端口放开了" port_free 38441
check "登记里也删掉了" test "$(jq -c '[.environments[].name]' "$state")" = '["demo/main"]'
check "保留满 7 天的数据删掉了" test ! -e "$recycled/old"
check "没满 7 天的留着" test -f "$recycled/new/recycled.json"
check "没有 recycled.json 的不动，日志说明" sh -c "test -d '$recycled/legacy' && grep -q 'legacy 没有能看懂的 recycled.json' '$work/s3.log'"
check "不是目录的不管" sh -c "test -f '$recycled/.DS_Store' && ! grep -q 'DS_Store' '$work/s3.log'"
kill -TERM "$s3"; wait_exit "$s3"
rm -rf "$state" "$recycled"

echo "上次没做完的回收和 reset：启动时接着做完"
# 伪造 napboxd 做到一半被杀后的状态：登记里带着没做完的操作
id_of() { # 和 EnvironmentRecord.id 一样的算法：环境名的 FNV-1a 64 位哈希
    python3 -I -c 'import sys
h = 14695981039346656037
for b in sys.argv[1].encode(): h = ((h ^ b) * 1099511628211) & 0xFFFFFFFFFFFFFFFF
print(format(h, "x"))' "$1"
}
envs="$NAPBOX_SUPPORT_DIR/environments"
main_id="$(id_of demo/main)"; half_id="$(id_of codeos/half)"; logs="$NAPBOX_SUPPORT_DIR/builder/logs"
mkdir -p "$envs/$main_id/volumes" "$envs/$half_id/volumes" "$logs/$main_id" "$logs/0123abcd"
echo pg >"$envs/$main_id/volumes/pg.ext4"; echo kept >"$envs/$main_id/volumes/other.ext4"; echo data >"$envs/$half_id/volumes/db.ext4"
cat >"$state" <<JSON
{"version":1,"environments":[
 {"name":"demo/main","project":"demo","mainRepository":"$fixrepo","worktree":"$fixrepo","owner":{"worktree":{}},"completedServices":["migrate"],"egress":"open","ports":[],
  "pending":{"resetVolume":{"_0":"pg"}}},
 {"name":"codeos/half","worktree":"$work/half","owner":{"caller":{"id":"codeos"}},"completedServices":["migrate"],"egress":"open",
  "ports":[{"service":"db","containerPort":5432,"hostPort":38451}],"pending":{"recycle":{"reason":"codeos 销毁","discardData":false}}},
 {"name":"codeos/moved","worktree":"$work/moved","owner":{"caller":{"id":"codeos"}},"completedServices":[],"egress":"open",
  "ports":[{"service":"db","containerPort":5432,"hostPort":38452}],"pending":{"recycle":{"reason":"codeos 销毁","discardData":true}}}]}
JSON
start_daemon "$work/s5.log"; s5=$started
wait_socket
check "回收做完：登记里只剩 reset 的那个" test "$(jq -c '[.environments[].name]' "$state")" = '["demo/main"]'
check "回收的数据移进 recycled，带 recycled.json" sh -c "f=\$(ls -d '$recycled/$half_id'-* | head -1) && test -f \"\$f/volumes/db.ext4\" -a -f \"\$f/recycled.json\""
check "环境目录不在原处了" test ! -e "$envs/$half_id"
check "回收的环境的端口放开了" port_free 38451
check "数据已经移走的那个也做完、端口放开了" port_free 38452
check "日志说明接着回收" grep -q "codeos/half 上次回收没做完（codeos 销毁），接着做" "$work/s5.log"
check "reset 做完：卷移进 recycled，带 recycled.json" sh -c "f=\$(ls -d '$recycled/$main_id'-*-pg) && test -f \"\$f/volumes/pg.ext4\" -a -f \"\$f/recycled.json\""
check "reset 做完：别的卷不动" test -f "$envs/$main_id/volumes/other.ext4"
check "reset 做完：一次性服务重新初始化、记号去掉" test "$(jq -c '.environments[0] | [.completedServices, .pending]' "$state")" = '[[],null]'
check "登记着的环境的构建日志不动" sh -c "test -d '$logs/$main_id' && ! grep -q '$main_id 没有登记' '$work/s5.log'"
# 这份 napboxd 没有内核，查不了镜像：日志说明，构建日志留着下次再试
check "没登记的环境留下的构建结果：查不了镜像时留着、日志说明" sh -c "test -d '$logs/0123abcd' && grep -q '0123abcd 没有登记，它留下的构建结果删不掉' '$work/s5.log'"
kill -TERM "$s5"; wait_exit "$s5"
rm -rf "$state" "$recycled" "$envs" "$NAPBOX_SUPPORT_DIR/builder"

echo "调用方持有的环境（不起虚拟机）"
# 和 CodeOS 的 Goal 副本一样：独立的 git 仓库，目录叫 repo
# 登记里写 napboxd 自己算出来的路径：resolvingSymlinksInPath 会把 /private/var 变成 /var（pwd -P 不会）
copy="$work/copy-a/repo"; mkdir -p "$copy"; git init -q "$copy"; copy="$(cd "$copy" && pwd -P)"; copy="${copy#/private}"
other="$work/copy-b/repo"; mkdir -p "$other"; other="$(cd "$other" && pwd -P)"
printf 'services:\n  app:\n    image: alpine:3.20\n' | tee "$copy/compose.yaml" >"$other/compose.yaml"
cat >"$state" <<JSON
{"version":1,"environments":[
 {"name":"demo/main","project":"demo","mainRepository":"$fixrepo","worktree":"$fixrepo","owner":{"worktree":{}},"completedServices":[],"egress":"open","ports":[]},
 {"name":"codeos/goal-1-work","worktree":"$copy","owner":{"caller":{"id":"codeos"}},"completedServices":[],"egress":"open","ports":[]},
 {"name":"codeos/goal-2-gone","worktree":"$work/never-existed","owner":{"caller":{"id":"codeos"}},"completedServices":[],"egress":"open","ports":[]}]}
JSON
start_daemon "$work/s4.log"; s4=$started
wait_socket
own='{"target":{"name":"codeos/goal-1-work","owner":"codeos"}}'
code_of() { jq -r .error.code <<<"$1"; }
create() { rpc create "$(jq -nc --arg name "$1" --arg owner "$2" --arg dir "$3" '{name: $name, owner: $owner, directory: $dir, files: [], profiles: [], environment: {}}')"; }
check "status 里有持有方" test "$("$napbox" status | jq -r '.environments[] | select(.name == "codeos/goal-1-work") | .owner')" = codeos
check "worktree 持有的环境没有持有方" test "$("$napbox" status | jq -r '.environments[] | select(.name == "demo/main") | .owner')" = null
check "代码副本不在了也不回收（只有调用方能回收）" test "$("$napbox" status | jq -r '[.environments[].name] | index("codeos/goal-2-gone") != null')" = true
check "代码副本里 napbox up 被拒绝" test "$(code_of "$(cd "$copy" && "$napbox" up)")" = owner_mismatch
check "代码副本里 napbox sleep 被拒绝" test "$(code_of "$(cd "$copy" && "$napbox" sleep)")" = owner_mismatch
check "按名字操作，持有方不对被拒绝" test "$(code_of "$(rpc sleep '{"target":{"name":"codeos/goal-1-work","owner":"other"}}')")" = owner_mismatch
check "按名字操作 worktree 持有的环境被拒绝" test "$(code_of "$(rpc sleep '{"target":{"name":"demo/main","owner":"codeos"}}')")" = owner_mismatch
check "按名字操作不存在的环境" test "$(code_of "$(rpc sleep '{"target":{"name":"codeos/nope","owner":"codeos"}}')")" = environment_not_found
check "target 同时写 cwd 和名字被拒绝" test "$(code_of "$(rpc sleep '{"target":{"cwd":"/","name":"codeos/goal-1-work","owner":"codeos"}}')")" = bad_request
check "休眠的环境按名字 sleep：还是休眠" test "$(rpc sleep "$own" | jq -r .result.state)" = sleeping
check "还没起过的环境运行记录是空的" test "$(rpc runs "$own" | jq -c .result.runs)" = "[]"
check "create 名字写法不对" test "$(code_of "$(create 'CodeOS/goal' codeos "$copy")")" = bad_request
check "create 持有方写法不对" test "$(code_of "$(create codeos/goal 'Code OS' "$copy")")" = bad_request
check "create 相对路径" test "$(code_of "$(create codeos/goal codeos copy-a/repo)")" = bad_request
check "create 目录不存在" test "$(code_of "$(create codeos/goal codeos "$work/nope")")" = bad_request
check "create 同名、持有方不同：name_taken" test "$(code_of "$(create codeos/goal-1-work other "$copy")")" = name_taken
check "create 同名、目录不同：name_taken" test "$(code_of "$(create codeos/goal-1-work codeos "$other")")" = name_taken
check "create 占 worktree 环境的名字：name_taken" test "$(code_of "$(create demo/main codeos "$copy")")" = name_taken
subscribe_to "$work/events-codeos.out" '{"owner":"codeos"}'; check "订阅 codeos 的事件：先收到订阅生效" test "$?" -eq 0; sub1=$subscriber; pids+=("$sub1")
subscribe_to "$work/events-other.out" '{"owner":"other"}'; sub2=$subscriber; pids+=("$sub2")
subscribe_to "$work/events-name.out" '{"names":["codeos/goal-2-gone"]}'; sub3=$subscriber; pids+=("$sub3")
downed="$(rpc down "$own")"
check "按名字销毁" test "$(jq -r .result.name <<<"$downed")" = codeos/goal-1-work
for _ in $(seq 1 50); do grep -q '"event"' "$work/events-codeos.out" && break; sleep 0.1; done
check "持有方收到 destroyed 事件，带原因" test "$(sed -n 2p "$work/events-codeos.out" | jq -r '.event | "\(.type) \(.environment) \(.owner) \(.reason)"')" = "destroyed codeos/goal-1-work codeos codeos 销毁"
check "别的持有方收不到" test "$(grep -c '"event"' "$work/events-other.out")" = 0
check "按名字过滤的收不到别的环境" test "$(grep -c '"event"' "$work/events-name.out")" = 0
check "销毁后 status 里没有了" test "$("$napbox" status | jq -r '[.environments[].name] | index("codeos/goal-1-work")')" = null
# napboxd 退出时 subscribe 的连接直接断开，订阅的程序自己结束
kill -TERM "$s4"; wait_exit "$s4"
wait_exit "$sub1"; check "napboxd 退出后订阅连接断开" test "$(kill -0 "$sub1" 2>/dev/null && echo alive)" = ""
rm -rf "$state" "$recycled"

echo "回应和命令行版本对不上"
mkdir -p "$NAPBOX_SUPPORT_DIR"
python3 -I -c '
import socket, sys
s = socket.socket(socket.AF_UNIX); s.bind(sys.argv[1]); s.listen(1)
c, _ = s.accept(); c.recv(65536); c.sendall(b"{\"id\":1,\"result\":{\"version\":\"0.0.9\"}}\n"); c.close()
' "$sock" &
fake=$!; pids+=("$fake")
wait_socket
out="$("$napbox" status)"; code=$?
check "退出码 1" test "$code" -eq 1
check "输出 protocol_error" is_json_error "$out" protocol_error
wait "$fake" 2>/dev/null; rm -f "$sock"

summary
