// 测：自签名能否用 NAT 网络；pod 内是否共享网络；不同虚拟机之间是否互通；pod 里停掉的服务能否再起。
// 用法：PodNet <工作目录> <内核路径> <等待宿主机测试的秒数>
import Containerization
import ContainerizationExtras
import ContainerizationOCI
import Foundation

setvbuf(stdout, nil, _IOLBF, 0)
let args = CommandLine.arguments
let root = URL(fileURLWithPath: args[1])
let kernelPath = args[2]
let hold = UInt64(args[3])!

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
func rootfs(_ name: String, _ ref: String) async throws -> (Containerization.Mount, [String]) {
    let img = try await image(ref)
    let path = root.appending(path: "\(name).ext4")
    try? FileManager.default.removeItem(at: path)
    let fs = try await EXT4Unpacker(capacityInBytes: 2 * 1024 * 1024 * 1024).unpack(img, for: platform, at: path)
    return (fs, try await img.config(for: platform).config?.env ?? [])
}

let initImage = try await store.getInitImage(reference: "ghcr.io/apple/containerization/vminit:0.53.0")
let initPath = root.appending(path: "init.block")
try? FileManager.default.removeItem(at: initPath)
let initfs = try await initImage.initBlock(at: initPath, for: .linuxArm)
let vmm = VZVirtualMachineManager(kernel: Kernel(path: URL(fileURLWithPath: kernelPath), platform: .linuxArm), initialFilesystem: initfs)

func nat(_ ip: String) throws -> NATInterface {
    NATInterface(ipv4Address: try CIDRv4("\(ip)/24"), ipv4Gateway: try IPv4Address("192.168.64.1"))
}

// 环境 A：一个 pod，redis + postgres + busybox，一个 NAT 网卡
let pod = try LinuxPod("env-a", vmm: vmm, vm: VMResources(cpus: 4, memoryInBytes: 2048 * 1024 * 1024)) { c in
    c.interfaces = [try nat("192.168.64.210")]
}
let (redisFS, redisEnv) = try await rootfs("redis", "docker.io/library/redis:7-alpine")
let (pgFS, pgEnv) = try await rootfs("postgres", "docker.io/library/postgres:17-alpine")
let (bbFS, _) = try await rootfs("busybox", "docker.io/library/busybox:1.37")
try await pod.addContainer("redis", rootfs: redisFS) { c in
    c.process.arguments = ["redis-server", "--save", "", "--protected-mode", "no"]; c.process.environmentVariables = redisEnv
}
try await pod.addContainer("postgres", rootfs: pgFS) { c in
    c.process.arguments = ["docker-entrypoint.sh", "postgres"]
    c.process.environmentVariables = pgEnv + ["POSTGRES_PASSWORD=x", "PGDATA=/var/lib/postgresql/data/pg"]
}
try await pod.addContainer("busybox", rootfs: bbFS) { c in c.process.arguments = ["sleep", "3600"] }
let t0 = Date()
try await pod.create()
for n in ["redis", "postgres", "busybox"] { try await pod.startContainer(n) }
print("pod 已启动 \(String(format: "%.1f", Date().timeIntervalSince(t0)))s")


@MainActor func run(_ cid: String, _ argv: [String]) async -> String {
    let tag = UUID().uuidString.prefix(8)
    let out = Buf()
    do {
        let p = try await pod.execInContainer(cid, processID: "x\(tag)") { c in c.arguments = argv; c.stdout = out; c.stderr = out }
        try await p.start(); let st = try await p.wait(); try await p.delete()
        return "exit=\(st.exitCode) \(out.text.prefix(120))"
    } catch { return "错误: \(error)" }
}
try await Task.sleep(nanoseconds: 6_000_000_000)
print("[服务都在跑] redis-cli ping →", await run("redis", ["redis-cli", "ping"]))
print("[服务都在跑] pg_isready →", await run("postgres", ["pg_isready", "-h", "127.0.0.1"]))
print("[共享网络] busybox 连 127.0.0.1:6379 →", await run("busybox", ["nc", "-z", "-w", "2", "127.0.0.1", "6379"]))
print("[共享网络] busybox 连 127.0.0.1:5432 →", await run("busybox", ["nc", "-z", "-w", "2", "127.0.0.1", "5432"]))
print("[端口冲突] busybox 再监听 6379（exit=1 表示被占）→", await run("busybox", ["timeout", "2", "nc", "-l", "-p", "6379"]))
print("[IP] busybox ip addr →", await run("busybox", ["sh", "-c", "ip -4 addr show | grep inet | tr '\\n' ' '"]))
print("[出网] busybox 连 1.1.1.1:80 →", await run("busybox", ["nc", "-z", "-w", "3", "1.1.1.1", "80"]))
print("[到宿主机] busybox 连网关 192.168.64.1:22 →", await run("busybox", ["nc", "-z", "-w", "2", "192.168.64.1", "22"]))

// 环境 B：单独一个虚拟机跑 redis
let (redisBFS, _) = try await rootfs("redis-b", "docker.io/library/redis:7-alpine")
let b = try LinuxContainer("env-b", rootfs: redisBFS, vmm: vmm, vm: VMResources(cpus: 2, memoryInBytes: 1024 * 1024 * 1024)) { c in
    c.process.arguments = ["redis-server", "--save", "", "--protected-mode", "no"]; c.process.environmentVariables = redisEnv
    c.interfaces = [try nat("192.168.64.211")]
}
try await b.create(); try await b.start()
try await Task.sleep(nanoseconds: 8_000_000_000)
let bOut = Buf()
let bp = try await b.exec("ping-b") { c in c.arguments = ["redis-cli", "ping"]; c.stdout = bOut }
try await bp.start(); _ = try await bp.wait(); try await bp.delete()
print("[环境 B 自己] redis-cli ping →", bOut.text)
print("[跨虚拟机] 环境 A 连环境 B 192.168.64.211:6379 →", await run("busybox", ["nc", "-z", "-w", "2", "192.168.64.211", "6379"]))

print("READY 宿主机可测 192.168.64.210 和 .211，等待 \(hold)s")
try await Task.sleep(nanoseconds: hold * 1_000_000_000)

// pod 里停掉一个服务再起
try await pod.stopContainer("redis")
do { try await pod.startContainer("redis"); print("[单服务重启] 同名直接 start：成功") }
catch { print("[单服务重启] 同名直接 start：失败 \(error)") }
do {
    try await pod.addContainer("redis-again", rootfs: redisFS) { c in
        c.process.arguments = ["redis-server", "--save", "", "--protected-mode", "no"]; c.process.environmentVariables = redisEnv
    }
    let t1 = Date()
    try await pod.startContainer("redis-again")
    try await Task.sleep(nanoseconds: 1_000_000_000)
    print("[单服务重启] 换名字重新加入：\(String(format: "%.1f", Date().timeIntervalSince(t1)))s，ping →", await run("redis-again", ["redis-cli", "ping"]))
} catch { print("[单服务重启] 换名字重新加入：失败 \(error)") }

try await b.stop()
try await pod.stop()
print("全部停止")
