// 一个正在运行的环境：按依赖顺序启动服务、判断就绪、记录每个服务的退出。
import Containerization
import ContainerizationArchive
import ContainerizationError
import ContainerizationOS
import Foundation
import NapboxCore
import NapboxProtocol

/// develop.watch 要写进容器的一个文件、目录或符号链接
public struct SyncedFile: Sendable {
    public var hostPath: String
    public var containerPath: String
    public var stat: SourceFileStat

    public init(hostPath: String, containerPath: String, stat: SourceFileStat) {
        self.hostPath = hostPath
        self.containerPath = containerPath
        self.stat = stat
    }
}

/// 同步文件要用到的镜像信息
struct ServiceImage: Sendable {
    var user: String
    var created: String?
}

private struct FileOwner: Sendable {
    var uid: UInt32
    var gid: UInt32
}

public actor RunningEnvironment {
    let pod: LinuxPod

    /// 连到虚拟机里的端口转发（guard/relay.go）。每个转发的连接一条。
    public nonisolated func dialRelay() async throws -> FileHandle {
        try await pod.dialVsock(port: GuardContainer.relayPort)
    }

    let logs: [String: LogFile]
    let stopSignals: [String: Signal]
    /// 已经退出的服务和退出码（每个服务一个一直等着的 waitContainer）
    private var exits: [String: Int32] = [:]
    private var healthy: Set<String> = []
    private var watchers: [Task<Void, Never>] = []
    /// 真正启动过的服务（唤醒时跳过的一次性服务不在里面），停的时候要先让它们正常退出
    private var started: Set<String> = []
    private var gracePeriods: [String: Double] = [:]
    private var project: ComposeProject?
    /// 停的顺序：按依赖分层倒过来，先停依赖别人的，被依赖的（比如数据库）最后停
    private var stopLayers: [[String]] = []
    /// 服务退出的通知：交给 napboxd 按 restart 决定要不要整个环境重启
    public typealias ExitHandler = @Sendable (RunningEnvironment, String, Int32) -> Void
    /// napboxd 把环境登记成运行中以后才给（deliverExits）；在那之前的退出先存在 undelivered 里
    private var exitHandler: ExitHandler?
    private var undelivered: [(service: String, code: Int32)] = []
    private var ready = false
    private var stopping = false
    /// 虚拟机意外没了的通知：交给 napboxd 把环境转成休眠。和退出通知一样，登记成运行中以后才给（deliverExits）
    public typealias VMLostHandler = @Sendable (RunningEnvironment) -> Void
    private var vmLostHandler: VMLostHandler?
    private var vmLost = false
    private var vmWatcher: Task<Void, Never>?
    /// 当前的出网模式，和 open 模式下挡住的宿主机地址
    private var egress: EgressMode = .open
    private var blockedHostAddresses: [String] = []
    /// 把宿主机挂载目录的变化转给虚拟机
    private var sourceStream: SourceEventStream?
    private var sourceForwarder: SourceEventForwarder?
    /// 挂进服务的单个文件，和每一处上次对过时宿主机上那个文件的样子（哪个文件、多大、什么时候改的、权限）。
    /// 宿主机上不一样了就让虚拟机跟上（catchUpBoundFiles）。
    /// 没记的是还不知道：服务启动时按名字挂，那一刻虚拟机记着的名字可能还指着刚被换掉的文件
    private var fileBindings: [GuardContainer.FileBinding] = []
    private var boundFiles: [GuardContainer.FileBinding.Use: SourceFileStat] = [:]
    /// 正在跑的那一轮重新挂载
    private var rebinding: Task<RebindOutcome, Never>?
    /// 同步文件时虚拟机连回来的 vsock 端口。框架自己用的从 0x1000_0000 开始
    private var nextCopyPort: UInt32 = 0x2000_0000
    let images: [String: ServiceImage]
    let layout: EnvironmentLayout
    /// 每个服务自己的地址（ServiceNetwork）。转发宿主机端口的连接时连的是它（guard/relay.go）
    public nonisolated let addresses: [String: String]
    /// 同步的文件属于谁，每个服务查一次
    private var fileOwners: [String: FileOwner] = [:]
    /// develop.watch 跑的命令最多等这么久
    static let watchCommandTimeout: Double = 600

    /// 和 Docker 一样：停服务时先发停止信号，等 stop_grace_period（默认 10 秒），还没退出再强制结束
    static let defaultGracePeriod: Double = 10

    /// 没有 healthcheck、有端口的服务，最多等这么久开始监听
    static let listenTimeout: TimeInterval = 120
    /// depends_on 要求 service_completed_successfully 时，最多等一次性服务这么久
    static let completionTimeout: TimeInterval = 600
    /// 多久看一次虚拟机还在不在。只读框架里的状态，不和虚拟机通信
    static let vmCheckNanoseconds: UInt64 = 500_000_000

    init(pod: LinuxPod, logs: [String: LogFile], stopSignals: [String: Signal], images: [String: ServiceImage],
         layout: EnvironmentLayout, addresses: [String: String]) {
        self.pod = pod
        self.logs = logs
        self.stopSignals = stopSignals
        self.images = images
        self.layout = layout
        self.addresses = addresses
    }

    /// 之后的服务退出和虚拟机没了交给 handler，之前已经发生的现在一起交出。napboxd 先把环境登记成运行中再调用，
    /// 这样收到的每条通知都能对上登记的环境。
    public func deliverExits(to handler: @escaping ExitHandler, vmLost lostHandler: @escaping VMLostHandler) {
        exitHandler = handler
        for e in undelivered { handler(self, e.service, e.code) }
        undelivered = []
        vmLostHandler = lostHandler
        if vmLost { lostHandler(self) }
    }

    /// 跑完的服务，唤醒、重启时不再启动
    public var completedServices: [String] {
        exits.filter { completes($0.key, exitCode: $0.value) }.map(\.key).sorted()
    }

    /// 不该停却停了的服务：这次启动过、退出了、又不算跑完。up、create、wake 看到它们时整个环境重启
    public var stoppedServices: [String] {
        started.filter { name in exits[name].map { !completes(name, exitCode: $0) } ?? false }.sorted()
    }

    private func completes(_ name: String, exitCode: Int32) -> Bool {
        guard let project, let service = project.service(name) else { return false }
        return project.completes(service, exitCode: exitCode)
    }

    /// 停掉环境（休眠、napboxd 退出、down 都走这里）：
    /// 1. 按依赖倒过来一层一层停（和 docker compose 一样）：给这一层还在运行的服务发停止信号（镜像的 STOPSIGNAL，
    ///    没写的是 SIGTERM），等它们自己退出（postgres、redis 这类要靠它正常落盘），再停下一层。层内同时发、同时等
    /// 2. 在网络小容器里执行 sync，把整个虚拟机的文件系统刷到磁盘：pod.stop() 只卸载启动过的容器的根文件系统，
    ///    唤醒时没启动的一次性服务的根文件系统不会被卸载，不刷的话写进去的东西（比如 resolv.conf）可能丢、
    ///    下次挂载后写不进去（2026-11-07 实测碰到）
    /// 3. pod.stop()：还没退出的强制结束，停掉虚拟机
    /// 虚拟机已经没了时跳过前两步：里面什么都不会回应，不用白等 stop_grace_period。
    public func stop() async {
        stopping = true
        vmWatcher?.cancel()
        sourceStream?.stop()
        await sourceForwarder?.close()
        if await vmState() == .running {
            for layer in stopLayers {
                let names = layer.filter { started.contains($0) && exits[$0] == nil }
                for name in names {
                    try? await pod.killContainer(name, signal: stopSignals[name] ?? .term)
                }
                let signalled = Date()
                for name in names {
                    let deadline = signalled.addingTimeInterval(gracePeriods[name] ?? Self.defaultGracePeriod)
                    while exits[name] == nil, Date() < deadline {
                        try? await Task.sleep(nanoseconds: 100_000_000)
                    }
                }
            }
            _ = await exec(GuardContainer.name, [GuardContainer.program, "sync"], timeout: 10)
        }
        for w in watchers { w.cancel() }
        try? await pod.stop()
        for log in logs.values { log.close() }
    }

    // MARK: - 启动

    /// - skipping：已经成功跑完的一次性服务。唤醒时它们照样加进 pod，但不启动、也不重新执行，
    ///   依赖它们 service_completed_successfully 的服务直接算满足
    /// - foreground：napbox run 在前台跑的那个服务。照依赖顺序启动，但不等它就绪：它跑完就退出，退出码由
    ///   foregroundExit 交给调用方，不为 0 也不算起环境失败
    /// - egress：先加好出网规则再启动服务，服务起来的那一刻规则就在
    /// - trace：记下每个服务启动、就绪的时间
    func startAll(_ project: ComposeProject, skipping: Set<String>, foreground: String? = nil, egress: EgressMode,
                  trace: RunTrace) async throws(NapboxError) {
        watchVM()
        self.project = project
        for name in skipping {
            exits[name] = 0
            trace.skipped(name)
        }
        stopLayers = StartOrder.levels(project.services).reversed().map { $0.map(\.name) }
        // 新起和唤醒都是新开的虚拟机，第一个服务启动之前把时钟对准
        try await GuestClock.sync(pod)
        var settings = Self.inotifyLimits
        // 4 是之后清目录项缓存时不再写内核日志，否则每条命令一行，会把内存不足杀进程这类有用的记录挤掉
        if project.hasSourceMounts { settings["vm.drop_caches"] = "4" }
        try await writeSysctl(settings)
        try await startContainer(GuardContainer.name)
        watchGuard()
        try await applyEgress(egress)
        try startSourceEvents(project)
        for s in StartOrder.order(project.services) where !skipping.contains(s.name) {
            for d in s.dependsOn {
                guard let dep = project.service(d.service) else { continue }
                switch d.condition {
                case .started: break
                case .healthy: try await waitHealthy(dep)
                case .completedSuccessfully: try await waitCompleted(dep)
                }
            }
            try await populateVolumes(s)
            try await startContainer(s.name)
            trace.started(s.name)
            started.insert(s.name)
            gracePeriods[s.name] = s.stopGracePeriodSeconds
            watch(s.name)
        }
        for s in project.services where !skipping.contains(s.name) && s.name != foreground {
            trace.ready(s.name, try await waitReady(s))
        }
        // 服务启动的那一刻宿主机正好在换文件的话，服务挂上的可能是被换掉的那个：报就绪之前确认一遍
        try await catchUpBoundFiles()
        // 报就绪之前存一次盘：启动期间写的内容（比如 postgres 入口脚本追加的 pg_hba.conf）最多 30 秒才写回，
        // 这时虚拟机随 napboxd 崩溃一起没了就丢了
        let (code, output) = await exec(GuardContainer.name, [GuardContainer.program, "sync"], timeout: 30)
        if code != 0 {
            throw NapboxError(.runtimeUnavailable, "就绪时存盘失败：\(output.isEmpty ? "退出码 \(code)" : output)")
        }
        ready = true
        // 就绪判断只看每个服务自己那一段：一个服务就绪以后、别的服务还在启动时退出了（包括跑完的一次性服务），
        // startAll 不会报错。现在补上通知，和就绪以后的退出一样由 napboxd 按 restart 处理
        for name in started.sorted() {
            if let code = exits[name] { report(name, code) }
        }
    }

    /// 和 Docker 建容器时一样：服务挂的命名卷是空的、镜像里有这个目录，就先把目录里的东西连同属主、权限复制进卷。
    /// 在网络小容器里做（guard/populate.go），这时服务还没启动。每个卷对服务现在的根文件系统只看一次。
    /// 不设时限：镜像里的目录可能很大（比如 node_modules），Docker 也是等它复制完。
    private func populateVolumes(_ s: Service) async throws(NapboxError) {
        for (volume, target) in s.namedVolumes where !layout.volumePopulated(volume, service: s.name) {
            let argv = [GuardContainer.program, "populate", GuardContainer.rootfsRoot(s.name), target, GuardContainer.volumeRoot(volume)]
            let (code, output) = await exec(GuardContainer.name, argv, timeout: nil)
            if code != 0 {
                throw NapboxError(.serviceFailed, "\(s.name) 的数据卷 \(volume) 带不上镜像里 \(target) 的内容：\(output.isEmpty ? "退出码 \(code)" : output)")
            }
            try layout.markVolumePopulated(volume, service: s.name)
        }
    }

    private func startContainer(_ name: String) async throws(NapboxError) {
        do {
            try await pod.startContainer(name)
        } catch {
            throw NapboxError(.serviceFailed, "\(name) 启动失败：\(error)\(logTail(name))")
        }
    }

    private func watch(_ name: String) {
        let pod = pod
        watchers.append(Task { [weak self] in
            // 等不到结果：要么环境在停（我们停的），要么虚拟机没了（watchVM 负责发现），都不算这个服务退出
            guard let status = try? await pod.waitContainer(name) else { return }
            await self?.recordExit(name, status.exitCode)
        })
    }

    /// 网络小容器没了，端口就转发不了了，出网规则也换不了：环境看着在运行其实用不了。
    /// 和虚拟机没了一样处理，转成休眠，用到时再起。
    private func watchGuard() {
        let pod = pod
        watchers.append(Task { [weak self] in
            guard (try? await pod.waitContainer(GuardContainer.name)) != nil else { return }
            await self?.recordVMLost()
        })
    }

    /// 定时看虚拟机还在不在。Containerization 没有虚拟机停止的通知，也不把框架的 delegate 交出来，只能看状态。
    /// 2026-11-08 实测：虚拟机进程被杀或自己崩溃，状态约 0.1 秒内就不再是 running；进程卡住（SIGSTOP 19 秒）状态
    /// 一直是 running，恢复后命令照常结束，所以卡顿不会误判。服务的 waitContainer 不能用来发现：卡住时等不到结果，
    /// 服务都跑完了的环境也没有在等的。
    private func watchVM() {
        vmWatcher = Task { [weak self] in
            while true {
                do { try await Task.sleep(nanoseconds: Self.vmCheckNanoseconds) } catch { return } // stop 取消了
                guard let self else { return }
                if await self.vmState() != .running {
                    await self.recordVMLost()
                    return
                }
            }
        }
    }

    /// nil 是 pod 已经停了（我们停的）
    private func vmState() async -> VirtualMachineInstanceState? {
        try? await pod.withVirtualMachineInstance { $0.state }
    }

    private func recordVMLost() {
        guard !stopping else { return } // 我们在停它
        vmLost = true
        vmLostHandler?(self)
    }

    private func recordExit(_ name: String, _ code: Int32) {
        exits[name] = code
        // 启动期间的退出由 startAll 报错或在就绪时补报
        if ready { report(name, code) }
    }

    /// 停的时候的退出是我们停的，不报
    private func report(_ name: String, _ code: Int32) {
        guard !stopping else { return }
        if let exitHandler { exitHandler(self, name, code) } else { undelivered.append((name, code)) }
    }

    // MARK: - napbox run

    /// 等前台那个服务退出，输出都交完后返回退出码（napbox run）。不关 output。
    /// 环境先停了（被销毁、虚拟机没了）就报错；调用它的任务被取消时（命令行断开了）也报错，由调用方销毁环境。
    public func foregroundExit(_ service: String, output: ExecOutput) async throws(NapboxError) -> Int32 {
        while true {
            if let code = exits[service] {
                await output.waitForUnread() // 环境销毁时输出的连接会关掉
                return code
            }
            if stopping || vmLost { throw NapboxError(.serviceFailed, "\(service) 还没跑完，环境就停了\(logTail(service))") }
            do { try await Task.sleep(nanoseconds: 50_000_000) } catch {
                throw NapboxError(.serviceFailed, "\(service) 还没跑完，命令行就断开了")
            }
        }
    }

    // MARK: - napbox exec

    /// 在服务的容器里执行一条命令（napbox exec，沿用容器主进程的环境变量、工作目录、用户，和 docker exec 一样），
    /// 等它结束、输出都交完后返回退出码。
    /// - stdin：命令的标准输入，结束时关掉命令的标准输入
    /// - output：输出按顺序排进去，积压到上限时命令等着（ExecOutput）。正常结束时收完了才返回，不关 output
    /// 调用它的任务被取消时（命令行断开了）结束这条命令和它的子进程（killGroup）。
    public func exec(_ service: String, _ argv: [String], stdin: AsyncStream<Data>,
                     output: ExecOutput) async throws(NapboxError) -> Int32 {
        guard started.contains(service) else {
            throw NapboxError(.serviceFailed, "\(service) 这次没有启动（已经跑完的一次性服务唤醒时不再启动），没法在里面执行命令")
        }
        if let code = exits[service] {
            throw NapboxError(.serviceFailed, "\(service) 已经退出了，退出码 \(code)，没法在里面执行命令\(logTail(service))")
        }
        try await refreshSourceMounts()
        let process: LinuxProcess
        do {
            process = try await pod.execInContainer(service, processID: "exec-\(UUID().uuidString.prefix(8))") { c in
                c.arguments = argv
                c.stdin = StreamReader(stream: stdin)
                c.stdout = OutputWriter(stream: .stdout, output: output)
                c.stderr = OutputWriter(stream: .stderr, output: output)
            }
        } catch {
            throw NapboxError(.serviceFailed, "在 \(service) 里执行命令失败：\(error)")
        }
        // 启动和等待都放进单独的任务，不随取消中断：启动被打断时虚拟机里可能已经起了进程；等待被打断的话，
        // 下面的 delete 会抢在结束命令之前（2026-11-08 实测 48 次取消里 9 次没杀到）。
        // 建好之后不管成没成功都要删掉
        do {
            try await Task { try await process.start() }.value
        } catch {
            try? await process.delete()
            throw NapboxError(.serviceFailed, "在 \(service) 里执行 \(argv.joined(separator: " ")) 失败：\(error)")
        }
        let waiting = Task { try await process.wait() } // 等到输出都转完才返回
        let status: ExitStatus
        do {
            status = try await withTaskCancellationHandler {
                try await waiting.value
            } onCancel: {
                output.close() // 被堵住的写入方要放开，命令才结束得了
                Task { await self.killGroup(process) }
            }
        } catch {
            output.close()
            try? await process.delete()
            throw NapboxError(.serviceFailed, "等命令结束时出错（环境可能停了）：\(error)")
        }
        await output.waitForUnread() // delete 会关掉输出的连接
        output.close()
        try? await process.delete()
        return status.exitCode
    }

    // MARK: - develop.watch 的同步

    /// 服务这次启动了、还没退出
    public func isServiceRunning(_ service: String) -> Bool {
        started.contains(service) && exits[service] == nil
    }

    /// 服务的镜像是什么时候建的（纳秒）。没写的是 nil
    public func imageCreatedNanoseconds(_ service: String) -> Int64? {
        images[service]?.created.flatMap(rfc3339Nanoseconds)
    }

    /// 把一批文件、目录、符号链接写进服务，已有的换掉。和 compose 一样打成一个包，权限和修改时间照宿主机，属主是容器的用户。
    /// 包先传进容器，再在容器里以 root 跑 tar 解开，所以写的就是容器看到的路径：经过符号链接、落在挂载下面都对。
    /// 不用框架现成的“传压缩包直接解开”（copy 的 isArchive）：vminitd 0.53.0 那条路径把连接关两次，第二次可能关掉别的线程刚拿到的
    /// 同一个编号，实测把并发 exec 的管道关了（read ack pipe: Bad file descriptor）。单个文件的 copy 没有这个问题。
    public func syncFiles(_ service: String, _ files: [SyncedFile]) async throws(NapboxError) {
        let owner = try await fileOwner(service)
        // 刚被删的不放进去，删除的变化随后就到。一个条目都没有的包 tar 也认，但没必要传
        let present = files.filter { SourceFileStat.of($0.hostPath) != nil }
        guard !present.isEmpty else { return }
        let archive = "/.napbox-sync-\(UUID().uuidString.prefix(8)).tar"
        do {
            try await transfer(service, .copyIn, path: archive, isArchive: false) { connection in
                try Self.writeArchive(present, owner: owner, to: connection)
            }
        } catch {
            throw NapboxError(.serviceFailed, "把 \(present.count) 个文件传到 \(service) 失败：\(error)")
        }
        let (code, output) = await exec(service, ["tar", "-xf", archive, "-C", "/"], timeout: Self.watchCommandTimeout, asRoot: true)
        _ = await exec(service, ["rm", "-f", archive], timeout: Self.watchCommandTimeout, asRoot: true)
        guard code == 0 else {
            throw NapboxError(.serviceFailed, "在 \(service) 里解开同步的 \(present.count) 个文件失败（镜像里要有 tar），退出码 \(code)：\(output)")
        }
    }

    /// 同步的文件属于谁：镜像的 USER，名字按容器自己的 /etc/passwd、/etc/group 查（和服务进程的规则相同）。没有这两个文件的镜像只能写数字。
    private func fileOwner(_ service: String) async throws(NapboxError) -> FileOwner {
        if let known = fileOwners[service] { return known }
        guard let image = images[service] else { throw NapboxError(.internalError, "没有 \(service) 的镜像信息") }
        let directory = FileManager.default.temporaryDirectory.appending(path: "napbox-user-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            for name in ["passwd", "group"] {
                let local = directory.appending(path: name)
                // 读不到就当没有：镜像可以没有这两个文件；要用名字却查不到时下面会报
                try? await transfer(service, .copyOut, path: "/etc/\(name)", isArchive: false) { connection in
                    try (connection.readToEnd() ?? Data()).write(to: local)
                }
            }
            let user = try ContainerizationOS.User.getExecUser(
                userString: image.user, passwdPath: directory.appending(path: "passwd"), groupPath: directory.appending(path: "group"))
            let owner = FileOwner(uid: user.uid, gid: user.gid)
            fileOwners[service] = owner
            return owner
        } catch {
            throw NapboxError(.serviceFailed, "查不到 \(service) 的用户 \(image.user)：\(error)")
        }
    }

    /// 和虚拟机里的 vminitd 传一次文件：vminitd 连回来一条 vsock，body 在这条连接上读或写，写完关掉就是结束
    private func transfer(_ service: String, _ direction: Com_Apple_Containerization_Sandbox_V3_CopyRequest.Direction, path: String, isArchive: Bool,
                          body: @escaping @Sendable (FileHandle) throws -> Void) async throws {
        let port = nextCopyPort
        nextCopyPort += 1
        try await pod.withVirtualMachineInstance { vm in
            let listener = try vm.listen(port)
            defer { try? listener.finish() }
            guard let vminitd = try await vm.dialAgent() as? Vminitd else {
                throw NapboxError(.internalError, "虚拟机里的代理不是 vminitd")
            }
            do {
                try await withThrowingTaskGroup(of: Void.self) { group in
                    group.addTask {
                        do {
                            try await vminitd.copy(direction: direction, root: GuardContainer.guestRootfs(service), path: path, vsockPort: port, isArchive: isArchive)
                        } catch {
                            try? listener.finish() // 不会连回来了（比如要读的文件没有），别让另一边一直等
                            throw error
                        }
                    }
                    group.addTask {
                        guard let connection = await listener.first(where: { _ in true }) else {
                            throw NapboxError(.internalError, "虚拟机没有连回来")
                        }
                        try listener.finish()
                        defer { connection.closeFile() }
                        try await Blocking.run { () throws(NapboxError) in
                            do {
                                try body(connection)
                            } catch {
                                throw NapboxError(.internalError, "\(error)")
                            }
                        }
                    }
                    try await group.waitForAll()
                }
            } catch {
                try? await vminitd.close()
                throw error
            }
            try? await vminitd.close()
        }
    }

    private nonisolated static func writeArchive(_ files: [SyncedFile], owner: FileOwner, to connection: FileHandle) throws {
        let writer = try ArchiveWriter(configuration: ArchiveWriterConfiguration(format: .gnutar, filter: .none))
        try writer.open(fileDescriptor: connection.fileDescriptor)
        var buffer = [UInt8](repeating: 0, count: 1 << 20)
        for file in files {
            let entry = WriteEntry()
            entry.path = String(file.containerPath.drop { $0 == "/" })
            entry.modificationDate = Date(timeIntervalSince1970: Double(file.stat.modifiedNanoseconds) / 1_000_000_000)
            entry.permissions = mode_t(file.stat.mode & 0o777)
            entry.owner = owner.uid
            entry.group = owner.gid
            entry.size = 0
            if file.stat.isDirectory {
                entry.fileType = .directory
                try writer.writeEntry(entry: entry, data: nil)
                continue
            }
            if file.stat.isSymlink {
                // 刚被删掉的就跳过，删除的变化随后就到。下面的普通文件同样
                guard let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: file.hostPath) else { continue }
                entry.fileType = .symbolicLink
                entry.symlinkTarget = destination
                try writer.writeEntry(entry: entry, data: nil)
                continue
            }
            let descriptor = open(file.hostPath, O_RDONLY | O_NONBLOCK)
            guard descriptor >= 0 else {
                if errno == ENOENT { continue }
                throw NapboxError(.internalError, "读不了 \(file.hostPath)：\(String(cString: strerror(errno)))")
            }
            defer { close(descriptor) }
            var info = Darwin.stat()
            guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { continue }
            entry.fileType = .regular
            entry.size = info.st_size
            let transaction = writer.makeTransactionWriter()
            try transaction.writeHeader(entry: entry)
            // 只写这么多：写的时候文件变长了，多的留给下一次变化。变短了框架补零
            var remaining = Int(info.st_size)
            while remaining > 0 {
                let count = read(descriptor, &buffer, min(buffer.count, remaining))
                guard count > 0 else {
                    if count < 0 { throw NapboxError(.internalError, "读不了 \(file.hostPath)：\(String(cString: strerror(errno)))") }
                    break
                }
                try buffer.withUnsafeBytes { try transaction.writeChunk(data: UnsafeRawBufferPointer(rebasing: $0[..<count])) }
                remaining -= count
            }
            try transaction.finish()
        }
        try writer.finishEncoding()
    }

    /// 在服务里跑一条同步要用的命令（删文件、sync+exec）。不是 0 就报错，带上输出。
    public func runInService(_ service: String, _ argv: [String]) async throws(NapboxError) {
        let (code, output) = await exec(service, argv, timeout: Self.watchCommandTimeout)
        guard code == 0 else {
            throw NapboxError(.serviceFailed, "在 \(service) 里执行 \(argv.joined(separator: " ")) 失败，退出码 \(code)：\(output)")
        }
    }

    /// 服务起来之前就开始转发：服务一读到文件，之后的变化就都不会漏
    private func startSourceEvents(_ project: ComposeProject) throws(NapboxError) {
        guard project.hasSourceMounts else { return }
        let sources = GuardContainer.sources(project)
        fileBindings = GuardContainer.fileBindings(project, sources)
        boundFiles = [:]
        let forwarder = SourceEventForwarder(
            environment: pod.id,
            mounts: sources.mounts,
            dial: { [pod] in try await pod.dialVsock(port: GuardContainer.notifyPort) },
            refresh: { [weak self] in try await self?.refreshSourceMounts() }
        )
        sourceForwarder = forwarder
        sourceStream = try SourceEventStream(
            directories: sources.directories,
            onChange: { paths in Task { await forwarder.add(paths) } },
            onDropped: { [id = pod.id] paths in
                print("环境 \(id)：系统说丢了一部分文件变化事件（\(paths.joined(separator: "、"))），这些目录下刚才的改动可能没通知到容器")
            }
        )
    }

    /// 让命令看到宿主机在它开始之前写完的内容：虚拟机里记着源码挂载的文件信息，从上次碰这个文件起
    /// 约 1 秒内不回宿主机问，这期间宿主机改了就会读到旧大小、旧内容，改名覆盖的还会报没有这个文件。框架没有调这个时间的
    /// 设置，所以执行命令前让 vminitd 清一次虚拟机的目录项缓存（只清目录项，不清文件内容；实测约 6 毫秒）。
    /// 清不掉还被进程打开着的文件：那种情况仍要等这 1 秒。清不了时报错，不让命令在可能读到旧内容的情况下跑。
    /// 也清不掉挂进服务的单个文件（容器里绑定着它）：那些由 catchUpBoundFiles 管。
    private func refreshSourceMounts() async throws(NapboxError) {
        guard project?.hasSourceMounts == true else { return }
        try await writeSysctl(["vm.drop_caches": "2"])
        try await catchUpBoundFiles()
    }

    /// 重新挂文件的那条命令要的权限（guard/rebind.go），网络小容器的 1 号进程和项目的服务都没有
    private static let rebindCapabilities = LinuxCapabilities(capabilities: [.sysAdmin, .sysChroot, .sysPtrace, .dacReadSearch])

    /// 挂进服务的单个文件在宿主机上变了，让在跑的服务跟上。容器里绑定的是文件本身，清目录项缓存
    /// 对它不起作用，所以每个文件记着上次对过时的样子，不一样了就让网络小容器回宿主机重新查一遍（guard/rebind.go）：
    /// - 换成了另一个文件（先写临时文件再改名：编辑器、git、agent 的写文件工具都这么保存）：挂上现在这个，不然读它会报错；
    /// - 还是这个文件、内容被原地改写了：虚拟机拿到新的大小，不然按旧的大小读，读到的是截短的内容。
    /// 还没启动的服务不用管：启动时按名字挂，启动完了再来确认。
    /// 同一时刻只跑一轮：几十条命令同时执行时，后到的等这一轮完了再看还有没有要跟上的。
    private func catchUpBoundFiles() async throws(NapboxError) {
        while true {
            if let running = rebinding {
                _ = await running.value
                continue
            }
            let pending = fileBindings.flatMap { binding -> [(use: GuardContainer.FileBinding.Use, guardPath: String, file: SourceFileStat)] in
                // 宿主机上没了，或者换成了目录、符号链接：没有可挂的，容器里那个文件读不了，等它再变回文件
                guard let now = SourceFileStat.of(binding.hostPath), !now.isSymlink, !now.isDirectory, !now.isSpecial else { return [] }
                return binding.uses
                    .filter { started.contains($0.service) && exits[$0.service] == nil && boundFiles[$0] != now }
                    .map { ($0, binding.guardPath, now) }
            }
            if pending.isEmpty { return }
            let task = Task<RebindOutcome, Never> {
                let argv = [GuardContainer.program, "rebind"] + pending.flatMap {
                    [$0.use.service, $0.guardPath, $0.use.target, $0.use.readOnly ? "ro" : "rw"]
                }
                let (code, output) = await self.exec(GuardContainer.name, argv, timeout: 10, capabilities: Self.rebindCapabilities)
                // 结束前自己清掉：等着的那些醒来时看到的是没有在跑的，会重新看一遍
                self.rebinding = nil
                guard code == 0 else {
                    // 有服务在这期间退出了，找不到它的进程是正常的：什么都没记，不带它再来一轮
                    if pending.contains(where: { self.exits[$0.use.service] != nil }) { return .serviceExited }
                    return .failed(NapboxError(.serviceFailed, "宿主机上变过的文件在服务里跟不上：\(output.isEmpty ? "退出码 \(code)" : output)"))
                }
                // 来源转眼又没了的那几个（"gone <第几个>"）不记，下次再看。
                // 记的是查之前看到的样子：这期间宿主机又改了的话，下次会再对一遍，只会多查不会漏
                let gone = Set(output.split(separator: "\n").compactMap { line -> Int? in
                    let words = line.split(separator: " ")
                    return words.count == 2 && words[0] == "gone" ? Int(words[1]) : nil
                })
                for (index, item) in pending.enumerated() where !gone.contains(index) {
                    self.boundFiles[item.use] = item.file
                }
                return .done
            }
            rebinding = task
            switch await task.value {
            case .done: return
            case .serviceExited: continue
            case .failed(let error): throw error
            }
        }
    }

    private enum RebindOutcome: Sendable {
        case done
        case serviceExited
        case failed(NapboxError)
    }

    /// 虚拟机里文件监听（inotify）的上限，照 Docker Desktop 的值设：
    /// 内核自己按虚拟机内存算的默认值小得多，chokidar 这类每个文件占一个监听的工具在前端项目里会不够。
    /// 一台虚拟机里的容器共用这一份，所以每次起虚拟机设一次。
    private static let inotifyLimits = [
        "fs.inotify.max_user_watches": "1048576",
        "fs.inotify.max_user_instances": "8192",
    ]

    /// 由 vminitd 写虚拟机的内核设置（/proc/sys 下的）：容器里这些文件是只读的。
    private func writeSysctl(_ settings: [String: String]) async throws(NapboxError) {
        do {
            try await pod.withVirtualMachineInstance { vm in
                guard let vminitd = try await vm.dialAgent() as? Vminitd else {
                    throw NapboxError(.internalError, "虚拟机里的代理不是 vminitd")
                }
                do {
                    try await vminitd.sysctl(settings: settings)
                } catch {
                    try? await vminitd.close()
                    throw error
                }
                try? await vminitd.close()
            }
        } catch {
            let text = settings.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "、")
            throw NapboxError(.serviceFailed, "写虚拟机的内核设置 \(text) 失败（环境可能停了）：\(error)")
        }
    }

    // MARK: - 出网规则

    /// 在网络小容器里换掉整个环境的出网规则。open 模式带上宿主机当前的地址一起挡。
    /// 只有这条命令带网络管理权限 NET_ADMIN，网络小容器的 1 号进程和项目的服务都没有（Containerization 默认的权限里没有它）。
    /// 失败时规则保持原样（napbox-guard 一次事务换完）。
    public func applyEgress(_ mode: EgressMode) async throws(NapboxError) {
        // open 模式要经网关出网和查 DNS：网关不在虚拟机的网络上时直接说清楚，不等服务里的请求慢慢超时
        if mode == .open { try await checkGateway() }
        try await replaceEgressRules(mode)
    }

    /// 网关在不在这台虚拟机的网络上。虚拟机开着时所在网段不会变：新起、唤醒、切回 open 时查一次就够
    private func checkGateway() async throws(NapboxError) {
        let (code, output) = await exec(GuardContainer.name, [GuardContainer.program, "gateway", AddressAllocator.gateway], timeout: 10)
        switch code {
        case 0: return
        // -1 是这条命令没跑起来或超时（exec），和网关通不通无关
        case -1: throw NapboxError(.runtimeUnavailable, "在虚拟机里查网关失败：\(output)")
        default: throw AddressAllocator.gatewayUnreachable(output.isEmpty ? "退出码 \(code)" : output)
        }
    }

    private func replaceEgressRules(_ mode: EgressMode) async throws(NapboxError) {
        let hosts = mode == .open ? EgressRules.uncovered(try HostAddresses.current()) : []
        let argv = [GuardContainer.program, "egress"] + EgressRules.guardArguments(mode, hostAddresses: hosts)
        let (code, output) = await exec(GuardContainer.name, argv, timeout: 10, capabilities: LinuxCapabilities(capabilities: [.netAdmin]))
        if code != 0 {
            throw NapboxError(.runtimeUnavailable, "加出网规则（\(mode.rawValue)）失败：\(output.isEmpty ? "退出码 \(code)" : output)")
        }
        egress = mode
        blockedHostAddresses = hosts
    }

    /// 宿主机的地址可能变了（换网络、重启 Clash、连 VPN）：open 模式下要单独挡的地址变了就重新加规则。
    /// 不再查网关：进 open 时已经查过，虚拟机所在网段没变
    public func refreshHostAddresses() async throws(NapboxError) {
        guard egress == .open, EgressRules.uncovered(try HostAddresses.current()) != blockedHostAddresses else { return }
        try await replaceEgressRules(.open)
    }

    // MARK: - 就绪

    /// 有 healthcheck 的执行它；没有的，有端口就查端口是否在监听；没有端口的，进程在运行（或已成功退出）就算起来了。
    /// 返回按哪种判断就绪的。
    private func waitReady(_ s: Service) async throws(NapboxError) -> ServiceRun.Readiness {
        if s.healthcheck != nil {
            try await waitHealthy(s)
            return .healthcheck
        } else if !s.listeningPorts.isEmpty {
            try await waitListening(s)
            return .port
        } else {
            try await pause(0.5)
            if let code = exits[s.name], code != 0 { throw failed(s.name, code) }
            return .process
        }
    }

    private func waitHealthy(_ s: Service) async throws(NapboxError) {
        if healthy.contains(s.name) { return }
        guard let hc = s.healthcheck else { return }
        let started = Date()
        var failures = 0
        var lastOutput = ""
        while true {
            if let code = exits[s.name] { throw failed(s.name, code) }
            let (ok, output) = await probe(s.name, hc)
            if ok {
                healthy.insert(s.name)
                return
            }
            lastOutput = output
            let inStartPeriod = Date().timeIntervalSince(started) < hc.startPeriodSeconds
            if !inStartPeriod {
                failures += 1
                if failures >= max(hc.retries, 1) {
                    throw NapboxError(.healthcheckTimeout, "\(s.name) 的 healthcheck 连续 \(failures) 次没通过。最后一次的输出：\(lastOutput.isEmpty ? "（没有输出）" : lastOutput)\(logTail(s.name))")
                }
            }
            try await pause(inStartPeriod ? hc.startIntervalSeconds : hc.intervalSeconds)
        }
    }

    private func waitListening(_ s: Service) async throws(NapboxError) {
        let deadline = Date().addingTimeInterval(Self.listenTimeout)
        while Date() < deadline {
            if let code = exits[s.name] { throw failed(s.name, code) }
            let (code, output) = await exec(GuardContainer.name, [GuardContainer.program, "listening", s.name], timeout: 5)
            if code == 0 {
                let listening = Set(output.split(separator: "\n").compactMap { Int($0) })
                if s.listeningPorts.allSatisfy(listening.contains) { return }
            }
            try await pause(0.2)
        }
        throw NapboxError(.healthcheckTimeout, "\(s.name) 启动 \(Int(Self.listenTimeout)) 秒后还没在 \(s.listeningPorts.map(String.init).joined(separator: "、")) 端口上监听\(logTail(s.name))")
    }

    private func waitCompleted(_ s: Service) async throws(NapboxError) {
        let deadline = Date().addingTimeInterval(Self.completionTimeout)
        while Date() < deadline {
            if let code = exits[s.name] {
                if code == 0 { return }
                throw failed(s.name, code)
            }
            try await pause(0.2)
        }
        throw NapboxError(.healthcheckTimeout, "\(s.name) 是别的服务要等它跑完的一次性服务，\(Int(Self.completionTimeout)) 秒后还没结束\(logTail(s.name))")
    }

    // MARK: - 工具

    private func probe(_ name: String, _ hc: Healthcheck) async -> (Bool, String) {
        let argv: [String] = switch hc.test {
        case .exec(let a): a
        case .shell(let cmd): ["/bin/sh", "-c", cmd]
        }
        let (code, output) = await exec(name, argv, timeout: hc.timeoutSeconds)
        return (code == 0, output)
    }

    /// 在容器里执行一条命令，返回退出码和输出；超时或执行不了时退出码是 -1。
    /// - timeout：nil 是一直等到它结束
    /// - capabilities：不给就沿用容器主进程的权限
    private func exec(_ container: String, _ argv: [String], timeout: Double?, capabilities: LinuxCapabilities? = nil, asRoot: Bool = false) async -> (Int32, String) {
        let output = CaptureWriter()
        let process: LinuxProcess
        do {
            process = try await pod.execInContainer(container, processID: "napbox-\(UUID().uuidString.prefix(8))") { c in
                c.arguments = argv
                if let capabilities { c.capabilities = capabilities }
                if asRoot { c.user = .init(uid: 0, gid: 0) }
                c.stdout = output
                c.stderr = output
            }
        } catch {
            return (-1, "\(error)")
        }
        // 建好之后不管启动成没成功、有没有超时，都要删掉，否则健康检查反复失败时会越积越多
        defer { Task { try? await process.delete() } }
        do {
            try await process.start()
            let status = try await process.wait(timeoutInSeconds: timeout.map { Int64(max(1, $0.rounded(.up))) })
            return (status.exitCode, output.text)
        } catch let error as ContainerizationError where error.isCode(.timeout) {
            await killGroup(process)
            return (-1, "超时（\(timeout ?? 0) 秒）")
        } catch {
            return (-1, "\(error)")
        }
    }

    /// 结束一条已经启动的命令和它的子进程。exec 起的进程是进程组组长（Containerization 的 vmexec 启动时 setsid），
    /// 子进程默认同组；process.kill 只发给组长，子进程会变成孤儿留下。
    /// 用 setsid 自己脱离出去的进程不在这个组里，留到环境停止时随虚拟机结束。
    private nonisolated func killGroup(_ process: LinuxProcess) async {
        try? await pod.withVirtualMachineInstance { vm in
            let agent = try await vm.dialAgent()
            _ = try? await agent.kill(pid: -process.pid, signal: Signal.kill.rawValue)
            try? await agent.close()
        }
    }

    private func failed(_ name: String, _ code: Int32) -> NapboxError {
        NapboxError(.serviceFailed, "\(name) 退出了，退出码 \(code)\(logTail(name))")
    }

    private func logTail(_ name: String) -> String {
        guard let tail = logs[name]?.tail(20), !tail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return "" }
        return "。最后的日志：\n\(tail)"
    }

    /// 启动时等服务就绪的间隔。虚拟机没了就不用等到超时
    private func pause(_ seconds: Double) async throws(NapboxError) {
        do { try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) } catch {
            throw NapboxError(.internalError, "被取消")
        }
        if vmLost { throw NapboxError(.runtimeUnavailable, "启动过程中虚拟机意外停了") }
    }
}

final class CaptureWriter: Writer, @unchecked Sendable {
    private var data = Data()
    private let lock = NSLock()

    func write(_ d: Data) throws {
        lock.lock()
        defer { lock.unlock() }
        data.append(d)
    }

    func close() throws {}

    var text: String {
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// exec 的命令、napbox run 的前台服务的标准输入
final class StreamReader: ReaderStream, Sendable {
    let source: AsyncStream<Data>

    init(stream: AsyncStream<Data>) { source = stream }

    func stream() -> AsyncStream<Data> { source }
}

/// exec 的命令、napbox run 的前台服务的输出：原样排进 ExecOutput，积压到上限时在这里等
final class OutputWriter: Writer, Sendable {
    let stream: StreamOutput.Stream
    let output: ExecOutput

    init(stream: StreamOutput.Stream, output: ExecOutput) {
        self.stream = stream
        self.output = output
    }

    func write(_ data: Data) throws {
        if !data.isEmpty { output.write(StreamOutput(stream: stream, data: data)) }
    }

    func close() throws {}
}
