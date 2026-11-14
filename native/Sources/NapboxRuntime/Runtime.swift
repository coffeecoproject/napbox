// 用 Containerization 起环境：一个环境一个 LinuxPod，每个服务一个容器，外加一个网络小容器。
import Containerization
import ContainerizationError
import ContainerizationExtras
import ContainerizationOCI
import Foundation
import NapboxCore
import NapboxProtocol
import NIOPosix
import Virtualization

let linuxArm64 = Platform(arch: "arm64", os: "linux", variant: "v8")

public actor Runtime {
    let supportDirectory: URL
    let storage: Storage
    /// 网络小容器的程序（Linux 版 napbox-guard）。直接写进一个根文件系统，不用镜像
    let guardBinary: URL
    let builder: ImageBuilder
    /// 正在做或已经做完的那次准备。同时进来的都等它：各做各的会互相删掉对方刚建的 init.block
    private var preparing: Task<(store: ImageStore, vmm: VZVirtualMachineManager), Error>?

    /// vminit 的版本和 Containerization 一致
    static let vminitReference = "ghcr.io/apple/containerization/vminit:0.53.0"
    /// 每个虚拟机除了各服务的内存上限之外，多给的部分（虚拟机本身约 290MB，再加网络小容器）
    static let vmOverheadBytes: UInt64 = 512 * 1024 * 1024

    public init(supportDirectory: URL, guardBinary: URL) {
        self.supportDirectory = supportDirectory
        storage = Storage(root: supportDirectory)
        self.guardBinary = guardBinary
        builder = ImageBuilder(directory: supportDirectory.appending(path: "builder"), guardBinary: guardBinary)
    }

    static func openImageStore(supportDirectory: URL) throws -> ImageStore {
        let images = supportDirectory.appending(path: "images")
        try FileManager.default.createDirectory(at: images, withIntermediateDirectories: true)
        return try ImageStore(path: images, contentStore: try LocalContentStore(path: images.appending(path: "content")))
    }

    /// 内核、runc、Rosetta、镜像库、vminit。第一次起环境时准备，之后复用。
    func prepare() async throws(NapboxError) -> (store: ImageStore, vmm: VZVirtualMachineManager) {
        let task = preparing ?? Task { try await self.prepareOnce() }
        preparing = task
        do {
            return try await task.value
        } catch {
            // 没准备成的不留着：下次再试（比如 setup 之后）
            if preparing == task { preparing = nil }
            throw error as? NapboxError ?? NapboxError(.runtimeUnavailable, "准备运行环境失败：\(error)")
        }
    }

    private func prepareOnce() async throws(NapboxError) -> (store: ImageStore, vmm: VZVirtualMachineManager) {
        guard FileManager.default.fileExists(atPath: guardBinary.path) else {
            throw NapboxError(.runtimeUnavailable, "没有网络小容器的程序 \(guardBinary.path)：它和 napboxd 在同一目录，由 scripts/build-native.sh 一起编译。")
        }
        let kernel = supportDirectory.appending(path: "kernel/vmlinux")
        guard FileManager.default.fileExists(atPath: kernel.path) else {
            throw NapboxError(.runtimeUnavailable, "没有内核 \(kernel.path)，先运行 napbox setup。")
        }
        let runc = RuntimeContainer.runc(in: supportDirectory)
        guard FileManager.default.fileExists(atPath: runc.path) else {
            throw NapboxError(.runtimeUnavailable, "没有 runc \(runc.path)，先运行 napbox setup。")
        }
        // 不在这里查的话，Containerization 会在第一个虚拟机启动前自己去装（弹系统的确认窗口）
        guard VZLinuxRosettaDirectoryShare.availability == .installed else {
            throw NapboxError(.runtimeUnavailable, "没有装 Rosetta（虚拟机里运行 x86 的程序要用它），先运行 napbox setup。")
        }
        do {
            let store = try Self.openImageStore(supportDirectory: supportDirectory)
            let initImage = try await store.getInitImage(reference: Self.vminitReference)
            let initPath = supportDirectory.appending(path: "runtime/init.block")
            try FileManager.default.createDirectory(at: initPath.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: initPath)
            let initfs = try await initImage.initBlock(at: initPath, for: .linuxArm)
            // 所有虚拟机共用一组线程。不给的话每个虚拟机自己建一组（CPU 核数个线程），停的时候才释放；虚拟机崩溃后
            // Containerization 的 stop 发现它不在运行就直接报错，这组线程和文件句柄永远留着（实测每次崩溃留下 18 个线程、18 个句柄）
            // rosetta：镜像是 arm64 的、里面的程序是 x86 的（比如 Dockerfile 里写死 GOARCH=amd64），Docker Desktop 里能跑，
            // 这里也要能跑。虚拟机启动时把 Rosetta 挂进去，登记成 x86 程序的解释器，对虚拟机里所有容器生效
            let vmm = VZVirtualMachineManager(kernel: Kernel(path: kernel, platform: .linuxArm), initialFilesystem: initfs,
                                              rosetta: true,
                                              group: MultiThreadedEventLoopGroup.singleton)
            return (store, vmm)
        } catch {
            throw NapboxError(.runtimeUnavailable, "准备运行环境失败：\(error)")
        }
    }

    /// 挂载的来源在宿主机上成不成立（secrets 的文件在不在、有没有同时挂目录和它里面的文件）。和准备镜像一样在登记
    /// 环境之前查：不成立时不留下没用的登记。
    public nonisolated func checkHostMounts(_ project: ComposeProject) throws(NapboxError) {
        for s in project.services { try s.checkHostMounts() }
    }

    /// 先把要用的镜像都准备好（本地没有就拉；构建出来的 buildImages 已经准备好了），再查每个服务的镜像和 compose
    /// 合起来成不成立（ImageSettings）。在登记环境、分配端口之前调用：镜像拉不到、配置不成立时不留下没用的登记。
    public func prepareImages(_ project: ComposeProject, environment name: String) async throws(NapboxError) {
        let (store, _) = try await prepare()
        let id = EnvironmentRecord.id(of: name)
        for s in project.services {
            let image = if Images.build(of: s, in: project) == nil {
                try await Images.resolve(s, store: store)
            } else {
                try await Images.forStart(s, project: project, environment: id, store: store)
            }
            _ = try await ImageSettings(service: s, image: image)
        }
    }

    /// 构建写了 build 的服务的镜像，规则和 Docker 一样：镜像还没有才构建，pull_policy: build 和 force（up --build）
    /// 每次都构建。build 定义一样的只构建一次。返回有没有镜像变了（构建了但内容一样不算），在跑的环境要靠它决定重不重启。
    public func buildImages(_ project: ComposeProject, environment name: String, force: Bool) async throws(NapboxError) -> Bool {
        let id = EnvironmentRecord.id(of: name)
        var builds: [(reference: String, build: Build, service: String, always: Bool)] = []
        for s in project.services {
            guard let build = s.build else { continue }
            let reference = try Images.builtReference(environment: id, build: build)
            if let i = builds.firstIndex(where: { $0.reference == reference }) {
                if s.pullPolicy == .build { builds[i].always = true }
            } else {
                builds.append((reference, build, s.name, s.pullPolicy == .build))
            }
        }
        guard !builds.isEmpty else { return false }
        let (store, vmm) = try await prepare()
        var changed = false
        for b in builds {
            let existing = try? await store.get(reference: b.reference)
            if existing != nil, !force, !b.always { continue }
            var before: String?
            if let existing { before = try? await Images.platformDigest(existing) }
            let request = ImageBuilder.Request(reference: b.reference, build: b.build, service: b.service,
                                               log: storage.buildLog(environment: id, service: b.service))
            let image = try await builder.build(request, store: store, vmm: vmm)
            if try await Images.platformDigest(image) != before { changed = true }
        }
        // 重新构建后旧版本的层没人用了。根文件系统是解包出来的独立文件，在跑的环境不受影响
        if changed { _ = try? await store.cleanUpOrphanedBlobs() }
        return changed
    }

    /// napboxd 退出前调用
    public func stopBuilder() async { await builder.stop() }

    /// 环境回收时删掉它构建出来的镜像和构建日志。要再用时重新构建，有缓存，不用从头来。
    /// 按环境名找：临时环境第一次起就失败时还没有登记，构建出来的也要删。
    public func removeBuiltImages(environment name: String) async throws(NapboxError) {
        let id = EnvironmentRecord.id(of: name)
        try? FileManager.default.removeItem(at: storage.buildLogs(environment: id))
        let (store, _) = try await prepare()
        let prefix = Images.builtPrefix(environment: id)
        do {
            let built = try await store.list().filter { $0.reference.hasPrefix(prefix) }
            guard !built.isEmpty else { return }
            for image in built { try await store.delete(reference: image.reference) }
            try await store.cleanUpOrphanedBlobs()
        } catch {
            throw NapboxError(.internalError, "\(error)")
        }
    }

    /// 起一个环境：准备镜像、根文件系统、数据卷，创建 pod，按依赖顺序启动，等全部就绪。
    /// 失败时虚拟机已经停掉、日志文件已经关上，错误里说明是哪个服务、退出码和最后的日志。
    /// 服务退出的通知由调用方登记好环境后用 deliverExits 接（restart）。
    /// - skipping：唤醒时传已经成功跑完的一次性服务；显式 up 传空，和 Docker 一样一次性服务会再跑一次
    /// - trace：记下每个服务用的镜像、启动和就绪的时间，失败时也留着走到的部分（运行记录用）
    /// - foreground：napbox run 在前台跑的那个服务，接上它的标准输入和输出，不等它就绪
    /// - progress：虚拟机建好了、哪个服务就绪了随时告诉它（唤醒时连接等自己的服务就绪用）
    public func start(_ record: EnvironmentRecord, project: ComposeProject, skipping: Set<String>,
                      foreground: ForegroundService? = nil, trace: RunTrace,
                      progress: StartProgress) async throws(NapboxError) -> RunningEnvironment {
        let (store, vmm) = try await prepare()
        guard let ip = record.ip else { throw NapboxError(.internalError, "环境 \(record.name) 没有分配 IP") }
        let layout = try EnvironmentLayout(directory: storage.environmentDirectory(record))
        let addresses = try ServiceNetwork.addresses(project.services.map(\.name))
        let portVariables = PortVariables.variables(record.ports.filter { project.service($0.service)?.ports.contains($0.containerPort) == true })

        // 每个 ContainerPlan 打开一个日志文件：中途失败时把已经打开的关上（napboxd 常驻，唤醒反复失败时句柄会越积越多）
        var containers: [ContainerPlan] = []
        var freshRootfs: [String: URL] = [:]
        let pod: LinuxPod
        do throws(NapboxError) {
            for s in project.services {
                let image = try await Images.forStart(s, project: project, environment: record.id, store: store)
                trace.image(s.name, reference: image.reference, digest: image.digest, platformDigest: try await Images.platformDigest(image))
                containers.append(try await ContainerPlan(
                    service: s, image: image, layout: layout, portVariables: portVariables, freshRootfs: &freshRootfs, trace: trace,
                    foreground: s.name == foreground?.service ? foreground : nil
                ))
            }
            pod = try await createPod(record, project: project, ip: ip, addresses: addresses, layout: layout, containers: containers, vmm: vmm)
        } catch {
            for plan in containers { plan.log.close() }
            throw error
        }

        let env = RunningEnvironment(
            pod: pod, logs: Dictionary(uniqueKeysWithValues: containers.map { ($0.name, $0.log) }),
            stopSignals: Dictionary(uniqueKeysWithValues: containers.map { ($0.name, $0.stopSignal) }),
            images: Dictionary(uniqueKeysWithValues: containers.map { ($0.name, ServiceImage(user: $0.imageConfig.user ?? "", created: $0.imageCreated)) }),
            layout: layout, addresses: addresses
        )
        progress.created(env)
        do {
            try await env.startAll(project, skipping: skipping, foreground: foreground?.service, egress: record.egress,
                                   trace: trace, progress: progress)
        } catch {
            await env.stop()
            throw error
        }
        return env
    }

    /// - ip：虚拟机在宿主机那个网段里的地址
    /// - addresses：每个服务在虚拟机里面那个网段的地址（ServiceNetwork）
    private func createPod(_ record: EnvironmentRecord, project: ComposeProject, ip: String, addresses: [String: String],
                           layout: EnvironmentLayout, containers: [ContainerPlan], vmm: VZVirtualMachineManager) async throws(NapboxError) -> LinuxPod {
        let guardRootfs = try layout.guardRootfs(binary: guardBinary)
        let runtimeDisk = try layout.runtimeDisk(guardBinary: guardBinary, runc: RuntimeContainer.runc(in: supportDirectory), addresses: addresses)
        // 服务之间用服务名互相找：每个名字指到那个服务自己的地址
        var hosts = Hosts.default
        hosts.entries += addresses.sorted { $0.key < $1.key }.map { .init(ipAddress: $0.value, hostnames: [$0.key]) }
        let volumes = try project.volumes.map { name throws(NapboxError) in
            LinuxPod.PodVolume(name: name, source: .diskImage(path: try layout.volume(name), readOnly: false), format: "ext4")
        }
        let memory = project.services.reduce(Self.vmOverheadBytes) { $0 + $1.memoryBytes }
        do {
            let cidr = try CIDRv4("\(ip)/24")
            let gateway = try IPv4Address(AddressAllocator.gateway)
            let mac = try MACAddress(try AddressAllocator.macAddress(for: ip))
            let finalHosts = hosts
            let pod = try LinuxPod("napbox-\(record.id)", vmm: vmm, vm: VMResources(cpus: 4, memoryInBytes: memory)) { c in
                c.interfaces = [NATInterface(ipv4Address: cidr, ipv4Gateway: gateway, macAddress: mac)]
                c.dns = DNS(nameservers: [AddressAllocator.gateway])
                c.hosts = finalHosts
                c.volumes = volumes
                // 容器都由垫在 runc 前面那一层来启动，服务的容器在这时接上自己的网络
                c.ociRuntimePath = RuntimeContainer.guestProgram
                // 服务都带框架默认的系统调用白名单（和 Docker 默认用的是同一份）。它不让建 vsock：服务够不到网络小容器
                // 和 napboxd 的 vsock 端口，这条路不经过出网规则
                c.seccompProfile = .default
            }
            // 只为了让虚拟机里有那块盘，不启动
            try await pod.addContainer(RuntimeContainer.name, rootfs: runtimeDisk) { c in
                c.process.arguments = [RuntimeContainer.program]
            }
            try await pod.addContainer(GuardContainer.name, rootfs: guardRootfs) { c in
                c.process.arguments = [GuardContainer.program]
                // 它自己要在 vsock 上听 napboxd，重新挂文件时还要进服务的挂载命名空间：不带白名单
                c.seccompProfile = .unconfined
                let sources = GuardContainer.sources(project)
                c.mounts = LinuxContainer.defaultMounts() + sources.directories.enumerated().map {
                    .share(source: $1, destination: "/napbox-src/\($0)", options: [])
                } + GuardContainer.populateMounts(project) + [GuardContainer.vmProcMount]
                // 只是上限，用多少才占多少。所有转发的连接都经过它（guard/mux.go），每条空闲连接约 25KB，
                // 忙的连接最多再加额度那么多。超过上限它会被杀，环境转成休眠（watchGuard）
                c.memoryInBytes = 256 * 1024 * 1024
            }
            for plan in containers {
                try await pod.addContainer(plan.name, rootfs: plan.rootfs) { c in plan.configure(&c) }
            }
            try await pod.create()
            return pod
        } catch {
            throw NapboxError(.runtimeUnavailable, "创建虚拟机失败：\(error)")
        }
    }

    // MARK: - 数据（Storage，不占着 actor）

    /// develop.watch 记着这个服务同步到哪了的文件
    public nonisolated func watchManifest(_ record: EnvironmentRecord, service: String) throws(NapboxError) -> URL {
        try EnvironmentLayout(directory: storage.environmentDirectory(record)).watchManifest(service)
    }

    /// napbox down、worktree 删掉后回收：整个环境目录移到 recycled 下保留 7 天。
    /// 环境没起过（没有目录）时返回 nil。
    public nonisolated func recycle(_ record: EnvironmentRecord, reason: String) throws(NapboxError) -> URL? {
        try storage.recycleEnvironment(record, reason: reason)
    }

    /// 调用方要求不保留数据的销毁：删掉了返回 nil，删失败时返回数据还留着的地方（7 天后删）。环境要先停掉。
    public nonisolated func discard(_ record: EnvironmentRecord, reason: String) throws(NapboxError) -> URL? {
        try storage.discardEnvironment(record, reason: reason)
    }

    /// 临时环境销毁：整个环境目录直接删掉，不保留。环境要先停掉。
    public nonisolated func delete(_ record: EnvironmentRecord) throws(NapboxError) {
        try storage.deleteEnvironment(record)
    }

    /// napbox reset：把一个数据卷移到 recycled 下保留 7 天，下次启动时建一个空的。环境要先停掉。卷还没建过时返回 nil。
    public nonisolated func recycleVolume(_ record: EnvironmentRecord, volume: String, reason: String) throws(NapboxError) -> URL? {
        try storage.recycleVolume(record, volume: volume, reason: reason)
    }

    /// 删掉 recycled 下保留期满的数据，返回要记进日志的话
    public nonisolated func purgeRecycled(now: Date = Date()) -> [String] { storage.purgeRecycled(now: now) }

    /// 记下一次起环境（运行记录）
    public nonisolated func saveRun(_ record: EnvironmentRecord, _ run: RunRecord) throws(NapboxError) {
        try storage.appendRun(record, run)
    }

    /// 环境的运行记录，从旧到新
    public nonisolated func runs(_ record: EnvironmentRecord) throws(NapboxError) -> [RunRecord] {
        try storage.runs(record)
    }

    /// 服务的日志文件（不一定存在：环境还没起过）
    public nonisolated func logFile(_ record: EnvironmentRecord, service: String) -> URL {
        EnvironmentLayout.logFile(in: storage.environmentDirectory(record), service: service)
    }
}
