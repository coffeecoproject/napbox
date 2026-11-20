// develop.watch：compose 里写了就生效。环境在跑时听宿主机的变化，攒一下按规则同步、重建、重启；
// 环境起好时先补上它没跑的这段时间的变化，所以休眠期间改的文件唤醒后也是新的。
import Foundation
import NapboxCore
import NapboxProtocol
import NapboxRuntime

/// 一个在跑的环境的监听。变化攒到安静下来才交出去（和 compose 一样 0.5 秒），一直有变化时最多攒 2 秒。
actor WatchSession {
    static let quietNanoseconds: UInt64 = 500_000_000
    static let longestNanoseconds: UInt64 = 2_000_000_000

    let environment: RunningEnvironment
    private let name: String
    private let matcher: WatchMatcher
    private let onBatch: @Sendable (Set<String>) -> Void
    private var stream: SourceEventStream?
    private var pending: Set<String> = []
    private var quiet: Task<Void, Never>?
    private var longest: Task<Void, Never>?
    private var stopped = false

    init(name: String, environment: RunningEnvironment, matcher: WatchMatcher, onBatch: @escaping @Sendable (Set<String>) -> Void) {
        self.name = name
        self.environment = environment
        self.matcher = matcher
        self.onBatch = onBatch
    }

    func start() throws(NapboxError) {
        let roots = matcher.eventRoots { SourceFileStat.of($0)?.isDirectory ?? false }
        stream = try SourceEventStream(
            directories: roots,
            onChange: { [weak self] paths in
                guard let self else { return }
                Task { await self.add(paths) }
            },
            onDropped: { [name] paths in
                print("环境 \(name)：系统说丢了一部分文件变化事件（\(paths.joined(separator: "、"))），develop.watch 可能少处理了这些目录下刚才的改动")
            }
        )
    }

    func stop() {
        stopped = true
        stream?.stop()
        stream = nil
        quiet?.cancel()
        longest?.cancel()
    }

    private func add(_ paths: [String]) {
        let wanted = paths.filter { matcher.watches($0) }
        guard !stopped, !wanted.isEmpty else { return }
        pending.formUnion(wanted)
        quiet?.cancel()
        quiet = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.quietNanoseconds)
            if !Task.isCancelled { await self?.flush() }
        }
        if longest == nil {
            longest = Task { [weak self] in
                try? await Task.sleep(nanoseconds: Self.longestNanoseconds)
                if !Task.isCancelled { await self?.flush() }
            }
        }
    }

    private func flush() {
        quiet?.cancel()
        longest?.cancel()
        quiet = nil
        longest = nil
        guard !stopped, !pending.isEmpty else { return }
        onBatch(pending)
        pending = []
    }
}

extension Daemon {
    /// 补同步、一批同步之后还要做的事。重建、重启排在同步后面，sync+exec 最后在届时的环境里跑（compose 的顺序）。
    struct WatchFollowUp: Sendable {
        var rebuild = false
        var restart = false
        var execs: [(service: String, command: [String])] = []

        var isEmpty: Bool { !rebuild && !restart && execs.isEmpty }

        mutating func add(_ plan: WatchPlan, service: String) {
            rebuild = rebuild || plan.rebuild
            restart = restart || plan.restart
            execs += plan.execs.map { (service, $0) }
        }
    }

    /// 服务都就绪后、环境登记成运行中之前调用：开始听变化，补上没跑的这段时间的变化。登记之后进来的连接直接转发，
    /// 所以先同步好再登记，它们不会连上还是旧文件的服务。同步失败不算起环境失败，原因放在 status 的 watchError。
    /// 返回同步之后还要做的事，登记之后交给 finishWatching。
    func startWatching(_ record: EnvironmentRecord, _ env: RunningEnvironment, project: ComposeProject) async -> WatchFollowUp {
        let name = record.name
        var followUp = WatchFollowUp()
        guard project.services.contains(where: { !$0.watch.isEmpty }) else {
            sessions[name]?.watchSyncError = nil
            sessions[name]?.watchBuildError = nil
            return followUp
        }
        // 构建上下文的忽略文件按 access 读（confine 的只读代码目录里的）。读不了当没有：只影响哪些变化不看
        let access = record.hostAccess
        let matcher = WatchMatcher(project: project, canonical: realDirectory) { path in
            try? access.readText(path, written: path, "develop.watch")
        }
        let session = WatchSession(name: name, environment: env, matcher: matcher) { [weak self] paths in
            Task { await self?.watchBatch(name, env, matcher, paths) }
        }
        do throws(NapboxError) {
            try await session.start()
        } catch {
            watchFailed(name, error.message)
            return followUp
        }
        watchSessions[name] = session

        var errors: [String] = []
        for service in matcher.services where await env.isServiceRunning(service) {
            do throws(NapboxError) {
                if let (plan, problems) = try await catchUp(record, env, matcher, service: service) {
                    followUp.add(plan, service: service)
                    errors += problems
                }
            } catch {
                errors.append(error.message)
            }
        }
        watchResult(name, errors)
        return followUp
    }

    /// 环境登记成运行中之后：补同步带出来的重建、重启、sync+exec
    func finishWatching(_ followUp: WatchFollowUp, _ name: String, _ env: RunningEnvironment) async {
        if followUp.rebuild || followUp.restart {
            // 服务已经按旧文件起来了，要重启才生效。现在在这个环境的队列里，重建、重启要排在后面
            Task { [self, followUp] in
                try? await serialized(name) { () throws(NapboxError) in
                    await self.finish(followUp, name, env)
                }
            }
        } else {
            await finish(followUp, name, env)
        }
    }

    func stopWatching(_ name: String) async {
        await watchSessions.removeValue(forKey: name)?.stop()
    }

    /// 比较这个服务记着的和现在的文件，把差的同步进去。返回这次的计划，第一次和没有变化时是 nil。
    /// 第一次没有记录：和 compose 一样，只有写了 initial_sync 的规则同步，只同步比镜像新的文件（旧的算镜像里已经有了），目录不单独同步。
    /// 失败了也记下现在的样子，不然之后的变化只记那几个文件，下次起环境其余的全算新增。
    private func catchUp(_ record: EnvironmentRecord, _ env: RunningEnvironment, _ matcher: WatchMatcher, service: String) async throws(NapboxError) -> (plan: WatchPlan, problems: [String])? {
        let url = try runtime.watchManifest(record, service: service)
        let current = await Blocking.run { matcher.scan(service: service) }
        guard let manifest = await Blocking.run({ Self.loadManifest(url) }) else {
            let imageCreated = await env.imageCreatedNanoseconds(service) ?? .min
            let newer = current.filter { !$0.value.isDirectory && $0.value.modifiedNanoseconds >= imageCreated }
            let plan = matcher.plan(service: service, paths: newer.keys.sorted(), onlyInitialSync: true)
            do throws(NapboxError) {
                _ = try await applySyncs(plan, service: service, env, current: current, previous: [:])
            } catch {
                try Self.saveManifest(current, url)
                throw error
            }
            try Self.saveManifest(current, url)
            return nil
        }
        var changed = current.filter { !$0.value.unchanged(from: manifest[$0.key]) }.keys.sorted()
        changed += manifest.keys.filter { current[$0] == nil }.sorted()
        guard !changed.isEmpty else { return nil }
        let plan = matcher.plan(service: service, paths: changed)
        var result = manifest
        let problems = try await applySyncs(plan, service: service, env, current: current, previous: manifest)
        for path in changed { result[path] = current[path] }
        try Self.saveManifest(result, url)
        return (plan, problems)
    }

    /// 监听报的一批变化
    func watchBatch(_ name: String, _ env: RunningEnvironment, _ matcher: WatchMatcher, _ paths: Set<String>) async {
        try? await serialized(name) { () throws(NapboxError) in
            await self.applyBatch(name, env, matcher, paths)
        }
    }

    private func applyBatch(_ name: String, _ env: RunningEnvironment, _ matcher: WatchMatcher, _ paths: Set<String>) async {
        guard running[name] === env, let record = store.state.environment(name) else { return }
        var followUp = WatchFollowUp()
        var errors: [String] = []
        for service in matcher.services where await env.isServiceRunning(service) {
            do throws(NapboxError) {
                let url = try runtime.watchManifest(record, service: service)
                // 要走目录、读写清单，可能很久，不占着 napboxd
                let (loaded, current, changed) = await Blocking.run {
                    let manifest = Self.loadManifest(url) ?? [:]
                    let (current, changed) = Self.changes(in: paths, matcher, service: service, manifest: manifest)
                    return (manifest, current, changed)
                }
                if changed.isEmpty { continue }
                let plan = matcher.plan(service: service, paths: changed)
                let problems = try await applySyncs(plan, service: service, env, current: current, previous: loaded)
                var manifest = loaded
                for path in changed { manifest[path] = current[path] }
                try Self.saveManifest(manifest, url)
                followUp.add(plan, service: service)
                errors += problems
            } catch {
                errors.append(error.message)
            }
        }
        watchResult(name, errors)
        await finish(followUp, name, env)
    }

    /// 这批路径里真的变了的。目录展开成它和下面的文件，FSEvents 对搬进来、换掉的目录只报目录本身；没了的路径，下面记着的也算没了。
    /// 目录自己可能不归规则管（只写了 include），下面的文件归，所以不先按目录判断。
    private nonisolated static func changes(in paths: Set<String>, _ matcher: WatchMatcher, service: String,
                                            manifest: [String: SourceFileStat]) -> (current: [String: SourceFileStat], changed: [String]) {
        var current: [String: SourceFileStat] = [:]
        var changed = Set<String>()
        for path in paths {
            let below = manifest.keys.filter { $0.hasPrefix(path + "/") }
            guard let stat = SourceFileStat.of(path) else {
                // 路径本身也要删：可能是目录，只删记着的文件会留下空目录
                if matcher.concerns(path, service: service) { changed.insert(path) }
                changed.formUnion(below)
                continue
            }
            if stat.isSpecial { continue }
            if stat.isDirectory {
                let files = matcher.files(under: path, service: service)
                current.merge(files) { _, new in new }
                changed.formUnion(files.filter { !$0.value.unchanged(from: manifest[$0.key]) }.keys)
                changed.formUnion(below.filter { files[$0] == nil })
            } else if matcher.concerns(path, service: service) {
                current[path] = stat
                if !stat.unchanged(from: manifest[path]) { changed.insert(path) }
            }
        }
        return (current, changed.sorted())
    }

    /// 没了的删掉，其余的写进容器（顺序和 compose 一样）。写失败抛错，调用方不记进 manifest，下次起环境再试。
    /// 删不掉（比如目录不属于容器的用户）和 compose 一样不挡着别的文件，也不重试，返回说明放进 watchError。
    private func applySyncs(_ plan: WatchPlan, service: String, _ env: RunningEnvironment,
                            current: [String: SourceFileStat], previous: [String: SourceFileStat]) async throws(NapboxError) -> [String] {
        var removals: [String] = []
        var files: [SyncedFile] = []
        for sync in plan.syncs {
            guard let stat = current[sync.hostPath] else {
                // 上层目录换成了文件：删那个上层时连同下面的一起没了，这里 rm 反而会因为“不是目录”报错
                if !Self.nearestAncestorIsNotDirectory(sync.hostPath) { removals.append(sync.containerPath) }
                continue
            }
            // 类型变了（文件和目录互换）：tar 不会把目录换成文件，也不能在文件上建目录，先删
            if let old = previous[sync.hostPath], old.isDirectory != stat.isDirectory {
                removals.append(sync.containerPath)
            }
            files.append(SyncedFile(hostPath: sync.hostPath, containerPath: sync.containerPath, stat: stat))
        }
        var problems: [String] = []
        if !removals.isEmpty {
            do throws(NapboxError) {
                try await env.runInService(service, ["rm", "-rf", "--"] + removals)
            } catch {
                problems.append(error.message)
            }
        }
        if !files.isEmpty {
            try await env.syncFiles(service, files)
        }
        return problems
    }

    /// 这个路径已经不在了：往上最近的还在的那一层是不是目录
    private nonisolated static func nearestAncestorIsNotDirectory(_ path: String) -> Bool {
        var parent = (path as NSString).deletingLastPathComponent
        while parent != "/", !parent.isEmpty {
            if let stat = SourceFileStat.of(parent) { return !stat.isDirectory }
            parent = (parent as NSString).deletingLastPathComponent
        }
        return false
    }

    /// 同步之后的重建、重启、sync+exec。重建或重启后环境换了新的，exec 在新的里跑
    private func finish(_ followUp: WatchFollowUp, _ name: String, _ env: RunningEnvironment) async {
        guard !followUp.isEmpty else { return }
        if followUp.rebuild {
            await rebuildNow(name, ifStill: env)
        }
        if followUp.restart, running[name] === env {
            await restartNow(name, env)
        }
        guard let current = running[name] else { return }
        for (service, command) in followUp.execs where await current.isServiceRunning(service) {
            do throws(NapboxError) {
                try await current.runInService(service, command)
            } catch {
                watchFailed(name, error.message)
            }
        }
    }

    /// 重新构建，镜像变了整个环境重启。失败时旧环境接着跑，原因放在 status 的 watchError，成功构建后才清（bringUp 里）。
    /// compose 在上次 up 之后改过时不做：重建会重跑一次性服务，等于一次 up，按存下的旧定义跑是拿新代码配旧配置。
    /// 记进登记（rebuildDeferred），status 的 watchError 里说明，下次 up 时补上
    private func rebuildNow(_ name: String, ifStill env: RunningEnvironment) async {
        guard running[name] === env, let record = store.state.environment(name), let project = record.definition else { return }
        if let stale = staleCompose(record) {
            print("环境 \(name)：依赖的文件变了，但 compose 在\(stale.last) 之后改过（\(stale.changed)），不自动重建，等\(stale.again)")
            deferRebuild(name)
            return
        }
        print("环境 \(name)：依赖的文件变了，重新构建")
        do throws(NapboxError) {
            _ = try await bringUp(name, project: project, source: nil, access: record.hostAccess, egress: nil, rebuild: true) { _ in record }
        } catch {
            print("环境 \(name) 的 develop.watch 重建失败：\(error.message)")
            sessions[name, default: EnvSession()].watchBuildError = error.message
        }
    }

    private func deferRebuild(_ name: String) {
        guard store.state.environment(name)?.rebuildDeferred != true else { return }
        do {
            try store.update { (state: inout NapboxState) throws(NapboxError) in
                if let i = state.environments.firstIndex(where: { $0.name == name }) { state.environments[i].rebuildDeferred = true }
            }
        } catch {
            print("环境 \(name) 记录没做的重建失败：\(error.message)")
        }
    }

    /// 一批同步的结果：有错放进 status 的 watchError，也记日志；都成功就清掉之前的同步错误。重建的错误不算在内
    private func watchResult(_ name: String, _ errors: [String]) {
        if errors.isEmpty {
            sessions[name]?.watchSyncError = nil
        } else {
            watchFailed(name, errors.joined(separator: "\n"))
        }
    }

    private func watchFailed(_ name: String, _ message: String) {
        print("环境 \(name) 的 develop.watch 出错：\(message)")
        sessions[name, default: EnvSession()].watchSyncError = message
    }

    private nonisolated static func loadManifest(_ url: URL) -> [String: SourceFileStat]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode([String: SourceFileStat].self, from: data)
    }

    private nonisolated static func saveManifest(_ manifest: [String: SourceFileStat], _ url: URL) throws(NapboxError) {
        do {
            try JSONEncoder().encode(manifest).write(to: url, options: .atomic)
        } catch {
            throw NapboxError(.internalError, "写不了 \(url.path)：\(error)")
        }
    }
}
