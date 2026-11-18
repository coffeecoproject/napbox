// napboxd 的状态和请求分发。各部分按功能分在 Daemon+*.swift 里（同一个 actor）：up 和 create、唤醒和休眠、出网、回收、restart、
// logs/exec。
import Foundation
import NIOCore
import NapboxCore
import NapboxProtocol
import NapboxRuntime

actor Daemon {
    let startedAt = Date()
    let store: StateStore
    /// 登记过的端口一直锁着，环境休眠时也不放开
    let locks = PortLocks()
    let runtime: Runtime
    /// 正在运行的环境
    var running: [String: RunningEnvironment] = [:]
    /// 连接触发的、正在进行的唤醒：同时进来的连接等同一次唤醒，各自等自己的服务就绪
    var wakeups: [String: StartProgress] = [:]
    /// 每个环境的 vsock 转发通道，连同它属于哪个 RunningEnvironment
    var relays: [String: (environment: ObjectIdentifier, connecting: Task<RelayMux, Error>)] = [:]
    /// 每个环境的端口监听（宿主机端口 → 监听 channel，127.0.0.1 和 [::1] 各一个），从登记到回收一直在
    var listeners: [String: [Int: [Channel]]] = [:]
    /// 正在转发的连接，休眠时断开
    let connections = ConnectionBoard()
    /// 代理上最后一次有数据往来的时间，判断闲置用
    let activity = ActivityBoard()
    /// 发给 subscribe 连接的事件
    let events = EventHub()
    /// 每个登记的环境的起停记录：失败、服务退出、重启退避
    var sessions: [String: EnvSession] = [:]
    /// 在跑的环境的 develop.watch 监听
    var watchSessions: [String: WatchSession] = [:]
    /// 同时唤醒的环境数（meetingSum 实测 6 个同时唤醒基本不变慢）
    let wakeSlots = Slots(limit: 6)
    /// 同一个环境的操作排队执行（up 要等很久，期间别的请求照常处理）
    var queues: [String: Task<Void, Never>] = [:]
    /// 收到 SIGTERM 后不再起环境、不再回收：这时进来的连接、up、down 请求直接拒绝，免得虚拟机起到一半、
    /// 数据移到一半进程就退出
    var shuttingDown = false
    /// 正在起环境之前准备（构建、拉镜像）的环境：这段时间不碰环境的虚拟机，退出时不用等（shutdown）
    var preparing: Set<String> = []
    /// 定时检查（闲置、worktree 删除、保留期），退出时取消
    var periodic: [Task<Void, Never>] = []

    /// 闲置多久休眠的默认值，项目用 x-napbox.idle_minutes 覆盖
    static let defaultIdleMinutes = 30
    /// 多久检查一次闲置
    static let idleCheckSeconds: UInt64 = 10
    /// 多久检查一次 worktree 是不是删掉了
    static let worktreeCheckSeconds: UInt64 = 60
    /// 多久清理一次 recycled 下保留期满的数据
    static let purgeCheckSeconds: UInt64 = 3600
    /// 起环境失败后这段时间内的新连接直接断开
    static let launchFailureCooldown: TimeInterval = 10

    /// 读状态文件，把登记过的端口重新锁上。锁不上的（napboxd 没运行期间被别的程序占了，或者本机回环监听不了）记进日志，
    /// 那个环境下次起的时候再试，还不行就报错说明。
    /// - programs：napboxd 所在的目录，napbox-guard 和建盘的 mke2fs 这些和它放在一起
    init(supportDirectory: URL, programs: URL) throws(NapboxError) {
        store = try StateStore(url: supportDirectory.appending(path: "state.json"))
        runtime = Runtime(supportDirectory: supportDirectory, programs: programs)
        for env in store.state.environments {
            for a in env.ports {
                do {
                    if try !locks.lock(a.hostPort) {
                        print("环境 \(env.name) 的 \(a.service):\(a.containerPort) 登记的端口 \(a.hostPort) 被别的程序占着，没锁上")
                    }
                } catch {
                    print("环境 \(env.name) 的 \(a.service):\(a.containerPort) 登记的端口 \(a.hostPort) 没锁上：\(error.message)")
                }
            }
        }
        let count = store.state.environments.reduce(0) { $0 + $1.ports.count }
        print("读到 \(store.state.environments.count) 个环境，锁上 \(locks.lockedPorts.count)/\(count) 个端口")
    }

    /// 启动后、处理请求之前调用：先把上次没做完的回收和 reset 做完、删掉没有登记的环境留下的构建结果，
    /// 再回收 napboxd 没运行期间 worktree 被删掉的环境、销毁上次留下的临时环境、清理保留期满的数据，
    /// 最后给登记过的环境开始监听端口（有连接进来就唤醒）；之后定时检查闲置、worktree 删除和保留期。
    func begin() async {
        await finishPendingOperations()
        await reclaimDeletedWorktrees()
        await destroyLeftoverTemporaries()
        await purgeRecycled()
        for env in store.state.environments { await syncListeners(env.name) }
        repeatEvery(Self.idleCheckSeconds) { await $0.sleepIdleEnvironments() }
        repeatEvery(Self.worktreeCheckSeconds) { await $0.reclaimDeletedWorktrees() }
        repeatEvery(Self.purgeCheckSeconds) { await $0.purgeRecycled() }
    }

    func repeatEvery(_ seconds: UInt64, _ body: @escaping @Sendable (Daemon) async -> Void) {
        periodic.append(Task {
            while true {
                do { try await Task.sleep(nanoseconds: seconds * 1_000_000_000) } catch { return } // 取消了
                await body(self)
            }
        })
    }

    /// 处理一行请求，返回一行回应（不含换行）。请求本身解析不了时 id 记为 0。
    func respond(to line: Data) async -> Data {
        let response: Response
        do {
            let request = try Wire.decoder.decode(Request.self, from: line)
            response = await handle(request)
        } catch {
            response = Response(id: 0, error: NapboxError(.badRequest, "请求不是有效的 JSON 或缺少 id、method：\(error)"))
        }
        do {
            return try Wire.encoder.encode(response)
        } catch {
            return Data(#"{"id":0,"error":{"code":"protocol_error","message":"回应编码失败"}}"#.utf8)
        }
    }

    func handle(_ request: Request) async -> Response {
        await Requests.respond(to: request) {
            switch request.method {
            case Method.status:
                return try Wire.value(status())
            case Method.up:
                return try Wire.value(try await up(try Requests.params(UpParams.self, request)))
            case Method.create:
                return try Wire.value(try await create(try Requests.params(CreateParams.self, request)))
            case Method.wake:
                return try Wire.value(try await wake(try Requests.params(EnvironmentParams.self, request)))
            case Method.sleep:
                return try Wire.value(try await sleep(try Requests.params(EnvironmentParams.self, request)))
            case Method.environment:
                return try Wire.value(info(try await record(for: try Requests.params(EnvironmentParams.self, request).target)))
            case Method.runs:
                return try Wire.value(try await runs(try Requests.params(EnvironmentParams.self, request)))
            case Method.egress:
                return try Wire.value(try await egress(try Requests.params(EgressParams.self, request)))
            case Method.reset:
                return try Wire.value(try await reset(try Requests.params(ResetParams.self, request)))
            case Method.down:
                return try Wire.value(try await down(try Requests.params(DownParams.self, request)))
            default:
                throw Requests.unknownMethod(request)
            }
        }
    }

    // MARK: - status

    func status() -> StatusResult {
        StatusResult(
            version: NapboxVersion.current, pid: getpid(), startedAt: startedAt,
            environments: store.state.environments.map(info).sorted { $0.name < $1.name }
        )
    }

    func info(_ record: EnvironmentRecord) -> EnvironmentInfo {
        let active = record.activePorts
        let ports = active.map {
            PortInfo(service: $0.service, containerPort: $0.containerPort, hostPort: $0.hostPort, variable: PortVariables.name(of: $0))
        }
        let host = record.hostPorts ?? []
        return EnvironmentInfo(
            name: record.name, owner: record.owner.callerID, state: running[record.name] == nil ? .sleeping : .running,
            worktree: record.worktree,
            ports: ports, hostPorts: host.map { HostPortInfo(name: $0.name, hostPort: $0.hostPort, variable: HostPortVariables.name(of: $0)) },
            egress: record.egress,
            hostname: record.hostname,
            variables: PortVariables.all(active, hostname: record.hostname, hostPorts: host),
            unsetVariables: record.definition?.unsetVariables ?? [],
            lastError: sessions[record.name]?.lastFailure?.message, serviceExits: sessions[record.name]?.exits ?? [],
            watchError: sessions[record.name]?.watchError,
            snapshotError: record.snapshotSkipped?.summary,
            confined: record.confinedRoot != nil ? true : nil
        )
    }

    /// 按 target 找登记的环境：
    /// - 目录：这个 worktree 的开发环境，带了临时环境的名字就是那个临时环境（都是 worktree 持有的）。
    ///   目录是调用方持有的环境的代码副本时拒绝，那个环境只能由调用方操作
    /// - 名字：这个名字的环境，持有方要对上
    func record(for target: EnvironmentTarget) async throws(NapboxError) -> EnvironmentRecord {
        switch target {
        case .directory(let cwd, let temporary):
            let location = try await Blocking.run { () throws(NapboxError) in try WorktreeLocation.locate(from: URL(fileURLWithPath: cwd)) }
            let path = location.worktree.path
            if let record = store.state.environment(worktree: path, temporary: temporary) { return record }
            try requireNotCallerDirectory(path)
            if let temporary {
                throw NapboxError(.environmentNotFound, "\(path) 没有叫 \(temporary) 的临时环境（临时环境停下来就销毁了），先 napbox up --temp \(temporary)")
            }
            throw NapboxError(.environmentNotFound, "\(path) 没有环境，先 napbox up")
        case .named(let name, let owner):
            guard let record = store.state.environment(name) else { throw NapboxError(.environmentNotFound, "没有环境 \(name)") }
            guard record.owner == .caller(id: owner) else {
                let holder = record.owner.callerID.map { "由 \($0) 持有" } ?? "由 worktree \(record.worktree) 持有"
                throw NapboxError(.ownerMismatch, "环境 \(name) \(holder)，不归 \(owner)")
            }
            return record
        }
    }

    /// 命令行在调用方持有的环境的代码副本里时拒绝：那个环境只能由调用方通过接口操作，也不能再在这里 up 出另一个环境
    func requireNotCallerDirectory(_ path: String) throws(NapboxError) {
        guard let record = store.state.environments.first(where: { $0.owner.callerID != nil && $0.worktree == path }),
              let owner = record.owner.callerID else { return }
        throw NapboxError(.ownerMismatch, "\(path) 是 \(owner) 持有的环境 \(record.name) 的代码副本，这个环境只能由 \(owner) 通过接口操作")
    }

    /// 环境的运行记录
    func runs(_ params: EnvironmentParams) async throws(NapboxError) -> RunsResult {
        let record = try await record(for: params.target)
        let runtime = runtime
        return RunsResult(runs: try await Blocking.run { () throws(NapboxError) in try runtime.runs(record) })
    }

    // MARK: - 事件

    /// 发一条事件，持有方按登记填
    func emit(_ name: String, _ type: EnvironmentEvent.Kind, _ fill: (inout EnvironmentEvent) -> Void = { _ in }) {
        var event = EnvironmentEvent(at: Date(), environment: name, owner: store.state.environment(name)?.owner.callerID, type: type)
        fill(&event)
        events.emit(event)
    }

    // MARK: - 退出

    static let exiting = NapboxError(.daemonUnavailable, "napboxd 正在退出")

    /// 收到 SIGTERM 时先把运行中的环境停掉（数据卷正常卸载），再退出。之后不再起环境。各环境同时停，
    /// 系统等不了太久。正在进行的 up、唤醒排在前面，等它们结束再停，不会留下起到一半的虚拟机；
    /// 只有还在准备镜像的不等：拉镜像可能要很久、取消不了，也不碰环境的虚拟机，拉完会发现正在退出（prepare）；
    /// 构建由 stopBuilder 直接停掉（构建虚拟机也要让引擎先退出再关）。
    func shutdown() async {
        shuttingDown = true
        for task in periodic { task.cancel() }
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await self.runtime.stopBuilder() }
            for name in Set(queues.keys).union(running.keys) {
                group.addTask { await self.stopForExit(name) }
            }
        }
    }

    private func stopForExit(_ name: String) async {
        if preparing.contains(name) {
            await stopRunning(name, sleep: .shutdown)
        } else {
            try? await serialized(name) { () throws(NapboxError) in await self.stopRunning(name, sleep: .shutdown) }
        }
    }

    // MARK: - 排队

    /// 同一个环境的操作一个接一个执行。
    func serialized<T: Sendable>(_ name: String, _ body: @escaping @Sendable () async throws(NapboxError) -> T) async throws(NapboxError) -> T {
        let previous = queues[name]
        let task = Task { () async -> Result<T, NapboxError> in
            await previous?.value
            do throws(NapboxError) { return .success(try await body()) } catch { return .failure(error) }
        }
        let tail = Task { _ = await task.value }
        queues[name] = tail
        let result = await task.value
        if queues[name] == tail { queues[name] = nil } // 后面没有再排的：这个环境现在没有在进行的操作
        return try result.get()
    }
}

/// 一个登记的环境在 napboxd 里的起停记录（不存盘，napboxd 重启后从头算），回收时整个丢掉。
/// 运行中的虚拟机（running）和端口监听（listeners）是要停、要关的资源，单独放。
struct EnvSession {
    /// 最近一次起环境失败（up、唤醒、reset、按 restart 重启都算）：冷却期内连接进来不再自动唤醒
    var lastFailure: (at: Date, message: String)?
    /// 运行中退出过的服务，最近 10 条（status 里看）
    var exits: [ServiceExit] = []
    var restart = RestartTracker()
    /// develop.watch 最近一批同步失败的原因，下一批成功后清掉
    var watchSyncError: String?
    /// develop.watch 最近一次重建失败的原因。和同步分开：之后同步成功不代表镜像是新的，下次构建成功才清
    var watchBuildError: String?
    /// status 里看的
    var watchError: String? {
        let errors = [watchBuildError, watchSyncError].compactMap { $0 }
        return errors.isEmpty ? nil : errors.joined(separator: "\n")
    }
}
