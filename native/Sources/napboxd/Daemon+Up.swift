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
    /// - access：create 带 confine 时是限定在代码目录里的
    func loadCompose(_ files: [URL], environment: [String: String], profiles: [String],
                     run: ComposeRun? = nil, access: HostAccess = .open) throws(NapboxError) -> ComposeProject {
        do {
            return try ComposeLoader.load(ComposeInput(files: files, callerEnvironment: environment, profiles: profiles, run: run,
                                                       access: access))
        } catch {
            throw error.napboxError
        }
    }

    /// 名字已经被别的环境占了时返回 nil
    func start(name: String, location: WorktreeLocation, temporary: String?, project: ComposeProject, egress: EgressMode?,
               rebuild: Bool, foreground: ForegroundService?) async throws(NapboxError) -> EnvironmentInfo? {
        if let existing = store.state.environment(name),
           existing.owner != .worktree || existing.worktree != location.worktree.path || existing.temporary != temporary { return nil }
        let seed = try stageFirstSeed(name, location: location, temporary: temporary, project: project)
        let registered: EnvironmentRecord
        do {
            registered = try await bringUp(name, project: project, access: .open, egress: egress, rebuild: rebuild, foreground: foreground,
                                           seed: seed) { state in
                EnvironmentRecord(
                    name: name, project: state.projectName(for: location.mainRepository), mainRepository: location.mainRepository.path,
                    worktree: location.worktree.path, owner: .worktree, temporary: temporary
                )
            }
        } catch {
            // 临时环境还没登记就失败了（构建到一半、镜像拉不下来）：已经构建出来的镜像没有环境可跟着销毁，这里删。
            // 登记以后才失败的，launch 已经把它整个销毁、镜像也删了；那时登记同样不在，这里再删一遍是空的
            if temporary != nil, store.state.environment(name) == nil { await removeBuiltImages(name) }
            // 还没登记就失败了时，复制到 incoming/ 的留着：下次 up 复制前先清空它，napboxd 启动时也清掉没有换卷记号的
            throw error
        }
        // ports.json 只写开发环境的：临时环境的端口在返回值里，也可以 napbox env --temp 再取
        if temporary == nil {
            try await Blocking.run { () throws(NapboxError) in
                try PortsFile.write(environment: name, ports: registered.activePorts, hostPorts: registered.hostPorts ?? [], worktree: location.worktree)
            }
        }
        var result = info(registered)
        result.seededFrom = seed
        return result
    }

    /// x-napbox.seed：worktree 的开发环境第一次创建时（还没登记），先把主目录环境最新快照里声明的卷复制到它的 incoming/。
    /// 登记时一起记上换卷的记号（bringUp），起环境之前（launch）换进去。主目录自己、临时环境不复制。
    /// 主目录没有环境或没有快照时报错，不退回成空卷
    private func stageFirstSeed(_ name: String, location: WorktreeLocation, temporary: String?,
                                project: ComposeProject) throws(NapboxError) -> SeedSource? {
        guard temporary == nil, !location.isMain, let volumes = project.seed, store.state.environment(name) == nil else { return nil }
        guard let source = store.state.environment(worktree: location.mainRepository.path, temporary: nil) else {
            throw NapboxError(.snapshotNotFound, "compose 声明了 x-napbox.seed（\(volumes.joined(separator: "、"))），要从主目录 \(location.mainRepository.path) 的环境复制数据，"
                + "但主目录还没有开发环境，也就没有快照：先在主目录 napbox up，等它正常停下一次（闲置休眠或 napbox sleep）；不要数据就把卷从 x-napbox.seed 去掉")
        }
        return try runtime.stageSeed(from: source, to: EnvironmentRecord.id(of: name), volumes: volumes)
    }

    // MARK: - create（调用方持有的环境）

    /// 调用方创建环境。名字由调用方给；同名、同持有方、同目录再调用时定义没变就保证它在运行（在运行的直接返回，
    /// 休眠的唤醒），定义变了整个环境重启；持有方或目录不同时报 name_taken。
    /// 代码副本里不写 .napbox/ports.json：端口和变量都在返回值里。
    /// confine 时 compose 里用到的宿主机路径都要在代码副本以内（Confinement）。代码副本的真实路径第一次带 confine 时定下、
    /// 记进登记（confinedRoot），之后每次读 compose、起环境都按它查，不再按目录重新解析
    func create(_ params: CreateParams) async throws(NapboxError) -> EnvironmentInfo {
        try CallerEnvironment.validate(name: params.name, owner: params.owner)
        let directory = try CallerEnvironment.directory(params.directory)
        let access: HostAccess = params.confine == true
            ? .confined(store.state.environment(params.name)?.confinedRoot.map(Confinement.init(root:)) ?? Confinement(directory: directory.path))
            : .open
        let files = try ComposeFiles.resolve(explicit: params.files, environment: params.environment, cwd: directory, worktree: directory,
                                             access: access)
        let project = try loadCompose(files, environment: params.environment, profiles: params.profiles, access: access)
        let name = params.name, owner = EnvironmentRecord.Owner.caller(id: params.owner), egress = params.egress
        return try await serialized(name) { () throws(NapboxError) in
            try await self.startCaller(name, owner: owner, directory: directory, project: project, egress: egress, access: access)
        }
    }

    func startCaller(_ name: String, owner: EnvironmentRecord.Owner, directory: URL, project: ComposeProject,
                     egress: EgressMode?, access: HostAccess) async throws(NapboxError) -> EnvironmentInfo {
        let root = access.confinement?.root
        // 只起了临时环境的 worktree 也占着它开发环境的名字（NapboxState.holder）
        if let existing = store.state.holder(of: name) {
            guard existing.name == name, existing.owner == owner, existing.worktree == directory.path else {
                let holder = existing.owner.callerID.map { "\($0) 持有" } ?? "worktree 持有"
                throw NapboxError(.nameTaken, "环境名 \(name) 已经被占了：\(holder)，代码目录 \(existing.worktree)")
            }
            if existing.confinedRoot != nil, root == nil {
                throw NapboxError(.badRequest, "环境 \(name) 是带 confine 建的，再 create 也要带 confine: true；要不受限的环境先 down 再建")
            }
            // 不受限的改成受限：先记上，这次起环境（和之后每次）就按受限的查和挂。起不来也不退回去。
            // 在跑的先停下：它的挂载是按不受限的方式建的，定义没变时 bringUp 会直接沿用它
            if let root, existing.confinedRoot == nil {
                try setConfinedRoot(name, root)
                await stopRunning(name, keepCompleted: false)
            }
            // 调用方重启后再 create 碰到的都是休眠的环境：定义没变就只是唤醒，建库、导入数据这些一次性服务不重跑
            if running[name] == nil, existing.definition == project, existing.confinedRoot == root {
                if shuttingDown { throw Self.exiting }
                if let egress, egress != existing.egress { _ = try await setEgress(name, egress) }
                try await wakeNow(name, cooldown: false)
                return info(store.state.environment(name)!)
            }
        }
        return info(try await bringUp(name, project: project, access: access, egress: egress, rebuild: false) { _ in
            EnvironmentRecord(name: name, project: nil, mainRepository: nil, worktree: directory.path, owner: owner, confinedRoot: root)
        })
    }

    private func setConfinedRoot(_ name: String, _ root: String) throws(NapboxError) {
        try store.update { (state: inout NapboxState) throws(NapboxError) in
            guard let i = state.environments.firstIndex(where: { $0.name == name }) else {
                throw NapboxError(.environmentNotFound, "环境 \(name) 没有登记")
            }
            state.environments[i].confinedRoot = root
        }
    }

    // MARK: - 起环境

    /// up 和 create 共用：已经在运行、定义和镜像都没变、服务都在就不重启（只按要求换出网模式）；否则整个环境重新起
    /// （单个服务不能单独重启），一次性服务重跑。准备好了才停旧环境：
    /// secrets 的文件不在、构建失败、镜像名写错、端口被占这类失败不影响在跑的环境，登记和定义也不变。
    /// - egress：要切到的出网模式，nil 是不变（新环境 open）
    /// - rebuild：up --build，写了 build 的服务都重新构建
    /// - foreground：napbox run 在前台跑的那个服务
    /// - seed：第一次创建、已经复制到 incoming/ 的数据（x-napbox.seed）。新登记里同时记上换卷的记号，和登记是同一次写入：
    ///   之后哪一步停下（失败、napboxd 被杀），记号都在，launch 或 napboxd 启动时接着换进去，不会变成登记了却一直是空卷
    /// - access：怎么碰宿主机上的文件，和登记（或要登记的）一致：worktree 的是 .open，调用方持有的按 confinedRoot
    /// - newRecord：还没登记时的新登记
    func bringUp(_ name: String, project: ComposeProject, access: HostAccess, egress: EgressMode?, rebuild: Bool,
                 foreground: ForegroundService? = nil, seed: SeedSource? = nil,
                 newRecord: (NapboxState) -> EnvironmentRecord) async throws(NapboxError) -> EnvironmentRecord {
        if shuttingDown { throw Self.exiting }
        let startedAt = Date()
        let rebuilt: Bool
        do {
            // 不用等的先查：挂载的来源不成立时不必先花时间构建
            try runtime.checkHostMounts(project, access: access)
            rebuilt = try await buildImages(name, project: project, force: rebuild, access: access)
            if rebuild { sessions[name]?.watchBuildError = nil }
            try Self.checkCaller(foreground)
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
            record = try await prepare(name, project: project, egress: egress, foreground: foreground) { state in
                var r = newRecord(state)
                if let seed { r.pending = .replaceVolumes(volumes: seed.volumes, seed: seed) }
                return r
            }
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

    /// napbox run 的命令行已经断开（或超时）：环境还没登记、没起虚拟机，不再往下起
    private static func checkCaller(_ foreground: ForegroundService?) throws(NapboxError) {
        if foreground?.callerGone.isGone == true {
            throw NapboxError(.serviceFailed, "命令行已经断开（或超时），不再起这个临时环境")
        }
    }

    /// 全新的环境还没登记，没有地方放运行记录，也还没有人订阅它的状态：只靠这次调用返回的错误
    private func preparationFailed(_ name: String, project: ComposeProject, startedAt: Date, error: NapboxError) async {
        guard let registered = store.state.environment(name) else { return }
        await startFailed(registered, project: project, purpose: .up, startedAt: startedAt, error: error)
    }

    /// 写了 build 的服务要构建的先构建（可能很久，也不碰在跑的环境）。返回有没有镜像变了。
    private func buildImages(_ name: String, project: ComposeProject, force: Bool,
                             access: HostAccess) async throws(NapboxError) -> Bool {
        preparing.insert(name)
        defer { preparing.remove(name) }
        return try await runtime.buildImages(project, environment: name, force: force, access: access)
    }

    /// 起环境之前的准备：拉镜像并查镜像和 compose 合起来成不成立、分配地址和端口，把新定义写进登记。全程不碰在跑的环境。
    /// 从分配地址到写登记之间不能有等待：别的名字的环境不在同一个队列里，它们看不到还没登记的地址和端口，
    /// 会分到同一个。
    private func prepare(_ name: String, project: ComposeProject, egress: EgressMode?, foreground: ForegroundService?,
                         newRecord: (NapboxState) -> EnvironmentRecord) async throws(NapboxError) -> EnvironmentRecord {
        // 这段可能很久，也取消不了，napboxd 退出时不等它（shutdown）；等完了再看要不要继续
        preparing.insert(name)
        defer { preparing.remove(name) }
        try await runtime.prepareImages(project, environment: name)
        let requests = project.portRequests
        let neighbors = await Blocking.run { NetworkNeighbors.addresses() }
        if shuttingDown { throw Self.exiting }
        try Self.checkCaller(foreground)
        let ip = try AddressAllocator.allocate(environment: name, state: store.state, inUseOnNetwork: neighbors)
        let ports = try PortAllocator.assign(requests, hostPorts: project.hostPorts ?? [], environment: name, state: store.state, locks: locks)
        return try store.update { (state: inout NapboxState) throws(NapboxError) -> EnvironmentRecord in
            var r = state.environment(name) ?? newRecord(state)
            r.ports = ports.ports
            r.hostPorts = ports.hostPorts.isEmpty ? nil : ports.hostPorts
            state.recordAllocation(ports)
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
    /// 登记里有没换完的数据卷（reset、x-napbox.seed 记上的，或者上次换到一半失败了）时先换完再起：
    /// 一次性服务跟着重跑，从快照复制的记进运行记录（seededFrom）
    func launch(_ record: EnvironmentRecord, project: ComposeProject, skipping: Set<String>,
                purpose: RunRecord.Purpose, foreground: ForegroundService? = nil,
                progress: StartProgress = StartProgress()) async throws(NapboxError) {
        if shuttingDown { throw Self.exiting }
        let name = record.name
        let trace = RunTrace()
        let startedAt = Date()
        let runId = Self.newRunId()
        var record = record, skipping = skipping
        var seededFrom: SeedSource?
        let env: RunningEnvironment
        do {
            if case .replaceVolumes(let volumes, let seed) = store.state.environment(name)?.pending {
                record = try finishReplace(record, volumes: volumes, seed: seed)
                skipping = []
                seededFrom = seed
            }
            try lockPorts(record)
            // 先开始监听：起环境期间进来的连接排队等着，唤醒时等它连的服务就绪就转发（route）
            await syncListeners(name)
            env = try await runtime.start(record, project: project, skipping: skipping, foreground: foreground, trace: trace,
                                          progress: progress)
        } catch {
            await startFailed(record, project: project, id: runId, purpose: purpose, startedAt: startedAt, error: error, trace: trace,
                              seededFrom: seededFrom)
            if record.temporary != nil { await destroyTemporary(name, reason: "\(Self.description(purpose))失败") }
            throw error
        }
        await saveRun(record, project: project, id: runId, purpose: purpose, startedAt: startedAt, error: nil, trace: trace,
                      seededFrom: seededFrom)
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
                             purpose: RunRecord.Purpose, startedAt: Date, error: NapboxError, trace: RunTrace = RunTrace(),
                             seededFrom: SeedSource? = nil) async {
        await saveRun(record, project: project, id: id, purpose: purpose, startedAt: startedAt, error: error, trace: trace, seededFrom: seededFrom)
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
                         startedAt: Date, error: NapboxError?, trace: RunTrace, seededFrom: SeedSource? = nil) async {
        let run = RunRecord(
            id: id, environment: record.name, purpose: purpose, startedAt: startedAt, finishedAt: Date(), error: error,
            definitionDigest: project.digest, egress: record.egress, ports: info(record).ports, services: trace.services,
            seededFrom: seededFrom
        )
        let runtime = runtime
        do {
            try await Blocking.run { () throws(NapboxError) in try runtime.saveRun(record, run) }
        } catch {
            print("环境 \(record.name) 写运行记录失败：\(error.message)")
        }
    }

    // MARK: - reset

    /// 换掉数据卷，再像 up 一样起来（一次性服务重新跑，比如建库、迁移），返回和 up 一样的结果。用 up 时固定下来的定义。
    /// 旧卷移到 recycled 下保留 7 天。不带 from 换成空的；带 from 换成那个 worktree 的开发环境最新快照里的那份
    /// （x-napbox.seed，同一个项目），源环境不用停、不受影响。
    func reset(_ params: ResetParams) async throws(NapboxError) -> EnvironmentInfo {
        let record = try await record(for: params.target)
        if record.temporary != nil {
            throw NapboxError(.badRequest, "临时环境 \(record.name) 没有 reset：要空的数据就销毁了重新起（napbox down --temp \(record.temporary!)，再 napbox up --temp \(record.temporary!)）")
        }
        guard !params.volumes.isEmpty else { throw NapboxError(.badRequest, "reset 至少要给一个数据卷") }
        var sourceWorktree: String?
        if let from = params.from { sourceWorktree = try await seedSourceWorktree(from, for: record) }
        let volumes = Array(Set(params.volumes)).sorted()
        return try await serialized(record.name) { [sourceWorktree] () throws(NapboxError) in
            try await self.resetVolumes(record.name, volumes, sourceWorktree: sourceWorktree)
        }
    }

    /// reset --from 的源：那个目录所在 worktree，要和目标是同一个项目、不是它自己。目标要是 worktree 的开发环境
    private func seedSourceWorktree(_ from: String, for record: EnvironmentRecord) async throws(NapboxError) -> String {
        guard record.owner == .worktree, let main = record.mainRepository else {
            throw NapboxError(.badRequest, "环境 \(record.name) 是调用方持有的，reset 不支持 from：只有 worktree 的开发环境能从别的 worktree 复制数据")
        }
        let location = try await Blocking.run { () throws(NapboxError) in try WorktreeLocation.locate(from: URL(fileURLWithPath: from)) }
        guard location.mainRepository.path == main else {
            throw NapboxError(.badRequest, "\(from) 不在环境 \(record.name) 的项目里（主仓库 \(main)），只能从同一个项目的 worktree 复制数据")
        }
        guard location.worktree.path != record.worktree else {
            throw NapboxError(.badRequest, "\(from) 就是环境 \(record.name) 自己的 worktree，不能从自己复制")
        }
        return location.worktree.path
    }

    func resetVolumes(_ name: String, _ volumes: [String], sourceWorktree: String?) async throws(NapboxError) -> EnvironmentInfo {
        if shuttingDown { throw Self.exiting }
        guard let record = store.state.environment(name), let project = record.definition else {
            throw NapboxError(.environmentNotFound, "环境 \(name) 没有登记或没有定义")
        }
        let unknown = volumes.filter { !project.volumes.contains($0) }
        guard unknown.isEmpty else {
            let known = project.volumes.isEmpty ? "这个环境没有命名卷" : "有：\(project.volumes.joined(separator: "、"))"
            throw NapboxError(.volumeNotFound, "环境 \(name) 里没有数据卷 \(unknown.joined(separator: "、"))，\(known)")
        }
        // 挂载的来源先查（secrets 的文件、confine 的路径）：起容器时才发现不成立的话，卷已经换了、环境停着起不来。
        // 和 up 一样准备好了才停旧环境，不成立时卷不换、环境原样不动
        try runtime.checkHostMounts(project, access: record.hostAccess)
        // 上次换卷换到一半失败了：先换完，免得这次的记号盖掉它（这时环境没在运行：launch 起来之前会先换完）
        if case .replaceVolumes(let pendingVolumes, let pendingSeed) = record.pending {
            _ = try finishReplace(record, volumes: pendingVolumes, seed: pendingSeed)
        }
        // 先从源的快照复制好再停目标：源没有快照、快照里缺卷时目标原样不动
        var seed: SeedSource?
        if let sourceWorktree {
            guard let source = store.state.environment(worktree: sourceWorktree, temporary: nil) else {
                throw NapboxError(.environmentNotFound, "\(sourceWorktree) 还没有开发环境，也就没有快照：先在那边 napbox up，等它正常停下一次（闲置休眠或 napbox sleep）")
            }
            seed = try runtime.stageSeed(from: source, to: record.id, volumes: volumes)
        }
        await stopRunning(name)
        do throws(NapboxError) {
            // 只记上，换卷由 launch 起环境之前做：卷换了、一次性服务的记录还没清时 napboxd 被杀，下次启动接着做完
            // （finishPendingOperations），不会带着“已经初始化过”的记录在新卷上起来
            try setPending(name, .replaceVolumes(volumes: volumes, seed: seed))
        } catch {
            await startFailed(record, project: project, purpose: .reset, startedAt: Date(), error: error)
            throw error
        }
        try await launch(store.state.environment(name)!, project: project, skipping: [], purpose: .reset)
        var result = info(store.state.environment(name)!)
        result.seededFrom = seed
        return result
    }

    /// 换卷（reset、x-napbox.seed）：环境已经停了、登记里已经记上“换数据卷”。换卷，再一次写进状态文件：
    /// 清掉已跑完的一次性服务（下次起来重新初始化）、去掉记号。上次做到一半的，已经换好的卷跳过。
    /// 换卷或写状态文件失败时记号留着（复制来的也留在 incoming/）：环境起来之前（launch）、napboxd 下次启动时接着做完，
    /// 在那之前环境起不来，不会在换了一半的卷上运行。
    func finishReplace(_ record: EnvironmentRecord, volumes: [String], seed: SeedSource?) throws(NapboxError) -> EnvironmentRecord {
        let reason = "napbox reset " + volumes.joined(separator: " ") + (seed.map { "（从 \($0.environment) 的快照复制）" } ?? "")
        try runtime.replaceVolumes(record, volumes: volumes, seed: seed != nil, reason: reason)
        return try store.update { (state: inout NapboxState) throws(NapboxError) -> EnvironmentRecord in
            guard let i = state.environments.firstIndex(where: { $0.name == record.name }) else {
                throw NapboxError(.environmentNotFound, "环境 \(record.name) 没有登记")
            }
            state.environments[i].completedServices = []
            state.environments[i].pending = nil
            return state.environments[i]
        }
    }
}
