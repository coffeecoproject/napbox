// 原型：一个 LinuxPod（一个虚拟机）里跑多个服务，测内存占用。
// 用法：PodProto <工作目录> <内核路径> <秒数> 服务名...（busybox / redis / postgres）
import Containerization
import ContainerizationOCI
import Foundation

setvbuf(stdout, nil, _IOLBF, 0)
let args = CommandLine.arguments
let root = URL(fileURLWithPath: args[1])
let kernelPath = args[2]
let holdSeconds = UInt64(args[3])!
let services = Array(args.dropFirst(4))

let images: [String: (ref: String, argv: [String], env: [String])] = [
    "busybox": ("docker.io/library/busybox:1.37", ["sleep", "3600"], []),
    "redis": ("docker.io/library/redis:7-alpine", ["redis-server", "--save", ""], []),
    "postgres": ("docker.io/library/postgres:17-alpine", ["docker-entrypoint.sh", "postgres"],
                 ["POSTGRES_PASSWORD=x", "PGDATA=/var/lib/postgresql/data/pg"]),
]

let contentStore = try LocalContentStore(path: root.appending(path: "content"))
let store = try ImageStore(path: root, contentStore: contentStore)
let platform = Platform(arch: "arm64", os: "linux", variant: "v8")

func image(_ ref: String) async throws -> Containerization.Image {
    if let found = try? await store.get(reference: ref) { return found }
    return try await store.pull(reference: ref, platform: platform)
}

let initImage = try await store.getInitImage(reference: "ghcr.io/apple/containerization/vminit:0.53.0")
let initPath = root.appending(path: "init.block")
try? FileManager.default.removeItem(at: initPath)
let initfs = try await initImage.initBlock(at: initPath, for: .linuxArm)
let vmm = VZVirtualMachineManager(
    kernel: Kernel(path: URL(fileURLWithPath: kernelPath), platform: .linuxArm),
    initialFilesystem: initfs
)

let pod = try LinuxPod("proto", vmm: vmm, vm: VMResources(cpus: 4, memoryInBytes: 2048 * 1024 * 1024)) { _ in }
for name in services {
    let spec = images[name]!
    let img = try await image(spec.ref)
    let path = root.appending(path: "\(name).ext4")
    try? FileManager.default.removeItem(at: path)
    let rootfs = try await EXT4Unpacker(capacityInBytes: 2 * 1024 * 1024 * 1024).unpack(img, for: platform, at: path)
    let baseEnv = try await img.config(for: platform).config?.env ?? []
    try await pod.addContainer(name, rootfs: rootfs) { config in
        config.process.arguments = spec.argv
        config.process.environmentVariables = baseEnv + spec.env
        config.memoryInBytes = 1024 * 1024 * 1024
    }
}
try await pod.create()
for name in services { try await pod.startContainer(name) }
print("started \(services) pid=\(ProcessInfo.processInfo.processIdentifier)")
try await Task.sleep(nanoseconds: holdSeconds * 1_000_000_000)
try await pod.stop()
print("stopped")
