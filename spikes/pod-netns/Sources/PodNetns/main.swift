// 实验：同一台虚拟机里，两个服务都监听 80，各有各的地址，按名字互相访问。
// 用法：PodNetns <工作目录> <内核路径> <模式> <nsrt 路径> <runc 路径>
// 模式：
//   vmexec   — 现在 napbox 的做法：苹果自带的启动器，所有容器共用虚拟机的网络（对照组）
//   runc     — 换成 runc 启动，但网络还是共用（单独看"换启动器"这件事的代价）
//   isolated — runc 启动，两个服务各有自己的网络（要验证的做法）
// 工作目录里要有 images（镜像仓库的副本）。
import Containerization
import ContainerizationEXT4
import ContainerizationExtras
import ContainerizationOCI
import Foundation
import SystemPackage

setvbuf(stdout, nil, _IOLBF, 0)
let args = CommandLine.arguments
let work = URL(fileURLWithPath: args[1])
let kernelPath = args[2]
let mode = args[3]
let nsrtPath = args[4]
let runcPath = args[5]
precondition(["vmexec", "runc", "isolated"].contains(mode))
let isolated = mode == "isolated"

final class Buf: Writer, @unchecked Sendable {
    var data = Data()
    func write(_ d: Data) throws { data.append(d) }
    func close() throws {}
    var text: String { String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "" }
}

func ms(_ since: Date) -> String { String(format: "%.0f 毫秒", Date().timeIntervalSince(since) * 1000) }

func shell(_ argv: [String]) -> String {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: argv[0])
    p.arguments = Array(argv.dropFirst())
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = FileHandle.nullDevice
    do { try p.run() } catch { return "" }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return String(data: data, encoding: .utf8) ?? ""
}

func vmProcesses() -> Set<String> {
    Set(shell(["/usr/bin/pgrep", "-f", "com.apple.Virtualization.VirtualMachine"]).split(separator: "\n").map(String.init))
}

// ---- 镜像和根文件系统 ----
let images = work.appending(path: "images")
let store = try ImageStore(path: images, contentStore: try LocalContentStore(path: images.appending(path: "content")))
let platform = Platform(arch: "arm64", os: "linux", variant: "v8")
let run = work.appending(path: "run-\(mode)")
try? FileManager.default.removeItem(at: run)
try FileManager.default.createDirectory(at: run, withIntermediateDirectories: true)

func rootfs(_ name: String, _ ref: String) async throws -> (Containerization.Mount, [String]) {
    let img = try await store.get(reference: ref)
    let path = run.appending(path: "\(name).ext4")
    let fs = try await EXT4Unpacker(capacityInBytes: 2 * 1024 * 1024 * 1024).unpack(img, for: platform, at: path)
    return (fs, try await img.config(for: platform).config?.env ?? [])
}

let bridge = "nbx0"
let gateway = "10.88.0.1"
let addresses = ["web-a": "10.88.0.11", "web-b": "10.88.0.12"]

/// 装着 nsrt、runc 和 net.json 的根文件系统。它在虚拟机里挂在 /run/container/rt/rootfs，
/// 苹果的 vminitd 就从那里把 nsrt 当 runc 叫。
/// rt 这个容器只加不启动：第一次实验启动过它，结果整个停掉时框架按随机顺序停容器，rt 一停它的盘就被卸掉，
/// 后面的容器找不到 runc，每个白等 3 秒。没启动过的容器，框架停的时候不碰，盘一直挂到虚拟机关掉。
func runtimeRootfs() throws -> Containerization.Mount {
    let path = run.appending(path: "rt.ext4")
    let formatter = try EXT4.Formatter(FilePath(path.path), minDiskSize: 64 * 1024 * 1024)
    for dir in ["/etc", "/proc", "/sys", "/dev", "/run"] {
        try formatter.create(path: FilePath(dir), mode: EXT4.Inode.Mode(.S_IFDIR, 0o755))
    }
    try formatter.create(path: FilePath("/tmp"), mode: EXT4.Inode.Mode(.S_IFDIR, 0o1777))
    let config: [String: Any] = ["bridge": bridge, "gateway": gateway, "prefix": 24, "containers": isolated ? addresses : [:]]
    let files: [(String, Data, UInt16)] = [
        ("/nsrt", try Data(contentsOf: URL(fileURLWithPath: nsrtPath)), 0o755),
        ("/runc", try Data(contentsOf: URL(fileURLWithPath: runcPath)), 0o755),
        ("/net.json", try JSONSerialization.data(withJSONObject: config), 0o644),
    ]
    for (name, content, perm) in files {
        let stream = InputStream(data: content)
        stream.open()
        defer { stream.close() }
        try formatter.create(path: FilePath(name), mode: EXT4.Inode.Mode(.S_IFREG, perm), buf: stream)
    }
    try formatter.close()
    return .block(format: "ext4", source: path.path, destination: "/", options: [])
}

let rtFS = try runtimeRootfs()
let (toolsFS, toolsEnv) = try await rootfs("tools", "docker.io/library/alpine:3.20")
let (aFS, nodeEnv) = try await rootfs("web-a", "docker.io/library/node:22-alpine")
let (bFS, _) = try await rootfs("web-b", "docker.io/library/node:22-alpine")

// ---- 虚拟机 ----
let initImage = try await store.getInitImage(reference: "ghcr.io/apple/containerization/vminit:0.53.0")
let initfs = try await initImage.initBlock(at: run.appending(path: "init.block"), for: .linuxArm)
let vmm = VZVirtualMachineManager(kernel: Kernel(path: URL(fileURLWithPath: kernelPath), platform: .linuxArm), initialFilesystem: initfs)

// 共用网络时两个服务没法都听 80，对照组里 web-b 用 8081
let ports = ["web-a": 80, "web-b": isolated ? 80 : 8081]
var hosts = Hosts.default
for name in ["web-a", "web-b"] {
    hosts.entries.append(.init(ipAddress: isolated ? addresses[name]! : "127.0.0.1", hostnames: [name]))
}
let finalHosts = hosts

let before = vmProcesses()
let pod = try LinuxPod("netns-\(mode)", vmm: vmm, vm: VMResources(cpus: 4, memoryInBytes: 2048 * 1024 * 1024)) { c in
    c.interfaces = [NATInterface(ipv4Address: try CIDRv4("192.168.64.120/24"), ipv4Gateway: try IPv4Address("192.168.64.1"))]
    c.dns = DNS(nameservers: ["192.168.64.1"])
    c.hosts = finalHosts
    c.bootLog = .file(path: run.appending(path: "boot.log"))
    if mode != "vmexec" { c.ociRuntimePath = "/run/container/rt/rootfs/nsrt" }
}
try await pod.addContainer("rt", rootfs: rtFS) { c in
    c.process.arguments = ["/nsrt", "hold"]
    c.memoryInBytes = 256 * 1024 * 1024
}
try await pod.addContainer("tools", rootfs: toolsFS) { c in
    c.process.arguments = ["sleep", "3600"]
    c.process.environmentVariables = toolsEnv
    c.mounts = LinuxContainer.defaultMounts() + [.any(type: "none", source: "/proc", destination: "/vmproc", options: ["bind"])]
}
// 宿主机的一个目录挂进 web-a：换了启动器以后，源码挂载这条路还通不通
let src = run.appending(path: "src")
try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
try "宿主机写的".write(to: src.appending(path: "from-host.txt"), atomically: true, encoding: .utf8)
let server = "require('http').createServer((q,s)=>s.end(process.env.NAME+'\\n')).listen(+process.env.PORT)"
for (name, fs) in [("web-a", aFS), ("web-b", bFS)] {
    try await pod.addContainer(name, rootfs: fs) { c in
        c.process.arguments = ["node", "-e", server]
        c.process.environmentVariables = nodeEnv + ["NAME=我是 \(name)", "PORT=\(ports[name]!)"]
        if name == "web-a" { c.mounts = LinuxContainer.defaultMounts() + [.share(source: src.path, destination: "/src", options: [])] }
    }
}

/// tools 容器里看虚拟机根目录的路径（它挂了虚拟机的 /proc）：在共用网络那一侧运行 nsrt 用
let nsrtInVM = "/vmproc/1/root/run/container/rt/rootfs/nsrt"

@MainActor func exec(_ cid: String, _ argv: [String], root: Bool = false) async -> (code: Int32, text: String) {
    let out = Buf()
    do {
        let p = try await pod.execInContainer(cid, processID: "x\(UUID().uuidString.prefix(8))") { c in
            c.arguments = argv
            c.stdout = out
            c.stderr = out
            if root { c.capabilities = .allCapabilities }
        }
        try await p.start()
        let st = try await p.wait()
        try await p.delete()
        return (st.exitCode, out.text)
    } catch { return (-1, "错误: \(error)") }
}
@MainActor func show(_ title: String, _ cid: String, _ argv: [String], root: Bool = false) async {
    let r = await exec(cid, argv, root: root)
    let text = r.text.contains("\n") ? "\n    " + r.text.replacingOccurrences(of: "\n", with: "\n    ") : r.text
    print("\(title) → 退出码 \(r.code) \(text)")
}
func get(_ url: String) -> [String] { ["wget", "-qO-", "-T", "3", url] }

print("==== 模式 \(mode) ====")
var t = Date()
try await pod.create()
print("[时间] 虚拟机起来：\(ms(t))")
let vmPID = vmProcesses().subtracting(before)
let total = Date()
for name in ["tools", "web-a", "web-b"] {
    t = Date()
    try await pod.startContainer(name)
    print("[时间] 启动 \(name)：\(ms(t))")
}
for name in ["web-a", "web-b"] {
    var ready = false
    for _ in 0..<100 where !ready {
        ready = await exec(name, get("http://127.0.0.1:\(ports[name]!)/")).code == 0
        if !ready { try await Task.sleep(nanoseconds: 50_000_000) }
    }
    print("[时间] \(name) 能答话（从开始启动容器算起）：\(ms(total))\(ready ? "" : "（没等到）")")
}

for name in ["web-a", "web-b"] {
    await show("[\(name) 自己] 连 127.0.0.1:\(ports[name]!)", name, get("http://127.0.0.1:\(ports[name]!)/"))
    await show("[\(name) 的地址]", name, ["sh", "-c", "ip -4 -o addr show | awk '{print $2, $4}' | tr '\\n' ' '"])
}
await show("[按名字] web-a 连 http://web-b:\(ports["web-b"]!)", "web-a", get("http://web-b:\(ports["web-b"]!)/"))
await show("[按名字] web-b 连 http://web-a:\(ports["web-a"]!)", "web-b", get("http://web-a:\(ports["web-a"]!)/"))
await show("[退出码] sh -c 'exit 7'", "web-a", ["sh", "-c", "exit 7"])

await show("[挂载] web-a 读宿主机写的文件", "web-a", ["cat", "/src/from-host.txt"])
await show("[挂载] web-a 往里写一个文件", "web-a", ["sh", "-c", "echo 容器写的 > /src/from-container.txt"])
print("[挂载] 宿主机上看到：\((try? String(contentsOf: src.appending(path: "from-container.txt"), encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "没有")")

let reach = isolated ? addresses : ["web-a": "127.0.0.1", "web-b": "127.0.0.1"]
for name in ["web-a", "web-b"] {
    await show("[转发端口那条路] 虚拟机自己连 \(reach[name]!):\(ports[name]!)", "tools", get("http://\(reach[name]!):\(ports[name]!)/"))
}
await show("[查监听] 虚拟机自己的 /proc/net/tcp 里在监听的端口（十六进制，0050 是 80）", "tools",
           ["sh", "-c", "awk '$4==\"0A\"{print $2}' /proc/net/tcp /proc/net/tcp6 | tr '\\n' ' '"])
for name in ["web-a", "web-b"] {
    await show("[查监听] 从 \(name) 的主进程那里看", "tools",
               ["sh", "-c", "p=$(grep -l '/\(name)$' /vmproc/[0-9]*/cgroup 2>/dev/null | head -1); p=${p%/cgroup}; echo \"进程 ${p#/vmproc/}：$(awk '$4==\"0A\"{print $2}' $p/net/tcp $p/net/tcp6 | tr '\\n' ' ')\""], root: true)
}

await show("[出网] web-a 查域名 example.com", "web-a", ["sh", "-c", "nslookup example.com 2>&1 | grep -c Address"])
await show("[出网] web-a 连 1.1.1.1:80", "web-a", ["nc", "-z", "-w", "3", "1.1.1.1", "80"])
await show("[到宿主机] web-a 连网关 192.168.64.1:22", "web-a", ["nc", "-z", "-w", "2", "192.168.64.1", "22"])

if isolated {
    await show("[出网规则] 切到不许出网", "tools", [nsrtInVM, "egress-none", bridge], root: true)
    await show("[出网规则] web-a 连 1.1.1.1:80（应该失败）", "web-a", ["nc", "-z", "-w", "3", "1.1.1.1", "80"])
    await show("[出网规则] web-a 连网关 192.168.64.1:22（应该失败）", "web-a", ["nc", "-z", "-w", "2", "192.168.64.1", "22"])
    await show("[出网规则] web-a 连 web-b（应该还通）", "web-a", get("http://web-b:80/"))
    await show("[出网规则] 虚拟机自己连 web-a（应该还通）", "tools", get("http://\(addresses["web-a"]!):80/"))
    await show("[出网规则] 切回可以出网", "tools", [nsrtInVM, "egress-open", bridge], root: true)
    await show("[出网规则] web-a 连 1.1.1.1:80（应该又通了）", "web-a", ["nc", "-z", "-w", "3", "1.1.1.1", "80"])
}
if mode != "vmexec" {
    await show("[垫层日志]", "tools", ["cat", "/vmproc/1/root/run/nsrt.log"], root: true)
    await show("[虚拟机里的网卡]", "tools", ["sh", "-c", "ip -o link | awk '{print $2, $9}' | tr '\\n' ' '"])
}
await show("[内核] 相关开关", "tools", ["sh", "-c", "zcat /proc/config.gz 2>/dev/null | grep -E '^CONFIG_(NET_NS|VETH|BRIDGE|BRIDGE_NETFILTER|NF_NAT|NFT_MASQ|NF_TABLES)=' | tr '\\n' ' ' || echo 没有 /proc/config.gz"])

try await Task.sleep(nanoseconds: 5_000_000_000)
await show("[内存] 虚拟机里", "tools", ["sh", "-c", "grep -E 'MemTotal|MemAvailable' /proc/meminfo | tr -s ' ' | tr '\\n' ' '"])
for pid in vmPID.sorted() {
    let line = shell(["/usr/bin/footprint", pid]).split(separator: "\n").first { $0.contains("Footprint:") } ?? "量不到"
    print("[内存] 宿主机上这台虚拟机的进程 \(pid)：\(line.trimmingCharacters(in: .whitespaces))")
}

t = Date()
do {
    try await pod.stopContainer("web-b")
    print("[停一个服务] web-b：\(ms(t))")
    await show("[停一个服务] web-a 还在", "web-a", get("http://127.0.0.1:80/"))
    if isolated { await show("[停一个服务] 虚拟机里的网卡（web-b 那根应该没了）", "tools", ["sh", "-c", "ip -o link | awk '{print $2}' | tr '\\n' ' '"]) }
} catch { print("[停一个服务] 失败：\(error)") }
t = Date()
try await pod.stop()
print("[时间] 整个停掉：\(ms(t))")
