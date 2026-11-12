// 测：整个环境休眠、唤醒、重启的耗时，数据是否保留；虚拟机里用 iptables 挡宿主机服务和完全不出网。
// 用法：PodLife <工作目录> <内核路径>
import Containerization
import ContainerizationExtras
import ContainerizationOCI
import Foundation

setvbuf(stdout, nil, _IOLBF, 0)
let root = URL(fileURLWithPath: CommandLine.arguments[1])
let kernelPath = CommandLine.arguments[2]
let ip = "192.168.64.220"

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
var envs: [String: [String]] = [:]
var mounts: [String: Containerization.Mount] = [:]
for (name, ref) in [("redis", "docker.io/library/redis:7-alpine"), ("postgres", "docker.io/library/postgres:17-alpine"), ("guard", "docker.io/library/alpine:3.20")] {
    let img = try await image(ref)
    let path = root.appending(path: "\(name).ext4")
    try? FileManager.default.removeItem(at: path)
    mounts[name] = try await EXT4Unpacker(capacityInBytes: 2 * 1024 * 1024 * 1024).unpack(img, for: platform, at: path)
    envs[name] = try await img.config(for: platform).config?.env ?? []
}
let initImage = try await store.getInitImage(reference: "ghcr.io/apple/containerization/vminit:0.53.0")
let initPath = root.appending(path: "init.block")
try? FileManager.default.removeItem(at: initPath)
let initfs = try await initImage.initBlock(at: initPath, for: .linuxArm)
let vmm = VZVirtualMachineManager(kernel: Kernel(path: URL(fileURLWithPath: kernelPath), platform: .linuxArm), initialFilesystem: initfs)

@MainActor func makePod(_ id: String) async throws -> LinuxPod {
    let re = envs["redis"]!, pe = envs["postgres"]!
    let pod = try LinuxPod(id, vmm: vmm, vm: VMResources(cpus: 4, memoryInBytes: 2048 * 1024 * 1024)) { c in
        c.interfaces = [NATInterface(ipv4Address: try CIDRv4("\(ip)/24"), ipv4Gateway: try IPv4Address("192.168.64.1"))]
    }
    try await pod.addContainer("redis", rootfs: mounts["redis"]!) { c in
        c.process.arguments = ["redis-server", "--save", "", "--protected-mode", "no"]; c.process.environmentVariables = re
    }
    try await pod.addContainer("postgres", rootfs: mounts["postgres"]!) { c in
        c.process.arguments = ["docker-entrypoint.sh", "postgres", "-c", "listen_addresses=*"]
        c.process.environmentVariables = pe + ["POSTGRES_PASSWORD=x", "PGDATA=/var/lib/postgresql/data/pg", "POSTGRES_HOST_AUTH_METHOD=trust"]
    }
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
            if cid == "guard" { c.capabilities = .allCapabilities }
        }
        try await p.start(); let st = try await p.wait(); try await p.delete()
        return (st.exitCode, String(out.text.prefix(160)))
    } catch { return (-1, "错误: \(error)") }
}
func host(_ port: Int) -> String {
    let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/nc"); p.arguments = ["-z", "-G", "2", ip, "\(port)"]
    p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
    try? p.run(); p.waitUntilExit(); return p.terminationStatus == 0 ? "通" : "不通"
}
@MainActor func startTimed(_ pod: LinuxPod, _ label: String) async throws {
    let t = Date()
    try await pod.create()
    for n in ["redis", "postgres", "guard"] { try await pod.startContainer(n) }
    let booted = Date().timeIntervalSince(t)
    var ready = -1.0
    for _ in 0..<100 {
        if await run(pod, "postgres", ["pg_isready", "-h", "127.0.0.1", "-q"]).0 == 0 { ready = Date().timeIntervalSince(t); break }
        try await Task.sleep(nanoseconds: 100_000_000)
    }
    print("[\(label)] 虚拟机和容器起来 \(String(format: "%.2f", booted))s，postgres 能连 \(String(format: "%.2f", ready))s，宿主机连 5432：\(host(5432))")
}

// 1. 首次启动
var pod = try await makePod("life-1")
try await startTimed(pod, "首次启动（含初始化数据库）")
print("[写数据]", await run(pod, "postgres", ["psql", "-U", "postgres", "-h", "127.0.0.1", "-c", "create table t(v text); insert into t values ('still-here');"]))

// 2. 出网规则
print("[DNS 配置]", await run(pod, "guard", ["sh", "-c", "cat /etc/resolv.conf 2>&1 | tr '\\n' ' '"]))
print("[解析域名]", await run(pod, "guard", ["sh", "-c", "nslookup dl-cdn.alpinelinux.org 2>&1 | tail -3 | tr '\\n' ' '"]))
print("[用网关做 DNS 解析]", await run(pod, "guard", ["sh", "-c", "nslookup dl-cdn.alpinelinux.org 192.168.64.1 2>&1 | tail -3 | tr '\\n' ' '"]))
print("[装 iptables]", await run(pod, "guard", ["sh", "-c", "echo nameserver 192.168.64.1 > /etc/resolv.conf; apk add --no-cache -q iptables 2>&1 | tail -2; command -v iptables"]))
print("[规则前] 连宿主机 22：", await run(pod, "postgres", ["nc", "-z", "-w", "2", "192.168.64.1", "22"]).0 == 0 ? "通" : "不通",
      "| 连外网 1.1.1.1:80：", await run(pod, "postgres", ["nc", "-z", "-w", "3", "1.1.1.1", "80"]).0 == 0 ? "通" : "不通")
// install：挡住到宿主机的新连接（DNS 除外），宿主机连进来的回包放行
let installRules = [
    ["iptables", "-A", "OUTPUT", "-d", "192.168.64.1", "-m", "conntrack", "--ctstate", "ESTABLISHED,RELATED", "-j", "ACCEPT"],
    ["iptables", "-A", "OUTPUT", "-d", "192.168.64.1", "-p", "udp", "--dport", "53", "-j", "ACCEPT"],
    ["iptables", "-A", "OUTPUT", "-d", "192.168.64.0/24", "-j", "REJECT"],
]
for r in installRules { let o = await run(pod, "guard", r); if o.0 != 0 { print("[规则失败]", r, o) } }
print("[install] 连宿主机 22：", await run(pod, "postgres", ["nc", "-z", "-w", "2", "192.168.64.1", "22"]).0 == 0 ? "通" : "不通",
      "| 连外网：", await run(pod, "postgres", ["nc", "-z", "-w", "3", "1.1.1.1", "80"]).0 == 0 ? "通" : "不通",
      "| 宿主机连 6379：", host(6379), "| 环境内 redis：", await run(pod, "postgres", ["nc", "-z", "-w", "2", "127.0.0.1", "6379"]).0 == 0 ? "通" : "不通")
// none：再挡掉所有出网的新连接
let o = await run(pod, "guard", ["iptables", "-A", "OUTPUT", "-o", "eth0", "-m", "conntrack", "--ctstate", "NEW", "-j", "REJECT"])
if o.0 != 0 { print("[规则失败] none", o) }
print("[none] 连外网：", await run(pod, "postgres", ["nc", "-z", "-w", "3", "1.1.1.1", "80"]).0 == 0 ? "通" : "不通",
      "| 宿主机连 6379：", host(6379), "| 宿主机连 5432：", host(5432),
      "| 环境内 redis：", await run(pod, "postgres", ["nc", "-z", "-w", "2", "127.0.0.1", "6379"]).0 == 0 ? "通" : "不通")
print("[没权限的容器改规则]", await run(pod, "postgres", ["sh", "-c", "command -v iptables || echo 没有iptables"]))

// 3. 休眠
func vmMem() -> String {
    let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/sh")
    p.arguments = ["-c", "for i in $(pgrep -f com.apple.Virtualization.VirtualMachine); do printf \"$i:\"; footprint $i 2>/dev/null | grep -o 'Footprint: [0-9]* MB' | grep -o '[0-9]*'; done | tr '\\n' ' '"]
    let pipe = Pipe(); p.standardOutput = pipe; try? p.run(); p.waitUntilExit()
    return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
}
try await Task.sleep(nanoseconds: 10_000_000_000)
print("[休眠前，闲置 10 秒] 虚拟机进程占用(MB)：", vmMem())
var t = Date(); try await pod.stop(); print("[休眠] 停止整个环境 \(String(format: "%.2f", Date().timeIntervalSince(t)))s，宿主机连 5432：\(host(5432))")
try await Task.sleep(nanoseconds: 3_000_000_000)
print("[休眠 3 秒后] 宿主机连 5432：\(host(5432))，虚拟机进程占用：", vmMem())

// 4. 唤醒（数据库已初始化过）
pod = try await makePod("life-2")
try await startTimed(pod, "唤醒")
print("[数据还在]", await run(pod, "postgres", ["psql", "-U", "postgres", "-h", "127.0.0.1", "-tAc", "select v from t"]))
print("[唤醒后规则]", await run(pod, "guard", ["sh", "-c", "iptables -S OUTPUT 2>&1 | wc -l; command -v iptables"]))

// 5. 模拟服务崩溃后整个环境重启
print("[模拟崩溃] 杀 redis：", await run(pod, "redis", ["sh", "-c", "kill -9 1; echo"]).0)
t = Date(); try await pod.stop(); pod = try await makePod("life-3")
let t2 = Date()
try await startTimed(pod, "崩溃后整个重启")
print("[崩溃后整个重启] 含停止，总计 \(String(format: "%.2f", Date().timeIntervalSince(t)))s（停止 \(String(format: "%.2f", t2.timeIntervalSince(t)))s）")
try await pod.stop()
print("全部停止")
