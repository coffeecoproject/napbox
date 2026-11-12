// 测：pod 里按依赖顺序启动（等前一个健康再启动下一个），一次性服务退出后其他服务是否不受影响、唤醒时不重新执行。
// 也顺带测：没有端口的服务怎么判断"进程在运行"、有端口的服务由网络小容器查监听、一个常驻服务崩溃后其他服务是否还在。
// 用法：PodOrder <工作目录> <内核路径>
import Containerization
import ContainerizationExtras
import ContainerizationOCI
import Foundation

setvbuf(stdout, nil, _IOLBF, 0)
let root = URL(fileURLWithPath: CommandLine.arguments[1])
let kernelPath = CommandLine.arguments[2]
let ip = "192.168.64.221"
let t0 = Date()
func ts() -> String { String(format: "%6.2fs", Date().timeIntervalSince(t0)) }
func log(_ items: Any...) { print("[\(ts())]", items.map { "\($0)" }.joined(separator: " ")) }

final class Buf: Writer, @unchecked Sendable {
    var data = Data()
    func write(_ d: Data) throws { data.append(d) }
    func close() throws {}
    var text: String { String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "" }
}
let contentStore = try LocalContentStore(path: root.appending(path: "content"))
let store = try ImageStore(path: root, contentStore: contentStore)
let platform = Platform(arch: "arm64", os: "linux", variant: "v8")
func image(_ ref: String) async throws -> Containerization.Image {
    if let found = try? await store.get(reference: ref) { return found }
    return try await store.pull(reference: ref, platform: platform)
}

// 每个容器一份根文件系统；postgres 和一次性服务 init 都用 postgres 镜像（init 要用 psql）
let pgRef = "docker.io/library/postgres:17-alpine", alpineRef = "docker.io/library/alpine:3.20"
let layout: [(String, String)] = [("postgres", pgRef), ("init", pgRef), ("bad", alpineRef), ("app", alpineRef), ("worker", alpineRef), ("guard", alpineRef)]
var envs: [String: [String]] = [:]
var mounts: [String: Containerization.Mount] = [:]
for (name, ref) in layout {
    let img = try await image(ref)
    let path = root.appending(path: "order-\(name).ext4")
    try? FileManager.default.removeItem(at: path)
    mounts[name] = try await EXT4Unpacker(capacityInBytes: 2 * 1024 * 1024 * 1024).unpack(img, for: platform, at: path)
    envs[name] = try await img.config(for: platform).config?.env ?? []
}
let initImage = try await store.getInitImage(reference: "ghcr.io/apple/containerization/vminit:0.53.0")
let initPath = root.appending(path: "init.block")
try? FileManager.default.removeItem(at: initPath)
let initfs = try await initImage.initBlock(at: initPath, for: .linuxArm)
let vmm = VZVirtualMachineManager(kernel: Kernel(path: URL(fileURLWithPath: kernelPath), platform: .linuxArm), initialFilesystem: initfs)
log("准备完成")

// 一次性服务：往数据库里记一次"我跑过了"，用来判断唤醒时有没有被重新执行
let initScript = "psql -h 127.0.0.1 -U postgres -v ON_ERROR_STOP=1 -c \"create table if not exists init_runs(at timestamptz default now()); insert into init_runs default values;\" && echo init-done"

@MainActor func makePod(_ id: String, oneShot: String) async throws -> LinuxPod {
    let pe = envs["postgres"]!, ie = envs["init"]!, be = envs["bad"]!, ae = envs["app"]!, we = envs["worker"]!, script = initScript
    let pod = try LinuxPod(id, vmm: vmm, vm: VMResources(cpus: 4, memoryInBytes: 2048 * 1024 * 1024)) { c in
        c.interfaces = [NATInterface(ipv4Address: try CIDRv4("\(ip)/24"), ipv4Gateway: try IPv4Address("192.168.64.1"))]
    }
    try await pod.addContainer("postgres", rootfs: mounts["postgres"]!) { c in
        c.process.arguments = ["docker-entrypoint.sh", "postgres", "-c", "listen_addresses=*"]
        c.process.environmentVariables = pe + ["POSTGRES_PASSWORD=x", "PGDATA=/var/lib/postgresql/data/pg", "POSTGRES_HOST_AUTH_METHOD=trust"]
    }
    if oneShot == "init" {
        try await pod.addContainer("init", rootfs: mounts["init"]!) { c in
            c.process.arguments = ["sh", "-c", script]; c.process.environmentVariables = ie
        }
    } else {
        try await pod.addContainer("bad", rootfs: mounts["bad"]!) { c in
            c.process.arguments = ["sh", "-c", "echo bad-start; sleep 1; exit 3"]; c.process.environmentVariables = be
        }
    }
    // 有端口的常驻服务：8080 上回一行 ok
    try await pod.addContainer("app", rootfs: mounts["app"]!) { c in
        c.process.arguments = ["sh", "-c", "while true; do echo ok | nc -l -p 8080 >/dev/null; done"]; c.process.environmentVariables = ae
    }
    // 没有端口的后台任务
    try await pod.addContainer("worker", rootfs: mounts["worker"]!) { c in
        c.process.arguments = ["sh", "-c", "while true; do date +%s > /tmp/beat; sleep 1; done"]; c.process.environmentVariables = we
    }
    // 网络小容器：查端口监听
    try await pod.addContainer("guard", rootfs: mounts["guard"]!) { c in
        c.process.arguments = ["sleep", "3600"]; c.process.capabilities = .allCapabilities
    }
    return pod
}
@MainActor func run(_ pod: LinuxPod, _ cid: String, _ argv: [String]) async -> (Int32, String) {
    let out = Buf()
    do {
        let p = try await pod.execInContainer(cid, processID: "x\(UUID().uuidString.prefix(8))") { c in
            c.arguments = argv; c.stdout = out; c.stderr = out
        }
        try await p.start(); let st = try await p.wait(); try await p.delete()
        return (st.exitCode, String(out.text.prefix(200)))
    } catch { return (-1, "错误: \(error)") }
}
@MainActor func pgReady(_ pod: LinuxPod) async -> Bool { await run(pod, "postgres", ["pg_isready", "-h", "127.0.0.1", "-q"]).0 == 0 }
@MainActor func waitPg(_ pod: LinuxPod) async throws -> Bool {
    for _ in 0..<150 { if await pgReady(pod) { return true }; try await Task.sleep(nanoseconds: 100_000_000) }
    return false
}
// 网络小容器在虚拟机里查监听端口（pod 共用网络，看得到所有服务的监听）
@MainActor func listening(_ pod: LinuxPod, _ port: Int) async -> Bool {
    await run(pod, "guard", ["sh", "-c", "netstat -ltn | grep -q ':\(port) '"]).0 == 0
}
// 没端口的服务：容器进程是否还在。waitContainer 带短超时，超时 = 还在跑
@MainActor func alive(_ pod: LinuxPod, _ cid: String) async -> String {
    do { let st = try await pod.waitContainer(cid, timeoutInSeconds: 1); return "已退出(\(st.exitCode))" } catch {
        let e = String(describing: error)
        return e.lowercased().contains("not found or not started") ? "没有进程（\(e.prefix(80))）" : "在运行（等待超时：\(e.prefix(80))）"
    }
}
@MainActor func snapshot(_ pod: LinuxPod, _ label: String) async {
    let initRuns = await run(pod, "postgres", ["psql", "-h", "127.0.0.1", "-U", "postgres", "-tAc", "select count(*) from init_runs"])
    log("[\(label)] postgres 健康：\(await pgReady(pod))",
        "| app 8080 在监听：\(await listening(pod, 8080))",
        "| app 回应：\(await run(pod, "guard", ["sh", "-c", "nc 127.0.0.1 8080 </dev/null | head -1"]).1)",
        "| worker：\(await alive(pod, "worker"))，心跳 \(await run(pod, "worker", ["cat", "/tmp/beat"]).1)",
        "| init_runs 行数：\(initRuns.0 == 0 ? initRuns.1 : "表不存在")")
}
func nowEpoch() -> Int { Int(Date().timeIntervalSince1970) }

// ===== A. 首次启动：按依赖顺序 postgres(健康) → init(成功退出) → app、worker =====
log("===== A. 首次启动，按依赖顺序")
var pod = try await makePod("order-a", oneShot: "init")
try await pod.create()
try await pod.startContainer("guard")
try await pod.startContainer("postgres")
log("postgres 已启动，等健康")
log("postgres 健康：\(try await waitPg(pod))；此时 app 在监听：\(await listening(pod, 8080))（应为 false）")
log("故意再等 5 秒，模拟依赖服务健康检查慢")
try await Task.sleep(nanoseconds: 5_000_000_000)
try await pod.startContainer("init")
let initExit = try await pod.waitContainer("init", timeoutInSeconds: 60)
log("init 退出码：\(initExit.exitCode)")
log("init 退出后：postgres 健康 \(await pgReady(pod))，guard 能执行命令 \(await run(pod, "guard", ["true"]).0 == 0)，容器列表 \(await pod.listContainers().sorted())")
try await pod.startContainer("app")
try await pod.startContainer("worker")
var ok = false
for _ in 0..<50 { if await listening(pod, 8080) { ok = true; break }; try await Task.sleep(nanoseconds: 100_000_000) }
log("app、worker 已启动，8080 开始监听：\(ok)")
try await Task.sleep(nanoseconds: 3_000_000_000)
await snapshot(pod, "A 全部起来 3 秒后，当前 \(nowEpoch())")
log("对已退出的 init 再 waitContainer：\(await alive(pod, "init"))")
do { try await pod.stopContainer("init"); log("stopContainer(已退出的 init)：成功") } catch { log("stopContainer(已退出的 init)：失败 \(error)") }
await snapshot(pod, "A 清理 init 之后")
do { try await pod.startContainer("init"); log("再次 startContainer(init)：成功（意外）") } catch { log("再次 startContainer(init)：失败（预期）\(String(describing: error).prefix(120))") }

// ===== D. 常驻服务崩溃：其他服务是否还在 =====
log("===== D. worker 崩溃")
try await pod.killContainer("worker", signal: .kill)
try await Task.sleep(nanoseconds: 1_000_000_000)
log("worker：\(await alive(pod, "worker"))")
await snapshot(pod, "D worker 崩溃后")

var t = Date(); try await pod.stop()
log("A 休眠：停止整个环境 \(String(format: "%.2f", Date().timeIntervalSince(t)))s（含一个已退出、一个已崩溃的容器）")

// ===== B. 唤醒：同一份定义，一次性服务加进 pod 但不启动 =====
log("===== B. 唤醒，init 加入但不启动")
pod = try await makePod("order-b", oneShot: "init")
t = Date()
try await pod.create()
try await pod.startContainer("guard")
try await pod.startContainer("postgres")
let ready = try await waitPg(pod)
try await pod.startContainer("app")
try await pod.startContainer("worker")
ok = false
for _ in 0..<50 { if await listening(pod, 8080) { ok = true; break }; try await Task.sleep(nanoseconds: 100_000_000) }
log("唤醒：postgres 健康 \(ready)，app 监听 \(ok)，共 \(String(format: "%.2f", Date().timeIntervalSince(t)))s")
try await Task.sleep(nanoseconds: 2_000_000_000)
await snapshot(pod, "B 唤醒后（init_runs 应仍为 1）")
log("没启动过的 init：\(await alive(pod, "init"))")
t = Date(); try await pod.stop()
log("B 休眠：停止 \(String(format: "%.2f", Date().timeIntervalSince(t)))s（含一个从没启动的容器）")

// ===== C. 一次性服务失败：依赖它的服务不启动，其他服务不受影响 =====
log("===== C. 一次性服务失败")
pod = try await makePod("order-c", oneShot: "bad")
try await pod.create()
try await pod.startContainer("guard")
try await pod.startContainer("postgres")
log("postgres 健康：\(try await waitPg(pod))")
try await pod.startContainer("bad")
let badExit = try await pod.waitContainer("bad", timeoutInSeconds: 30)
log("bad 退出码：\(badExit.exitCode)；按 compose 语义，依赖它的 app 不启动")
try await Task.sleep(nanoseconds: 1_000_000_000)
log("bad 失败后：postgres 健康 \(await pgReady(pod))，app 在监听 \(await listening(pod, 8080))（应为 false），guard 能执行 \(await run(pod, "guard", ["true"]).0 == 0)")
t = Date(); try await pod.stop()
log("C 停止 \(String(format: "%.2f", Date().timeIntervalSince(t)))s")
log("全部结束")
