// 构建镜像（compose 的 build）：在一个专用虚拟机里跑 Docker 用的构建引擎 BuildKit，
// 结果导回 napbox 的镜像库。虚拟机按需开、构建完就关，所有环境共用一份构建缓存。
// 缓存卷同一时间只能挂在一个虚拟机上，要构建的目录也只能在开机时共享进去，所以一次只跑一个构建，其余排队。
import Containerization
import ContainerizationEXT4
import ContainerizationExtras
import ContainerizationOCI
import Foundation
import NapboxCore
import NapboxProtocol

actor ImageBuilder {
    struct Request: Sendable {
        /// 构建结果的镜像名
        var reference: String
        var build: Build
        /// 构建成哪个架构的镜像
        var platform: ImagePlatform
        /// 报错时说是哪个服务
        var service: String
        /// 完整的构建输出写到这里，每次构建覆盖
        var log: URL
        /// 怎么碰宿主机上的文件：Dockerfile 和忽略文件按它读，context 按它共享进构建虚拟机（HostShares）
        var access: HostAccess
    }

    static let engineReference = "docker.io/moby/buildkit:v0.34.2"
    static let engineRootfsBytes: UInt64 = 2 * 1024 * 1024 * 1024
    /// 稀疏文件，写多少占多少。旧缓存由引擎自己按磁盘大小清理
    static let cacheBytes: UInt64 = 32 * 1024 * 1024 * 1024
    /// 只是上限，用多少才占多少，构建完虚拟机就关
    static let memoryBytes: UInt64 = 8 * 1024 * 1024 * 1024
    static let container = "buildkit"
    /// 一次构建最多多久。卡住的构建（比如 RUN 里等不到网络）不能一直挡着后面排队的
    static let buildTimeoutSeconds: Int64 = 3600
    static let engineReadySeconds = 30
    /// 引擎收到 SIGTERM 后等它退出多久
    static let engineExitSeconds: Int64 = 10
    /// 报错时带上构建输出的最后几行
    static let errorTailLines = 40

    private let directory: URL
    /// napbox-guard：构建引擎启动后用它查网关（gateway 子命令）
    private let guardBinary: URL
    /// 建构建缓存那块盘
    private let disk: DataDisk
    private let queue = Slots(limit: 1)
    /// 正在跑的构建虚拟机：napboxd 退出时要让引擎先退出再关（stopEngine）
    private var active: LinuxPod?
    private var stopping = false

    init(directory: URL, guardBinary: URL, disk: DataDisk) {
        self.directory = directory
        self.guardBinary = guardBinary
        self.disk = disk
    }

    private var exiting: NapboxError { NapboxError(.daemonUnavailable, "napboxd 正在退出") }

    /// 排队跑一次构建，返回导入镜像库后的镜像
    func build(_ request: Request, store: ImageStore, vmm: VZVirtualMachineManager) async throws(NapboxError) -> Containerization.Image {
        await queue.acquire()
        let result: Result<Containerization.Image, NapboxError>
        do throws(NapboxError) {
            result = .success(try await run(request, store: store, vmm: vmm))
        } catch {
            result = .failure(error)
        }
        await queue.release()
        return try result.get()
    }

    /// napboxd 退出前调用：停掉正在跑的构建，排队的不再开始
    func stop() async {
        stopping = true
        await stopEngine()
    }

    private func run(_ request: Request, store: ImageStore, vmm: VZVirtualMachineManager) async throws(NapboxError) -> Containerization.Image {
        if stopping { throw exiting }
        let dockerfile = try Self.locate(request)
        let engine = try await engineImage(store: store)
        let (rootfs, config) = try await engineRootfs(engine)
        let cache = try cacheVolume()
        let output = try prepareWorkDirectory("output")
        defer { try? FileManager.default.removeItem(at: output) } // napbox 自己的临时目录
        let staged = try stage(dockerfile, context: request.build.context, access: request.access)
        defer { try? FileManager.default.removeItem(at: staged) }
        let logs = try prepareLogs(request)
        defer {
            logs.build.close()
            logs.engine.close()
        }
        if stopping { throw exiting }

        let pod: LinuxPod
        do {
            pod = try await makePod(
                request, dockerfile: staged, rootfs: rootfs, config: config, cache: cache, output: output,
                engineLog: logs.engine, vmm: vmm
            )
            try await pod.create()
        } catch {
            throw NapboxError(.runtimeUnavailable, "创建构建虚拟机失败：\(error)")
        }
        active = pod
        do {
            try await pod.startContainer(Self.container)
        } catch {
            await stopEngine()
            throw NapboxError(.runtimeUnavailable, "构建引擎启动失败：\(error)")
        }
        // 构建跑 RUN 之前对准时钟（不用进容器）。查网关要进容器，等引擎就绪后再做（见 waitForEngine）
        do {
            try await GuestClock.sync(pod)
            try await waitForEngine(logs.engine)
            try await checkGateway(pod)
        } catch {
            await stopEngine()
            throw error
        }
        let failure = await runBuild(request, dockerfile: dockerfile, in: pod, logs: logs)
        await stopEngine()
        if stopping { throw exiting }
        if let failure { throw failure }
        return try await load(request, from: output.appending(path: "layout"), store: store)
    }

    // MARK: - 准备

    private struct Dockerfile {
        var file: URL
        var name: String { file.lastPathComponent }
    }

    /// 上下文和 Dockerfile 都要在：开虚拟机之前就报清楚
    private static func locate(_ request: Request) throws(NapboxError) -> Dockerfile {
        let build = request.build
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: build.context, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw NapboxError(.imageBuildFailed, "\(request.service) 的构建目录 \(build.context) 不存在")
        }
        let file = URL(fileURLWithPath: build.dockerfilePath)
        guard FileManager.default.fileExists(atPath: file.path) else {
            throw NapboxError(.imageBuildFailed, "\(request.service) 的 Dockerfile \(file.path) 不存在")
        }
        return Dockerfile(file: file)
    }

    /// 交给引擎的 Dockerfile 目录：Dockerfile 的副本，加一份 `<Dockerfile 的名字>.dockerignore`。
    /// 引擎先认这份同名的忽略文件，有它就不看构建目录里的 `.dockerignore`，所以内容是项目里生效的那一份
    /// （同样的先后）再加一条 `.napbox`：那是 napbox 自己写在 worktree 里的（ports.json），不进镜像，
    /// `COPY . .` 的缓存也不因为它失效。后面的规则优先，项目的规则放不回来。
    /// 这两样都按 access 读：confine 时不在代码目录以内（比如是指出去的符号链接）就报错
    private func stage(_ dockerfile: Dockerfile, context: String, access: HostAccess) throws(NapboxError) -> URL {
        let staged = try prepareWorkDirectory("dockerfile")
        let ignoreName = "\(dockerfile.name).dockerignore"
        let candidates = [
            dockerfile.file.deletingLastPathComponent().appending(path: ignoreName),
            URL(fileURLWithPath: context).appending(path: ".dockerignore"),
        ]
        func read(_ url: URL) throws(NapboxError) -> Data? {
            do {
                return try access.read(url.path)
            } catch {
                switch error {
                case .outside: throw NapboxError(.pathOutsideDirectory, access.outside(url.path))
                case .unreadable(let reason): throw NapboxError(.imageBuildFailed, "读不了 \(url.path)：\(reason)")
                }
            }
        }
        func write(_ data: Data, to url: URL) throws(NapboxError) {
            do {
                try data.write(to: url)
            } catch {
                throw NapboxError(.imageBuildFailed, "准备 \(dockerfile.file.path) 和忽略规则失败：\(error.localizedDescription)")
            }
        }
        guard let content = try read(dockerfile.file) else {
            throw NapboxError(.imageBuildFailed, "Dockerfile \(dockerfile.file.path) 不存在")
        }
        try write(content, to: staged.appending(path: dockerfile.name))
        var rules = Data()
        for candidate in candidates {
            if let own = try read(candidate) {
                rules = own
                break
            }
        }
        rules.append(Data("\n**/.napbox\n".utf8))
        try write(rules, to: staged.appending(path: ignoreName))
        return staged
    }

    private func engineImage(store: ImageStore) async throws(NapboxError) -> Containerization.Image {
        if let local = try? await store.get(reference: Self.engineReference) { return local }
        do {
            return try await store.pull(reference: Self.engineReference, platform: linuxArm64)
        } catch {
            throw NapboxError(.imageUnavailable, "构建引擎的镜像 \(Self.engineReference) 拉不下来：\(error)")
        }
    }

    /// 引擎的根文件系统，镜像没变就沿用
    private func engineRootfs(_ image: Containerization.Image) async throws(NapboxError) -> (Containerization.Mount, ImageConfig) {
        let path = directory.appending(path: "engine.ext4"), stamp = directory.appending(path: "engine.stamp")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let digest = try await image.descriptor(for: linuxArm64).digest
            let config = try await image.config(for: linuxArm64).config ?? ImageConfig()
            if FileManager.default.fileExists(atPath: path.path), (try? String(contentsOf: stamp, encoding: .utf8)) == digest {
                return (.block(format: "ext4", source: path.path, destination: "/", options: []), config)
            }
            try? FileManager.default.removeItem(at: stamp)
            if FileManager.default.fileExists(atPath: path.path) { try FileManager.default.removeItem(at: path) }
            let mount = try await EXT4Unpacker(capacityInBytes: Self.engineRootfsBytes, journal: EnvironmentLayout.journal)
                .unpack(image, for: linuxArm64, at: path)
            try Data(digest.utf8).write(to: stamp)
            return (mount, config)
        } catch {
            throw NapboxError(.imageUnavailable, "构建引擎的根文件系统准备失败：\(error)")
        }
    }

    private func cacheVolume() throws(NapboxError) -> URL {
        let path = directory.appending(path: "cache.ext4")
        if FileManager.default.fileExists(atPath: path.path) { return path }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try disk.create(at: path, bytes: Self.cacheBytes)
        } catch {
            throw NapboxError(.internalError, "建不了构建缓存卷：\(error)")
        }
        return path
    }

    /// 共享给虚拟机的临时目录（output 放构建结果，dockerfile 放 Dockerfile 和忽略规则）。一次只有一个构建：上次崩溃留下的直接清掉
    private func prepareWorkDirectory(_ name: String) throws(NapboxError) -> URL {
        let path = directory.appending(path: name)
        do {
            if FileManager.default.fileExists(atPath: path.path) { try FileManager.default.removeItem(at: path) }
            try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        } catch {
            throw NapboxError(.internalError, "建不了 \(path.path)：\(error.localizedDescription)")
        }
        return path
    }

    private struct Logs {
        var build: LogFile
        var engine: LogFile
    }

    private func prepareLogs(_ request: Request) throws(NapboxError) -> Logs {
        let engine = directory.appending(path: "engine.log")
        do {
            try FileManager.default.createDirectory(at: request.log.deletingLastPathComponent(), withIntermediateDirectories: true)
            for file in [request.log, engine] where FileManager.default.fileExists(atPath: file.path) {
                try FileManager.default.removeItem(at: file)
            }
        } catch {
            throw NapboxError(.internalError, "准备构建日志失败：\(error.localizedDescription)")
        }
        return Logs(build: LogFile(url: request.log), engine: LogFile(url: engine))
    }

    /// 每次换一个地址，见 AddressAllocator.builderAddress
    private func nextAddress() -> String {
        let file = directory.appending(path: "last-address")
        let last = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
        let next = AddressAllocator.builderAddress(after: last)
        try? Data(next.utf8).write(to: file)
        return next
    }

    private func makePod(_ request: Request, dockerfile: URL, rootfs: Containerization.Mount, config: ImageConfig, cache: URL,
                         output: URL, engineLog: LogFile, vmm: VZVirtualMachineManager) async throws -> LinuxPod {
        let ip = nextAddress()
        let cidr = try CIDRv4("\(ip)/24")
        let gateway = try IPv4Address(AddressAllocator.gateway)
        let mac = try MACAddress(try AddressAllocator.macAddress(for: ip))
        let cpus = ProcessInfo.processInfo.activeProcessorCount
        let guardProgram = guardBinary
        // context 只读：confine 时共享的是代码目录本身（只读），context 在虚拟机里从它绑定
        let shares = HostShares(request.access, readOnly: true)
        let context = [try shares.mount(request.build.context, destination: "/ctx")] + (shares.root(destination: "/napbox-confined").map { [$0] } ?? [])
        let pod = try LinuxPod("napbox-builder", vmm: vmm, vm: VMResources(cpus: cpus, memoryInBytes: Self.memoryBytes)) { c in
            c.interfaces = [NATInterface(ipv4Address: cidr, ipv4Gateway: gateway, macAddress: mac)]
            c.dns = DNS(nameservers: [AddressAllocator.gateway])
            c.volumes = [LinuxPod.PodVolume(name: "cache", source: .diskImage(path: cache, readOnly: false), format: "ext4")]
        }
        try await pod.addContainer(Self.container, rootfs: rootfs) { c in
            c.process = LinuxProcessConfiguration(from: config)
            // 先删掉引擎自带的 x86 模拟器（qemu）再启动。构建 linux/amd64 的镜像时，RUN 里的 x86 程序该由虚拟机里登记好的
            // Rosetta 执行；可是引擎启动时自己试一遍（在 chroot 里跑测试程序）认不出 Rosetta，就改用自带的 qemu，
            // 它慢，有的程序在里面直接崩（比如 tsc 段错误）。自带的没了，RUN 就直接执行，交给 Rosetta。
            // 苹果的 container 也是这么做的。这块盘每次构建都沿用，rm -f 删过了也不报错
            c.process.arguments = ["/bin/sh", "-c", "rm -f /usr/bin/buildkit-qemu-x86_64 && exec buildkitd --addr unix:///run/buildkit/buildkitd.sock"]
            // 引擎自己再起容器跑 RUN，要全部权限和不被遮挡的 /proc、/sys；它和宿主机之间还隔着这个虚拟机
            c.process.capabilities = .allCapabilities
            c.process.stdout = engineLog
            c.process.stderr = engineLog
            c.memoryInBytes = Self.memoryBytes - 256 * 1024 * 1024
            c.maskedPaths = []
            c.readonlyPaths = []
            c.mounts = LinuxContainer.defaultMounts() + [
                .sharedMount(name: "cache", destination: "/var/lib/buildkit", options: []),
            ] + context + [
                .share(source: dockerfile.path, destination: "/dockerfile", options: ["ro"]),
                .share(source: output.path, destination: "/out", options: []),
                .share(source: guardProgram.path, destination: Self.guardPath, options: ["ro"]),
            ]
        }
        return pod
    }

    // MARK: - 构建

    /// 跑 buildctl（引擎已经就绪）。失败时返回错误（这时还要先停虚拟机），成功返回 nil。
    private func runBuild(_ request: Request, dockerfile: Dockerfile, in pod: LinuxPod, logs: Logs) async -> NapboxError? {
        var arguments = [
            "buildctl", "build", "--progress", "plain", "--frontend", "dockerfile.v0",
            "--local", "context=/ctx", "--local", "dockerfile=/dockerfile", "--opt", "filename=\(dockerfile.name)",
            "--opt", "platform=\(request.platform.rawValue)",
        ]
        if let target = request.build.target { arguments += ["--opt", "target=\(target)"] }
        for (key, value) in request.build.args.sorted(by: { $0.key < $1.key }) {
            arguments += ["--opt", "build-arg:\(key)=\(value)"]
        }
        arguments += ["--output", "type=oci,tar=false,dest=/out/layout,name=\(request.reference)"]
        let code: Int32
        do {
            code = try await exec(arguments, in: pod, output: logs.build, timeout: Self.buildTimeoutSeconds)
        } catch {
            return NapboxError(.imageBuildFailed, "\(request.service) 的镜像构建没有完成（最多 \(Self.buildTimeoutSeconds / 60) 分钟）：\(error)\n\(Self.ending(logs.build, request))")
        }
        guard code == 0 else {
            return NapboxError(.imageBuildFailed, "\(request.service) 的镜像构建失败（退出码 \(code)）：\n\(Self.ending(logs.build, request))")
        }
        return nil
    }

    private static func ending(_ log: LogFile, _ request: Request) -> String {
        "\(log.tail(errorTailLines))\n完整输出：\(request.log.path)"
    }

    /// 引擎开始监听时在日志里写的一句（BuildKit 的 serveGRPC），换引擎版本时要核对还在
    static let engineReadyMark = "running server on"

    /// 等引擎就绪：在宿主机上看它的日志，不进容器查。
    /// 引擎启动时会把自己挪进子 cgroup，再在容器这一层打开控制器（镜像设了 BUILDKIT_SETUP_CGROUPV2_ROOT=1）。
    /// 这期间进容器执行命令，虚拟机里先读到的是挪之前的位置，等把新进程放进去时那一层已经不能直接放进程，
    /// 内核报 EBUSY；赶在它挪之前进去的进程还会让它开不了控制器。就绪这一句在挪完之后才写，
    /// 所以第一次进容器执行命令要等到它出现。
    private func waitForEngine(_ log: LogFile) async throws(NapboxError) {
        let mark = Data(Self.engineReadyMark.utf8)
        let deadline = Date().addingTimeInterval(Double(Self.engineReadySeconds))
        while Date() < deadline {
            if stopping { throw exiting }
            // 启动时的日志只有十来行，整份读
            if let written = try? Data(contentsOf: log.url), written.range(of: mark) != nil { return }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        throw NapboxError(.runtimeUnavailable, "构建引擎 \(Self.engineReadySeconds) 秒内没有就绪：\(log.tail(Self.errorTailLines))")
    }

    static let guardPath = "/napbox-guard"

    /// 网关不在构建虚拟机的网络上时，拉镜像和 RUN 里的下载都会卡到超时：先查，直接说清楚
    private func checkGateway(_ pod: LinuxPod) async throws(NapboxError) {
        let output = CaptureWriter()
        let code: Int32
        do {
            code = try await exec([Self.guardPath, "gateway", AddressAllocator.gateway], in: pod, output: output, timeout: 10)
        } catch {
            throw NapboxError(.runtimeUnavailable, "在构建虚拟机里查网关失败：\(error)")
        }
        if code != 0 { throw AddressAllocator.gatewayUnreachable(output.text.isEmpty ? "退出码 \(code)" : output.text) }
    }

    private func exec(_ argv: [String], in pod: LinuxPod, output: any Writer, timeout: Int64) async throws -> Int32 {
        let process = try await pod.execInContainer(Self.container, processID: "build-\(UUID().uuidString.prefix(8))") { c in
            c.arguments = argv
            c.capabilities = .allCapabilities
            c.stdout = output
            c.stderr = output
        }
        defer { Task { try? await process.delete() } }
        try await process.start()
        return try await process.wait(timeoutInSeconds: timeout).exitCode
    }

    /// 让引擎自己退出再关虚拟机。开着 Clash 的 TUN 时，虚拟机带着外网连接被直接关掉后，同一地址再开机可能很久
    /// 连不上走 Clash 的外网，引擎先退出就没有这个问题。
    /// 引擎收到 SIGTERM 后会等还在跑的构建结束（RUN 可能要很久），所以先结束 buildctl：连接断了，引擎就取消构建。
    private func stopEngine() async {
        guard let pod = active else { return }
        active = nil
        _ = try? await exec(["pkill", "buildctl"], in: pod, output: CaptureWriter(), timeout: 5)
        try? await pod.killContainer(Self.container, signal: .term)
        do {
            _ = try await pod.waitContainer(Self.container, timeoutInSeconds: Self.engineExitSeconds)
        } catch {
            print("构建引擎 \(Self.engineExitSeconds) 秒内没有退出，直接关虚拟机：\(error)")
        }
        try? await pod.stop()
    }

    private func load(_ request: Request, from layout: URL, store: ImageStore) async throws(NapboxError) -> Containerization.Image {
        do {
            let loaded = try await store.load(from: layout)
            guard let image = loaded.first(where: { $0.reference == request.reference }) else {
                throw NapboxError(.imageBuildFailed, "\(request.service) 构建好了，但导入后没找到 \(request.reference)，导入的是：\(loaded.map(\.reference).joined(separator: "、"))")
            }
            return image
        } catch let error as NapboxError {
            throw error
        } catch {
            throw NapboxError(.imageBuildFailed, "\(request.service) 构建好了，但导入镜像库失败：\(error)")
        }
    }
}
