// 端口监听和转发、唤醒、休眠。
import Foundation
import NIOCore
import NapboxCore
import NapboxProtocol
import NapboxRuntime

extension Daemon {
    // MARK: - 端口监听和转发

    /// 把登记的端口都锁上。napboxd 启动时被别的程序占着的这时再试：已经放开了就恢复，还占着报 port_unavailable。
    func lockPorts(_ record: EnvironmentRecord) throws(NapboxError) {
        _ = try PortAllocator.assign(record.ports.map(\.request), hostPorts: (record.hostPorts ?? []).map(\.name),
                                     environment: record.name, state: store.state, locks: locks)
    }

    /// 让监听的端口和登记的一致：登记里没有的关掉，新登记的开始监听。没启用的 profile 留着的端口也监听，
    /// 连上来马上断开（route），不唤醒环境，免得连接一直挂着等不到回应。
    func syncListeners(_ name: String) async {
        let wanted = Set(store.state.environment(name)?.ports.map(\.hostPort) ?? [])
        var current = listeners[name] ?? [:]
        for (port, channel) in current where !wanted.contains(port) {
            try? await channel.close()
            current[port] = nil
        }
        for port in wanted where current[port] == nil {
            guard let fd = locks.duplicate(port) else { continue } // 没锁上：起环境时会报 port_unavailable（lockPorts）
            do {
                current[port] = try await PortProxy.listen(descriptor: fd) { [weak self] inbound in
                    Task { await self?.route(inbound, name: name, hostPort: port) }
                }
            } catch {
                close(fd)
                print("环境 \(name) 的端口 \(port) 开始监听失败：\(error)")
            }
        }
        listeners[name] = current.isEmpty ? nil : current
    }

    func closeListeners(_ name: String) async {
        relays[name] = nil
        for c in (listeners.removeValue(forKey: name) ?? [:]).values { try? await c.close() }
    }

    /// 这个环境的 vsock 转发通道（RelayMux），第一个连接来时建。环境重启后虚拟机换了，通道也跟着换；连接失败下次再试。
    private func relay(for name: String, _ environment: RunningEnvironment) async throws -> RelayMux {
        let id = ObjectIdentifier(environment)
        // 别的连接正在连的那条：连上了一起用。没连上或者已经断了：一起等的连接里只有一个去重连，其余的等它那条
        while let existing = relays[name], existing.environment == id {
            if let relay = try? await existing.connecting.value, relay.isActive { return relay }
            if relays[name]?.connecting == existing.connecting { break }
        }
        let connecting = Task { try await RelayMux.connect(try await environment.dialRelay()) }
        relays[name] = (id, connecting)
        do {
            return try await connecting.value
        } catch {
            // 没连上的不留着：下一个连接重新连
            if relays[name]?.connecting == connecting { relays[name] = nil }
            throw error
        }
    }

    /// 新连接：环境在运行就转发；在休眠就先唤醒，连接等它连的服务和这个服务依赖的服务就绪就转发，
    /// 其余服务在后台接着起（整个环境起完前失败的话，虚拟机停掉，已经转发的连接跟着断开）；唤醒失败就断开。
    /// 这些服务里有 develop.watch 同步规则的，连接等整个环境起完。
    func route(_ inbound: Channel, name: String, hostPort: Int) async {
        guard let record = store.state.environment(name),
              let assignment = record.activePorts.first(where: { $0.hostPort == hostPort }) else {
            try? await inbound.close()
            return
        }
        // 连接先登记：休眠、回收、重启停虚拟机时一起断开，不会接到停掉的虚拟机上。
        // 唤醒和建立转发期间占住环境，闲置休眠不会在这时把它停了
        connections.add(name, inbound)
        activity.hold(name)
        defer { activity.release(name) }
        let environment: RunningEnvironment
        if let env = running[name] {
            environment = env
        } else {
            let services = record.definition?.services ?? []
            let needed = StartOrder.dependencies(of: assignment.service, in: services)
            // 休眠期间改的文件，整个环境起完时才同步进去（startWatching）：要等的服务里有同步规则的，连接等到那时
            let synced = services.contains { needed.contains($0.name) && $0.watch.contains(where: \.action.syncs) }
            do {
                environment = try await wakeup(name).environment(whenReady: synced ? nil : needed)
            } catch {
                try? await inbound.close()
                return
            }
        }
        do {
            // 连的是这个服务自己的地址：每个服务有自己的网络，同一个端口可以有好几个服务在听
            guard let address = environment.addresses[assignment.service] else {
                throw NapboxError(.internalError, "运行中的环境里没有服务 \(assignment.service)")
            }
            let board = activity
            let relay = try await relay(for: name, environment)
            try await relay.open(inbound, target: "\(address):\(assignment.containerPort)") { board.touch(name) }
            activity.touch(name)
        } catch {
            print("环境 \(name) 的端口 \(hostPort) 转发到 \(assignment.service) 的 \(assignment.containerPort) 端口失败，断开这个连接：\(error)")
            try? await inbound.close()
        }
    }

    // MARK: - 唤醒和休眠

    /// 连接触发的唤醒：已经有在进行的就等那一次，没有就在后台开始一次。连接只等自己的服务，唤醒本身照样起完整个环境
    /// （不随连接断开而中止）。
    private func wakeup(_ name: String) -> StartProgress {
        if let existing = wakeups[name] { return existing }
        let progress = StartProgress()
        wakeups[name] = progress
        Task {
            do throws(NapboxError) {
                try await self.wake(name, progress: progress)
                if let env = self.running[name] {
                    progress.finished(.success(env))
                } else {
                    progress.finished(.failure(NapboxError(.serviceFailed, "环境 \(name) 唤醒后又停了")))
                }
            } catch {
                progress.finished(.failure(error))
            }
            if self.wakeups[name] === progress { self.wakeups[name] = nil }
        }
        return progress
    }

    /// 连接或 exec 触发的唤醒：用登记里固定下来的定义把环境起来，已经跑完的一次性服务不再启动。
    /// - progress：起到哪了，连接在上面等自己的服务就绪
    func wake(_ name: String, progress: StartProgress = StartProgress()) async throws(NapboxError) {
        try await serialized(name) { () throws(NapboxError) in try await self.wakeNow(name, cooldown: true, progress: progress) }
    }

    /// 明确要求的唤醒（调用方）：不看冷却，服务都就绪后返回。
    func wake(_ params: EnvironmentParams) async throws(NapboxError) -> EnvironmentInfo {
        let record = try await record(for: params.target)
        try await serialized(record.name) { () throws(NapboxError) in
            try await self.wakeNow(record.name, cooldown: false)
            try await self.restartStoppedServices(record.name, purpose: .wake)
        }
        return info(store.state.environment(record.name) ?? record)
    }

    /// - cooldown：刚起失败过时不再试（可能就是排在前面的那次，同时进来的连接不用各自起一次）
    func wakeNow(_ name: String, cooldown: Bool, progress: StartProgress = StartProgress()) async throws(NapboxError) {
        if running[name] != nil { return } // 排队期间别的连接已经把它唤醒了
        if cooldown, let failure = sessions[name]?.lastFailure, Date().timeIntervalSince(failure.at) < Self.launchFailureCooldown {
            throw NapboxError(.serviceFailed, failure.message)
        }
        guard let record = store.state.environment(name), let project = record.definition else {
            throw NapboxError(.environmentNotFound, "环境 \(name) 没有登记或没有定义")
        }
        await wakeSlots.acquire()
        let started = Date()
        do {
            try await launch(record, project: project, skipping: Set(record.completedServices), purpose: .wake, progress: progress)
            await wakeSlots.release()
            print("环境 \(name) 唤醒用了 \(String(format: "%.2f", Date().timeIntervalSince(started))) 秒")
        } catch {
            await wakeSlots.release()
            print("环境 \(name) 唤醒失败：\(error.message)")
            throw error
        }
    }

    /// 手动休眠（napbox sleep、调用方）。临时环境没有休眠。
    func sleep(_ params: EnvironmentParams) async throws(NapboxError) -> EnvironmentInfo {
        let record = try await record(for: params.target)
        if record.temporary != nil {
            throw NapboxError(.badRequest, "临时环境 \(record.name) 不休眠：用完就销毁（napbox down --temp \(record.temporary!)），闲置时它也会自己销毁")
        }
        try await serialized(record.name) { () throws(NapboxError) in await self.stopRunning(record.name, sleep: .request) }
        return info(store.state.environment(record.name) ?? record)
    }

    /// 闲置的环境休眠：代理上 N 分钟没有数据往来、没有 napbox exec 或 logs -f 在跑，而且没有服务设置
    /// keep_awake。临时环境闲置了是销毁：脚本中途断了留下的不会一直占着。
    func sleepIdleEnvironments() async {
        let now = Date()
        for name in running.keys {
            guard let project = store.state.environment(name)?.definition,
                  !project.services.contains(where: \.keepAwake) else { continue }
            let idle = TimeInterval(project.idleMinutes ?? Self.defaultIdleMinutes) * 60
            guard !activity.isHeld(name), let last = activity.lastActivity(name), now.timeIntervalSince(last) >= idle else { continue }
            print("环境 \(name) 闲置 \(Int(now.timeIntervalSince(last))) 秒，停掉（开发环境休眠，临时环境销毁）")
            try? await serialized(name) { () throws(NapboxError) in
                // 排队期间可能又有了数据往来
                if self.activity.isHeld(name) { return }
                if let last = self.activity.lastActivity(name), Date().timeIntervalSince(last) < idle { return }
                await self.sleepOrDestroy(name, .idle)
            }
        }
    }

    /// 虚拟机意外没了：转成休眠，和正常休眠走同一条路（断开连接、记下跑完的一次性服务、释放资源、发事件）。
    /// 不主动重启：用到时才起，反复崩溃也不会自己循环。原因记进 lastFailure，status 里看得到，冷却期内不自动唤醒。
    /// 临时环境是销毁。
    func vmLost(_ name: String, _ env: RunningEnvironment) async {
        try? await serialized(name) { () throws(NapboxError) in await self.vmLostNow(name, env) }
    }

    private func vmLostNow(_ name: String, _ env: RunningEnvironment) async {
        guard running[name] === env else { return } // 排队期间已经停了或换了
        print("环境 \(name) 的虚拟机或网络小容器意外停了（开发环境转成休眠，临时环境销毁）")
        sessions[name, default: EnvSession()].lastFailure = (Date(), "虚拟机或网络小容器意外停了（可能崩溃了），环境转成了休眠。数据卷还在，刚停的 \(Int(Self.launchFailureCooldown)) 秒内不自动唤醒，可以直接调用 wake")
        await sleepOrDestroy(name, .vmLost)
    }

    /// 环境自己该休眠了（闲置、虚拟机没了、出网规则加不上）：临时环境没有休眠，销毁。
    func sleepOrDestroy(_ name: String, _ reason: EnvironmentEvent.SleepReason) async {
        if store.state.environment(name)?.temporary != nil {
            await destroyTemporary(name, reason: "本来该休眠了（\(reason.rawValue)），临时环境不休眠")
        } else {
            await stopRunning(name, sleep: reason)
        }
    }

    /// 停掉环境：先断开正在转发的连接，再停虚拟机。停之前把已经跑完的一次性服务记下来
    /// （它们可能在 up 返回之后才结束），唤醒时就不再启动它们。端口监听不动，有连接进来会再唤醒。
    /// - sleep：这次是休眠时给原因，停完发事件。重启、回收的停是中间步骤，不算休眠，由它们自己发事件
    /// - keepCompleted：false 是定义已经换了，这个环境跑完的一次性服务不再算数
    func stopRunning(_ name: String, sleep: EnvironmentEvent.SleepReason? = nil, keepCompleted: Bool = true) async {
        guard let env = running.removeValue(forKey: name) else { return }
        await stopWatching(name)
        await connections.closeAll(name)
        if keepCompleted { await saveCompleted(name, env) }
        await env.stop()
        if let sleep { emit(name, .slept) { $0.sleepReason = sleep } }
    }

    func saveCompleted(_ name: String, _ env: RunningEnvironment) async {
        let completed = await env.completedServices
        do {
            try store.update { (state: inout NapboxState) throws(NapboxError) in
                if let i = state.environments.firstIndex(where: { $0.name == name }) {
                    state.environments[i].completedServices = completed
                }
            }
        } catch {
            print("环境 \(name) 记录已完成的一次性服务失败：\(error.message)")
        }
    }
}
