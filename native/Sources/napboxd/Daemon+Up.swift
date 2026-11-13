// up、create、reset：登记环境、起环境（launch 是唤醒、按 restart 重启共用的那一步）。
import Foundation
import NIOCore
import NapboxCore
import NapboxProtocol
import NapboxRuntime

extension Daemon {
    // MARK: - up

    /// 创建或重新启动当前 worktree 的环境，服务都就绪后返回端口和环境变量。
    /// 给了 temp 时是这个 worktree 的临时环境。
    func up(_ params: UpParams) async throws(NapboxError) -> EnvironmentInfo {
        if let temp = params.temp { try TemporaryEnvironment.validate(name: temp) }
        let cwd = URL(fileURLWithPath: params.cwd)
        let location = try await Blocking.run { () throws(NapboxError) in try WorktreeLocation.locate(from: cwd) }
        try requireNotCallerDirectory(location.worktree.path)
        let files = try ComposeFiles.resolve(explicit: params.files, environment: params.environment, cwd: cwd, worktree: location.worktree)
        let project = try loadCompose(files, environment: params.environment, profiles: params.profiles)
        return try await startInWorktree(location, temporary: params.temp, project: project, egress: nil, rebuild: params.build)
    }

    /// up 和 run 共用：起这个 worktree 的环境（temporary 不是 nil 时是它的临时环境）。
    func startInWorktree(_ location: WorktreeLocation, temporary: String?, project: ComposeProject, egress: EgressMode?,
                         rebuild: Bool, foreground: ForegroundService? = nil) async throws(NapboxError) -> EnvironmentInfo {
        // 环境名在排队前按当时的登记算：排队期间同一个项目里同名的另一个 worktree 可能先登记了这个名字，
        // 这时按新的登记重新算名字、重新排队
        var name = store.state.environmentName(for: location, temporary: temporary)
        while true {
            let queued = name
            let started = try await serialized(queued) { () throws(NapboxError) -> EnvironmentInfo? in
                try await self.start(name: queued, location: location, temporary: temporary, project: project, egress: egress,
                                     rebuild: rebuild, foreground: foreground)
            }
            if let started { return started }
            name = store.state.environmentName(for: location, temporary: temporary)
        }
    }

    /// - run：napbox run 时只留其中一个服务和它依赖的
    func loadCompose(_ files: [URL], environment: [String: String], profiles: [String],
                     run: ComposeRun? = nil) throws(NapboxError) -> ComposeProject {
        do {
            return try ComposeLoader.load(ComposeInput(files: files, callerEnvironment: environment, profiles: profiles, run: run))
        } catch {
            throw error.napboxError
        }
    }

    /// 名字已经被别的环境占了时返回 nil
    func start(name: String, location: WorktreeLocation, temporary: String?, project: ComposeProject, egress: EgressMode?,
               rebuild: Bool, foreground: ForegroundService?) async throws(NapboxError) -> EnvironmentInfo? {
        if let existing = store.state.environment(name),
           existing.owner != .worktree || existing.worktree != location.worktree.path || existing.temporary != temporary { return nil }
        let registered: EnvironmentRecord
        do {
            registered = try await bringUp(name, project: project, egress: egress, rebuild: rebuild, foreground: foreground) { state in
                EnvironmentRecord(
                    name: name, project: state.projectName(for: location.mainRepository), mainRepository: location.mainRepository.path,
                    worktree: location.worktree.path, owner: .worktree, temporary: temporary
                )
            }
        } catch {
            // 临时环境还没登记就失败了（构建到一半、镜像拉不下来）：已经构建出来的镜像没有环境可跟着销毁，这里删。
            // 登记以后才失败的，launch 已经把它整个销毁、镜像也删了；那时登记同样不在，这里再删一遍是空的
            if temporary != nil, store.state.environment(name) == nil { await removeBuiltImages(name) }
            throw error
        }
        // ports.json 只写开发环境的：临时环境的端口在返回值里，也可以 napbox env --temp 再取
        if temporary == nil {
            try await Blocking.run { () throws(NapboxError) in
                try PortsFile.write(environment: name, ports: registered.activePorts, worktree: location.worktree)
            }
        }
        return info(registered)
    }

    // MARK: - create（调用方持有的环境）

    /// 调用方创建环境。名字由调用方给；同名、同持有方、同目录再调用时定义没变就保证它在运行（在运行的直接返回，
    /// 休眠的唤醒），定义变了整个环境重启；持有方或目录不同时报 name_taken。
    /// 代码副本里不写 .napbox/ports.json：端口和变量都在返回值里。
    func create(_ params: CreateParams) async throws(NapboxError) -> EnvironmentInfo {
        try CallerEnvironment.validate(name: params.name, owner: params.owner)
        let directory = try CallerEnvironment.directory(params.directory)
        let files = try ComposeFiles.resolve(explicit: params.files, environment: params.environment, cwd: directory, worktree: directory)
        let project = try loadCompose(files, environment: params.environment, profiles: params.profiles)
        let name = params.name, owner = EnvironmentRecord.Owner.caller(id: params.owner), egress = params.egress
        return try await serialized(name) { () throws(NapboxError) in
            try await self.startCaller(name, owner: owner, directory: directory, project: project, egress: egress)
        }
    }

    func startCaller(_ name: String, owner: EnvironmentRecord.Owner, directory: URL, project: ComposeProject,
                     egress: EgressMode?) async throws(NapboxError) -> EnvironmentInfo {
        // 只起了临时环境的 worktree 也占着它开发环境的名字（NapboxState.holder）
        if let existing = store.state.holder(of: name) {
            guard existing.name == name, existing.owner == owner, existing.worktree == directory.path else {
                let holder = existing.owner.callerID.map { "\($0) 持有" } ?? "worktree 持有"
                throw NapboxError(.nameTaken, "环境名 \(name) 已经被占了：\(holder)，代码目录 \(existing.worktree)")
            }
            // 调用方重启后再 create 碰到的都是休眠的环境：定义没变就只是唤醒，建库、导入数据这些一次性服务不重跑
            if running[name] == nil, existing.definition == project {
                if shuttingDown { throw Self.exiting }
                if let egress, egress != existing.egress { _ = try await setEgress(name, egress) }
                try await wakeNow(name, cooldown: false)
                return info(store.state.environment(name)!)
            }
        }
        return info(try await bringUp(name, project: project, egress: egress, rebuild: false) { _ in
            EnvironmentRecord(name: name, project: nil, mainRepository: nil, worktree: directory.path, owner: owner)
        })
    }

    // MARK: - 起环境

    /// up 和 create 共用：已经在运行、定义和镜像都没变、服务都在就不重启（只按要求换出网模式）；否则整个环境重新起
    /// （单个服务不能单独重启），一次性服务重跑。准备好了才停旧环境：
    /// secrets 的文件不在、构建失败、镜像名写错、端口被占这类失败不影响在跑的环境，登记和定义也不变。
    /// - egress：要切到的出网模式，nil 是不变（新环境 open）
    /// - rebuild：up --build，写了 build 的服务都重新构建
    /// - foreground：napbox run 在前台跑的那个服务
    /// - newRecord：还没登记时的新登记
    func bringUp(_ name: String, project: ComposeProject, egress: EgressMode?, rebuild: Bool, foreground: ForegroundService? = nil,
                 newRecord: (NapboxState) -> EnvironmentRecord) async throws(NapboxError) -> EnvironmentRecord {
        if shuttingDown { throw Self.exiting }
        let startedAt = Date()
        let rebuilt: Bool
        do {
            // 不用等的先查：挂载的来源不成立时不必先花时间构建
            try runtime.checkHostMounts(project)
            rebuilt = try await buildImages(name, project: project, force: rebuild)
            if rebuild { sessions[name]?.watchBuildError = nil }
        } catch {
            await preparationFailed(name, project: project, startedAt: startedAt, error: error)
            throw error
        }
        if !rebuilt, running[name] != nil, let registered = store.state.environment(name), registered.definition == project {
            if let egress, egress != registered.egress { _ = try await setEgress(name, egress) }
            try await restartStoppedServices(name, purpose: .up)
            // 环境在跑，定义也是要的这份：之前准备失败时记下的错误已经不成立了
            sessions[name]?.lastFailure = nil
            return store.state.environment(name)!
        }
        let record: EnvironmentRecord
        do {
            record = try await prepare(name, project: project, egress: egress, newRecord: newRecord)
        } catch {
            await preparationFailed(name, project: project, startedAt: startedAt, error: error)
            throw error
        }
        // 定义已经换了：旧环境跑完的一次性服务不算数，不能写回登记（起新环境失败时，下次唤醒会错误地跳过它们）
        await stopRunning(name, keepCompleted: false)
        try await launch(record, project: project, skipping: [], purpose: .up, foreground: foreground)
        return store.state.environment(name)!
    }

    /// up、create、wake 要保证服务都在：环境在跑，但有服务不该停却停了（restart 不管的退出）时，整个环境重启
    /// （单个服务不能单独重启），跳过已经跑完的一次性服务。
    func restartStoppedServices(_ name: String, purpose: RunRecord.Purpose) async throws(NapboxError) {
        guard let env = running[name] else { return }
        let stopped = await env.stoppedServices
        guard !stopped.isEmpty else { return }
        print("环境 \(name) 的 \(stopped.joined(separator: "、")) 已经退出了，整个环境重启")
        await stopRunning(name)
        guard let record = store.state.environment(name), let project = record.definition else {
            throw NapboxError(.environmentNotFound, "环境 \(name) 没有登记或没有定义")
        }
        try await launch(record, project: project, skipping: Set(record.completedServices), purpose: purpose)
    }

    /// 全新的环境还没登记，没有地方放运行记录，也还没有人订阅它的状态：只靠这次调用返回的错误
    private func preparationFailed(_ name: String, project: ComposeProject, startedAt: Date, error: NapboxError) async {
        guard let registered = store.state.environment(name) else { return }
        await startFailed(registered, project: project, purpose: .up, startedAt: startedAt, error: error)
    }

    /// 写了 build 的服务要构建的先构建（可能很久，也不碰在跑的环境）。返回有没有镜像变了。
    private func buildImages(_ name: String, project: ComposeProject, force: Bool) async throws(NapboxError) -> Bool {
        preparing.insert(name)
        defer { preparing.remove(name) }
        return try await runtime.buildImages(project, environment: name, force: force)
    }

    /// 起环境之前的准备：拉镜像并查镜像和 compose 合起来成不成立、分配地址和端口，把新定义写进登记。全程不碰在跑的环境。
    /// 从分配地址到写登记之间不能有等待：别的名字的环境不在同一个队列里，它们看不到还没登记的地址和端口，
    /// 会分到同一个。
    private func prepare(_ name: String, project: ComposeProject, egress: EgressMode?,
                         newRecord: (NapboxState) -> EnvironmentRecord) async throws(NapboxError) -> EnvironmentRecord {
        // 这段可能很久，也取消不了，napboxd 退出时不等它（shutdown）；等完了再看要不要继续
        preparing.insert(name)
        defer { preparing.remove(name) }
        try await runtime.prepareImages(project, environment: name)
        let requests = project.portRequests
        let neighbors = await Blocking.run { NetworkNeighbors.addresses() }
        if shuttingDown { throw Self.exiting }
        let ip = try AddressAllocator.allocate(environment: name, state: store.state, inUseOnNetwork: neighbors)
        let ports = try PortAllocator.assign(requests, environment: name, state: store.state, locks: locks)
        return try store.update { (state: inout NapboxState) throws(NapboxError) -> EnvironmentRecord in
            var r = state.environment(name) ?? newRecord(state)
            r.ports = ports
            r.ip = ip
            r.definition = project
            r.completedServices = []
            if let egress { r.egress = egress }
            state.environments.removeAll { $0.name == name }
            state.environments.append(r)
            return r
        }
    }

    /// 起环境（up、create、唤醒、reset、按 restart 重启都走这里），起来后补上 develop.watch 没跑这段时间的变化，
    /// 登记成运行中，再开始接它的服务退出通知（先登记再接：每条通知都能对上 running 里的环境）。成功失败都留一条运行记录、发一条事件；失败时记下原因，
    /// 冷却期内自动唤醒不再试。各入口共同的前提都在这里查：napboxd 不在退出、登记的端口都锁得上。
    /// 临时环境起不来就整个销毁：它没有休眠，不留一个停着的。
    /// - purpose：这次是为什么起。按 restart 重启时保留退避和重启次数，别的情况重新算
    /// - foreground：napbox run 在前台跑的那个服务
    /// - progress：起到哪了（唤醒时连接等自己的服务就绪用）
    func launch(_ record: EnvironmentRecord, project: ComposeProject, skipping: Set<String>,
                purpose: RunRecord.Purpose, foreground: ForegroundService? = nil,
                progress: StartProgress = StartProgress()) async throws(NapboxError) {
        if shuttingDown { throw Self.exiting }
        let name = record.name
        let trace = RunTrace()
        let startedAt = Date()
        let runId = Self.newRunId()
        let env: RunningEnvironment
        do {
            try lockPorts(record)
            // 先开始监听：起环境期间进来的连接排队等着，唤醒时等它连的服务就绪就转发（route）
            await syncListeners(name)
            env = try await runtime.start(record, project: project, skipping: skipping, foreground: foreground, trace: trace,
                                          progress: progress)
        } catch {
            await startFailed(record, project: project, id: runId, purpose: purpose, startedAt: startedAt, error: error, trace: trace)
            if record.temporary != nil { await destroyTemporary(name, reason: "\(Self.description(purpose))失败") }
            throw error
        }
        await saveRun(record, project: project, id: runId, purpose: purpose, startedAt: startedAt, error: nil, trace: trace)
        sessions[name, default: EnvSession()].lastFailure = nil
        sessions[name, default: EnvSession()].restart.launched(at: Date(), restarting: purpose == .restart)
        // 没跑的这段时间改的文件先同步进去，再登记成运行中：登记之后进来的连接直接转发
        let followUp = await startWatching(record, env, project: project)
        running[name] = env
        activity.touch(name)
        // 先发 started 再接退出通知：调用方收到的顺序和发生的顺序一致
        emit(name, .started) {
            $0.purpose = purpose
            $0.runId = runId
        }
        await env.deliverExits { [weak self] env, service, code in
            Task { await self?.serviceExited(name, env, service, code) }
        } vmLost: { [weak self] env in
            Task { await self?.vmLost(name, env) }
        }
        await saveCompleted(name, env)
        await finishWatching(followUp, name, env)
    }

    /// 这次起环境失败了（可能还没走到 launch）：留运行记录、记下原因（冷却、status 用）、发事件。
    private func startFailed(_ record: EnvironmentRecord, project: ComposeProject, id: String = Daemon.newRunId(),
                             purpose: RunRecord.Purpose, startedAt: Date, error: NapboxError, trace: RunTrace = RunTrace()) async {
        await saveRun(record, project: project, id: id, purpose: purpose, startedAt: startedAt, error: error, trace: trace)
        sessions[record.name, default: EnvSession()].lastFailure = (Date(), "\(Self.description(purpose))失败：\(error.message)")
        emit(record.name, .startFailed) {
            $0.purpose = purpose
            $0.runId = id
            $0.error = error
        }
    }

    private static func newRunId() -> String { UUID().uuidString.lowercased() }

    private static func description(_ purpose: RunRecord.Purpose) -> String {
        switch purpose {
        case .up: "up 时起环境"
        case .wake: "唤醒"
        case .reset: "reset 后重新起环境"
        case .restart: "服务退出后重启"
        }
    }

    /// 运行记录写不下去不影响环境本身，记进日志
    private func saveRun(_ record: EnvironmentRecord, project: ComposeProject, id: String, purpose: RunRecord.Purpose,
                         startedAt: Date, error: NapboxError?, trace: RunTrace) async {
        let run = RunRecord(
            id: id, environment: record.name, purpose: purpose, startedAt: startedAt, finishedAt: Date(), error: error,
            definitionDigest: project.digest, egress: record.egress, ports: info(record).ports, services: trace.services
        )
        let runtime = runtime
        do {
            try await Blocking.run { () throws(NapboxError) in try runtime.saveRun(record, run) }
        } catch {
            print("环境 \(record.name) 写运行记录失败：\(error.message)")
        }
    }

    // MARK: - reset

    /// 把一个数据卷恢复成初始状态（空的）：停掉环境，旧卷移到 recycled 下保留 7 天，再像 up 一样起来
    /// （一次性服务重新跑，比如建库、建桶），返回和 up 一样的结果。用 up 时固定下来的定义。
    func reset(_ params: ResetParams) async throws(NapboxError) -> EnvironmentInfo {
        let record = try await record(for: params.target)
        if record.temporary != nil {
            throw NapboxError(.badRequest, "临时环境 \(record.name) 没有 reset：要空的数据就销毁了重新起（napbox down --temp \(record.temporary!)，再 napbox up --temp \(record.temporary!)）")
        }
        return try await serialized(record.name) { () throws(NapboxError) in
            try await self.resetVolume(record.name, params.volume)
        }
    }

    func resetVolume(_ name: String, _ volume: String) async throws(NapboxError) -> EnvironmentInfo {
        if shuttingDown { throw Self.exiting }
        guard let record = store.state.environment(name), let project = record.definition else {
            throw NapboxError(.environmentNotFound, "环境 \(name) 没有登记或没有定义")
        }
        guard project.volumes.contains(volume) else {
            let known = project.volumes.isEmpty ? "这个环境没有命名卷" : "有：\(project.volumes.joined(separator: "、"))"
            throw NapboxError(.volumeNotFound, "环境 \(name) 里没有数据卷 \(volume)，\(known)")
        }
        await stopRunning(name)
        let startedAt = Date()
        let cleared: EnvironmentRecord
        do {
            _ = try runtime.recycleVolume(record, volume: volume, reason: "napbox reset \(volume)")
            cleared = try store.update { (state: inout NapboxState) throws(NapboxError) -> EnvironmentRecord in
                guard let i = state.environments.firstIndex(where: { $0.name == name }) else {
                    throw NapboxError(.environmentNotFound, "环境 \(name) 没有登记")
                }
                state.environments[i].completedServices = []
                return state.environments[i]
            }
        } catch {
            await startFailed(record, project: project, purpose: .reset, startedAt: startedAt, error: error)
            throw error
        }
        try await launch(cleared, project: project, skipping: [], purpose: .reset)
        return info(store.state.environment(name)!)
    }
}
