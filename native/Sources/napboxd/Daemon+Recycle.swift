// 回收：napbox down、worktree 删掉后自动回收、清理保留期满的数据。
import Foundation
import NIOCore
import NapboxCore
import NapboxProtocol
import NapboxRuntime

extension Daemon {
    // MARK: - down

    /// 回收环境：停掉服务、不再监听、释放端口、删掉登记；数据卷移到 recycled 目录保留 7 天。
    /// 临时环境的数据直接删掉。调用方按名字销毁时也走这里，带 discardData 时数据也直接删掉。
    func down(_ params: DownParams) async throws(NapboxError) -> DownResult {
        let discardData = params.discardData == true
        if discardData, case .directory = params.target {
            throw NapboxError(.usageError, "discardData 只能用在调用方持有的环境（按 name、owner 指定）；worktree 的开发环境回收后数据保留 7 天，临时环境本来就直接删")
        }
        let queued = try await record(for: params.target)
        let reason = queued.owner.callerID.map { "\($0) 销毁" } ?? "napbox down"
        return try await serialized(queued.name) { () throws(NapboxError) in
            // 按排到时的登记回收：排在前面的 up 可能改了端口
            guard let record = await self.environmentRecord(queued.name) else {
                throw NapboxError(.environmentNotFound, "环境 \(queued.name) 没有了（排队期间已经回收）")
            }
            return try await self.recycle(record, reason: reason, discardData: discardData)
        }
    }

    /// 先停，在登记里记上“回收中”，再移走数据（临时环境是删掉），都成功了才关监听、放端口、删登记。
    /// 移数据失败时去掉记号，环境还是完整登记着的休眠状态，有连接进来照样唤醒，下次再回收。
    /// napboxd 在中间被杀时，下次启动由 finishPendingOperations 接着做完。
    /// discardData：调用方要求不保留数据，移走后马上删；删失败时结果里的 keptDataAt 写明数据还在哪（7 天后删）。
    /// 数据马上就删的（临时环境、discardData）直接关虚拟机，不等服务收尾：数据保留 7 天的才要正常停下、存好盘。
    func recycle(_ record: EnvironmentRecord, reason: String, discardData: Bool = false) async throws(NapboxError) -> DownResult {
        if shuttingDown { throw Self.exiting }
        await stopRunning(record.name, snapshot: false, discarding: record.temporary != nil || discardData)
        try setPending(record.name, .recycle(reason: reason, discardData: discardData))
        return try await finishRecycle(record, reason: reason, discardData: discardData)
    }

    /// 回收的后半段：环境已经停了、登记里已经记上“回收中”
    private func finishRecycle(_ record: EnvironmentRecord, reason: String, discardData: Bool) async throws(NapboxError) -> DownResult {
        let runtime = runtime
        var kept: URL?
        do {
            // 删大文件要一会儿，不占着 actor
            if record.temporary != nil {
                try await Blocking.run { () throws(NapboxError) in try runtime.delete(record) }
            } else if discardData {
                kept = try await Blocking.run { () throws(NapboxError) in try runtime.discard(record, reason: reason) }
            } else {
                kept = try runtime.recycle(record, reason: reason)
            }
        } catch {
            try? setPending(record.name, nil)
            throw error
        }
        await removeBuiltImages(record.name)
        await closeListeners(record.name)
        for a in record.ports { locks.release(a.hostPort) }
        try store.update { (state: inout NapboxState) throws(NapboxError) in state.environments.removeAll { $0.name == record.name } }
        activity.forget(record.name)
        sessions[record.name] = nil
        // ports.json 是开发环境的，临时环境不写也不删
        if record.owner == .worktree, record.temporary == nil { removePortsFile(worktree: URL(fileURLWithPath: record.worktree)) }
        events.emit(EnvironmentEvent(at: Date(), environment: record.name, owner: record.owner.callerID, type: .destroyed, reason: reason))
        return DownResult(name: record.name, releasedPorts: record.allHostPorts.sorted(), keptDataAt: kept?.path)
    }

    /// 在登记里记上（nil 是去掉）开始了还没做完的操作
    func setPending(_ name: String, _ pending: EnvironmentRecord.PendingOperation?) throws(NapboxError) {
        try store.update { (state: inout NapboxState) throws(NapboxError) in
            guard let i = state.environments.firstIndex(where: { $0.name == name }) else {
                throw NapboxError(.environmentNotFound, "环境 \(name) 没有登记")
            }
            state.environments[i].pending = pending
        }
    }

    /// napboxd 启动时、开始监听端口之前：上次没做完的回收和换数据卷（reset、x-napbox.seed）接着做完（这时环境都没在运行）；
    /// 再删掉登记里没有的环境留下的构建结果、没在换卷的环境留下的复制数据和没拍完的快照。做不完的记进日志：
    /// 回收移不走数据时去掉记号，环境照常登记、休眠；换卷失败时记号留着，环境起来之前（launch）再做；
    /// 回收移走了、写状态文件失败的，记号留着下次再做。
    func finishPendingOperations() async {
        for record in store.state.environments {
            switch record.pending {
            case nil:
                continue
            case .recycle(let reason, let discardData):
                print("环境 \(record.name) 上次回收没做完（\(reason)），接着做")
                do {
                    let result = try await finishRecycle(record, reason: reason, discardData: discardData)
                    if let kept = result.keptDataAt { print("环境 \(record.name) 的数据没删掉，留在 \(kept)，7 天后删") }
                } catch {
                    print("环境 \(record.name) 回收失败，照常登记、下次再回收：\(error.message)")
                }
            case .replaceVolumes(let volumes, let seed):
                let what = volumes.joined(separator: "、") + (seed.map { "（从 \($0.environment) 的快照复制）" } ?? "")
                print("环境 \(record.name) 上次换数据卷 \(what) 没做完，接着做")
                do {
                    _ = try finishReplace(record, volumes: volumes, seed: seed)
                } catch {
                    print("环境 \(record.name) 换数据卷 \(what) 没做完：\(error.message)")
                }
            }
        }
        let ids = Set(store.state.environments.map(\.id))
        for message in await runtime.removeLeftoverBuilds(keeping: ids) { print(message) }
        let seeding = Set(store.state.environments.filter {
            if case .replaceVolumes(_, .some) = $0.pending { true } else { false }
        }.map(\.id))
        for message in runtime.removeLeftoverSeeds(keepingIncoming: seeding) { print(message) }
    }

    /// 只是多占点硬盘，不算回收失败
    func removeBuiltImages(_ name: String) async {
        do {
            try await runtime.removeBuiltImages(environment: name)
        } catch {
            print("环境 \(name) 构建出来的镜像删除失败：\(error.message)")
        }
    }

    // MARK: - 临时环境停下来就销毁

    /// 临时环境不该再留着了（闲置、起不来、虚拟机没了）：销毁。调用时已经排在这个环境的队列里。
    /// 销毁不了（napboxd 正在退出、数据删不掉）时登记还在，napboxd 下次启动时再销毁（destroyLeftoverTemporaries）。
    func destroyTemporary(_ name: String, reason: String) async {
        guard let record = store.state.environment(name), record.temporary != nil else { return }
        do {
            _ = try await recycle(record, reason: reason)
        } catch {
            print("临时环境 \(name) 销毁失败（\(reason)）：\(error.message)")
        }
    }

    /// napboxd 启动时：上次留下的临时环境都销毁。napboxd 退出时它们只是停了（来不及删数据），崩溃时也会留下登记。
    func destroyLeftoverTemporaries() async {
        for name in store.state.environments.filter({ $0.temporary != nil }).map(\.name) {
            try? await serialized(name) { () throws(NapboxError) in
                print("临时环境 \(name) 是 napboxd 上次运行时留下的，销毁")
                await self.destroyTemporary(name, reason: "napboxd 重启，临时环境不保留")
            }
        }
    }

    /// ports.json 是 napbox 自己写的，端口已经释放，留着会误导；.napbox 目录空了也一起去掉
    private func removePortsFile(worktree: URL) {
        let dir = worktree.appending(path: ".napbox")
        try? FileManager.default.removeItem(at: dir.appending(path: "ports.json"))
        if (try? FileManager.default.contentsOfDirectory(atPath: dir.path))?.isEmpty == true {
            try? FileManager.default.removeItem(at: dir)
        }
    }

    // MARK: - worktree 删除后自动回收

    /// worktree 持有的环境，worktree 删掉了就回收（和 down 一样，数据保留 7 天）。调用方持有的环境不管。
    /// git 查不了的这次跳过，下次再查。
    func reclaimDeletedWorktrees() async {
        let candidates = store.state.environments.compactMap { r -> (String, String, String)? in
            guard r.owner == .worktree, let main = r.mainRepository else { return nil }
            return (r.name, r.worktree, main)
        }
        guard !candidates.isEmpty else { return }
        // 要跑 git，不占着 actor
        let results = await Blocking.run {
            candidates.map { ($0.0, WorktreePresence.check(worktree: $0.1, mainRepository: $0.2)) }
        }
        for (name, presence) in results {
            switch presence {
            case .present:
                continue
            case .unknown(let why):
                print("环境 \(name) 的 worktree 查不了，这次不回收：\(why)")
            case .gone(let why):
                do {
                    try await serialized(name) { () throws(NapboxError) in
                        // 排队期间可能已经 down 了，或者在原来的路径上重建了 worktree：按现在的登记再查一次
                        guard let record = await self.environmentRecord(name), let main = record.mainRepository else { return }
                        guard case .gone = await Blocking.run({ WorktreePresence.check(worktree: record.worktree, mainRepository: main) }) else { return }
                        print("环境 \(name) 的 worktree 删掉了（\(why)），回收")
                        _ = try await self.recycle(record, reason: "worktree 删掉了：\(why)")
                    }
                } catch {
                    print("环境 \(name) 回收失败：\(error.message)")
                }
            }
        }
    }

    /// 删大文件要一会儿，不占着 actor。顺带清掉镜像已经不在的根文件系统模板：平常删镜像时就清了，
    /// 这里补上标签指到新内容（重新拉）留下的、napboxd 被杀留下的、升级前的版本留下的
    func purgeRecycled() async {
        let runtime = runtime
        let messages = await Task.detached { runtime.purgeRecycled() }.value
        for message in messages { print(message) }
        await runtime.purgeRootfsTemplates()
    }
}
