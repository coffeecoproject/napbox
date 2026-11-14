// 一个服务的容器怎么配：命令、环境变量、工作目录、挂载、内存上限，按 Docker 的规则合并镜像配置和 compose。
import Containerization
import ContainerizationOCI
import Foundation
import NapboxCore
import NapboxProtocol

/// napbox run 在前台跑的那个服务：标准输入从命令行转过来，输出除了写日志也原样转回去。
public struct ForegroundService: Sendable {
    public let service: String
    /// 结束时关掉服务的标准输入
    public let stdin: AsyncStream<Data>
    /// 积压到上限时服务等着（ExecOutput）
    public let output: ExecOutput
    /// 命令行断开了（或超时）：还在准备镜像时就不再往下起
    public let callerGone: CallerGone

    public init(service: String, stdin: AsyncStream<Data>, output: ExecOutput, callerGone: CallerGone) {
        self.service = service
        self.stdin = stdin
        self.output = output
        self.callerGone = callerGone
    }
}

struct ContainerPlan: Sendable {
    let name: String
    let rootfs: Containerization.Mount
    let imageConfig: ImageConfig
    /// 镜像的创建时间。OCI 里这一项可以不写
    let imageCreated: String?
    let arguments: [String]
    let environment: [String]
    let workingDirectory: String
    let mounts: [Containerization.Mount]
    /// 只读挂载的宿主机目录在容器里的路径
    let readOnlySources: [String]
    let memoryBytes: UInt64
    let useInit: Bool
    /// 停服务时发的信号：镜像的 STOPSIGNAL（比如 postgres 是 SIGINT），没写的是 SIGTERM，和 Docker 一样
    let stopSignal: Signal
    let log: LogFile
    /// 这个服务是 napbox run 在前台跑的那个时有
    let foreground: ForegroundService?

    /// - portVariables：这个环境的端口变量，换掉 environment 里引用的（PortReferences）
    /// - freshRootfs：这次起环境新解包出来的根文件系统，同一个镜像的服务从它克隆（EnvironmentLayout.rootfs）
    /// - trace：记下根文件系统是怎么来的
    init(service s: Service, image: Containerization.Image, layout: EnvironmentLayout, portVariables: [String: String],
         freshRootfs: inout [String: URL], trace: RunTrace, foreground: ForegroundService? = nil) async throws(NapboxError) {
        name = s.name
        self.foreground = foreground
        // up 在登记之前都查过一遍（Runtime.checkHostMounts、prepareImages）；唤醒、reset、按 restart 重启不经过那里，
        // 宿主机上的文件可能已经变了
        try s.checkHostMounts()
        let settings = try await ImageSettings(service: s, image: image)
        imageConfig = settings.config
        imageCreated = settings.created
        arguments = settings.arguments
        stopSignal = settings.stopSignal
        let prepared = try await layout.rootfs(s.name, image: image, definition: try Self.definition(s), fresh: &freshRootfs)
        rootfs = prepared.mount
        trace.rootfs(s.name, prepared.source)

        // 按第一个 = 拆；没有名字的条目（空的、= 开头的）不是环境变量，不要
        var env: [(String, String)] = (imageConfig.env ?? []).compactMap { kv in
            let name = kv.prefix { $0 != "=" }
            return name.isEmpty ? nil : (String(name), String(kv.dropFirst(name.count + 1)))
        }
        for (k, raw) in s.environment.sorted(by: { $0.key < $1.key }) {
            let v = PortReferences.resolve(raw, portVariables)
            if let i = env.firstIndex(where: { $0.0 == k }) { env[i].1 = v } else { env.append((k, v)) }
        }
        environment = env.map { "\($0)=\($1)" }
        workingDirectory = s.workingDir ?? imageConfig.workingDir.flatMap { $0.isEmpty ? nil : $0 } ?? "/"
        memoryBytes = s.memoryBytes
        useInit = s.initProcess

        var extra: [Containerization.Mount] = []
        var readOnlySources: [String] = []
        for v in s.volumes {
            switch v.source {
            case .named(let volume):
                extra.append(.sharedMount(name: volume, destination: v.target, options: v.readOnly ? ["ro"] : []))
            case .bind(let path), .secret(let path):
                // 和 Docker 一样：volumes 的来源不存在时建成目录（secrets 的文件不建，checkHostMounts 查过了）。来源是单个文件时，
                // 框架共享它所在的目录，再把这个文件绑定进容器（Containerization 的 FileMount；虚拟机只能共享目录）
                if case .bind = v.source, !FileManager.default.fileExists(atPath: path) {
                    try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
                }
                // 只读做在容器这一层，不做在虚拟机的共享上（和 Docker 一样靠挂载，服务没有权限重新挂载）：框架里同一个目录
                // 只共享一次，只读的话网络小容器也发不出文件变化通知
                extra.append(.share(source: path, destination: v.target, options: []))
                if v.readOnly { readOnlySources.append(v.target) }
            }
        }
        self.readOnlySources = readOnlySources
        for t in s.tmpfs {
            let parts = t.split(separator: ":", maxSplits: 1)
            let options = parts.count > 1 ? parts[1].split(separator: ",").map(String.init) : []
            extra.append(.any(type: "tmpfs", source: "tmpfs", destination: String(parts[0]), options: options))
        }
        var base = LinuxContainer.defaultMounts()
        if let shm = s.shmSizeBytes, let i = base.firstIndex(where: { $0.destination == "/dev/shm" }) {
            base[i] = .any(type: "tmpfs", source: "tmpfs", destination: "/dev/shm", options: ["nosuid", "noexec", "nodev", "mode=1777", "size=\(shm)"])
        }
        mounts = base + extra

        let log = LogFile(url: layout.log(s.name))
        try? log.write(Data("----- napbox 启动 \(ISO8601DateFormatter().string(from: Date())) -----\n".utf8))
        self.log = log
    }

    /// 服务定义的固定写法，用来判断根文件系统能不能沿用
    static func definition(_ s: Service) throws(NapboxError) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        // 同步规则不影响容器本身，改规则不用重新解包（容器里已经同步进去的也还在）
        var definition = s
        definition.watch = []
        do {
            return String(decoding: try encoder.encode(definition), as: UTF8.self)
        } catch {
            throw NapboxError(.internalError, "\(s.name) 的定义编码失败：\(error)")
        }
    }

    func configure(_ c: inout LinuxPod.ContainerConfiguration) {
        c.process = LinuxProcessConfiguration(from: imageConfig)
        c.process.arguments = arguments
        c.process.environmentVariables = environment
        c.process.workingDirectory = workingDirectory
        if let foreground {
            c.process.stdin = StreamReader(stream: foreground.stdin)
            c.process.stdout = ForegroundWriter(log: log, forward: OutputWriter(stream: .stdout, output: foreground.output))
            c.process.stderr = ForegroundWriter(log: log, forward: OutputWriter(stream: .stderr, output: foreground.output))
        } else {
            c.process.stdout = log
            c.process.stderr = log
        }
        c.memoryInBytes = memoryBytes
        c.useInit = useInit
        c.mounts = mounts
        c.readonlyPaths += readOnlySources
    }
}

/// 镜像的配置和 compose 合起来才知道成不成立的几项。不用起虚拟机就能算：up 在登记环境之前先算一遍
/// （Runtime.prepareImages），不成立时不留下没用的登记。
struct ImageSettings: Sendable {
    let config: ImageConfig
    /// 镜像的创建时间。OCI 里这一项可以不写
    let created: String?
    let arguments: [String]
    /// 停服务时发的信号：镜像的 STOPSIGNAL（比如 postgres 是 SIGINT），没写的是 SIGTERM，和 Docker 一样
    let stopSignal: Signal

    init(service s: Service, image: Containerization.Image) async throws(NapboxError) {
        do {
            let config = try await image.config(for: linuxArm64)
            self.config = config.config ?? ImageConfig()
            created = config.created
        } catch {
            throw NapboxError(.imageUnavailable, "\(s.name) 的镜像配置读不了：\(error)")
        }
        // Docker 的规则：compose 写了 entrypoint 时，镜像的 CMD 不再使用
        let entrypoint = s.entrypoint ?? config.entrypoint ?? []
        let command = s.command ?? (s.entrypoint == nil ? config.cmd ?? [] : [])
        arguments = entrypoint + command
        guard !arguments.isEmpty else {
            throw NapboxError(.composeInvalid, "\(s.name) 没有要执行的命令：镜像里没有 ENTRYPOINT/CMD，compose 里也没写 command")
        }
        if let name = config.stopSignal, !name.isEmpty {
            do { stopSignal = try Signal(name) } catch {
                throw NapboxError(.serviceFailed, "\(s.name) 的镜像指定的停止信号 STOPSIGNAL \(name) 不认识")
            }
        } else {
            stopSignal = .term
        }
    }
}

extension Service {
    /// 挂载的来源在宿主机上不成立的两种情况。只看宿主机上的文件，不用等：up 在构建、登记环境之前先查
    /// （Runtime.checkHostMounts），不留下没用的登记。
    func checkHostMounts() throws(NapboxError) {
        for v in volumes {
            guard let path = v.source.hostPath else { continue }
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir) else {
                // secrets 的文件都得在：和普通挂载不一样，不存在时不建，报错（和 Docker 一样）
                if case .secret = v.source { throw NapboxError(.composeInvalid, "\(name) 的 secrets 文件 \(path) 不存在") }
                continue
            }
            guard !isDir.boolValue else { continue }
            // 来源是单个文件，它所在的目录又整个挂了：框架 0.53.0 在这种组合下会把整目录那条挂载丢掉（LinuxPod 启动容器时
            // 按共享的标签过滤，两条的标签一样），服务起得来但目录没挂上。与其悄悄少一条挂载，不如直接说
            let parent = (realDirectory(path) as NSString).deletingLastPathComponent
            if volumes.contains(where: { $0.source.hostPath.map { realDirectory($0) == parent } ?? false }) {
                throw NapboxError(.composeUnsupported, "\(name) 同时挂了目录 \(parent) 和它里面的文件 \(path)：同一个服务里这样挂 napbox 现在不支持")
            }
        }
    }
}

/// 前台服务的输出：照常写进日志，再原样转给命令行
private final class ForegroundWriter: Writer, Sendable {
    let log: LogFile
    let forward: OutputWriter

    init(log: LogFile, forward: OutputWriter) {
        self.log = log
        self.forward = forward
    }

    func write(_ data: Data) throws {
        try log.write(data)
        try forward.write(data)
    }

    func close() throws {}
}
