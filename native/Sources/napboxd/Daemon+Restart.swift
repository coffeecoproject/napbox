// 服务退出后按 restart 整个环境重启（DESIGN.md 第 8 节），要不要重启由 RestartTracker 决定。
import Foundation
import NIOCore
import NapboxCore
import NapboxProtocol
import NapboxRuntime

extension Daemon {
    // MARK: - restart（DESIGN.md 第 8 节）

    /// 就绪以后有服务退出：按它的 restart 决定（RestartTracker）。要重启时整个环境一起重启（单个服务不能单独重启），
    /// 跳过已经跑完的一次性服务。
    func serviceExited(_ name: String, _ env: RunningEnvironment, _ service: String, _ code: Int32) {
        guard running[name] === env, let s = store.state.environment(name)?.definition?.service(service) else { return }
        var session = sessions[name] ?? EnvSession()
        let decision = session.restart.serviceExited(service, policy: s.restart, code: code, at: Date())
        session.exits = Array((session.exits + [ServiceExit(service: service, exitCode: code, at: Date(), restart: decision.action)]).suffix(10))
        sessions[name] = session
        emit(name, .serviceExited) {
            $0.service = service
            $0.exitCode = code
            $0.restart = decision.action
        }
        switch decision.action {
        case .none:
            print("环境 \(name) 的 \(service) 退出了，退出码 \(code)，不重启")
        case .gaveUp:
            print("环境 \(name) 的 \(service) 退出了，退出码 \(code)，已经重启 \(session.restart.restarts(service)) 次，不再重启")
        case .restarting:
            guard let delay = decision.delay else { return } // 已经排上了
            print("环境 \(name) 的 \(service) 退出了，退出码 \(code)，\(String(format: "%.1f", delay)) 秒后整个环境重启")
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                await self?.restartAfterExit(name, env)
            }
        }
    }

    func restartAfterExit(_ name: String, _ env: RunningEnvironment) async {
        sessions[name]?.restart.restartStarted()
        try? await serialized(name) { () throws(NapboxError) in await self.restartNow(name, env) }
    }

    func restartNow(_ name: String, _ env: RunningEnvironment) async {
        // 等待期间休眠了、down 了、重新 up 了，或者 napboxd 要退出：都不用再重启
        guard running[name] === env, !shuttingDown else { return }
        await stopRunning(name)
        guard let record = store.state.environment(name), let project = record.definition else { return }
        do throws(NapboxError) {
            try await launch(record, project: project, skipping: Set(record.completedServices), purpose: .restart)
            print("环境 \(name) 重启好了")
        } catch {
            print("环境 \(name) 服务退出后重启失败：\(error.message)")
        }
    }
}
