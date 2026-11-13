// 一次起环境走到哪了：虚拟机建好没有、哪些服务就绪了、最后成没成。
// 唤醒时进来的连接在这里等它要连的服务（和它依赖的）就绪就开始转发，不用等整个环境起完；
// 这些服务里有要同步文件的（develop.watch）才等整个环境。
import NapboxProtocol
import Synchronization

public final class StartProgress: Sendable {
    /// needed：等哪些服务就绪，nil 是等整个环境起完
    private typealias Waiter = (needed: Set<String>?, continuation: CheckedContinuation<Result<RunningEnvironment, NapboxError>, Never>)

    private struct State {
        var environment: RunningEnvironment?
        var ready: Set<String> = []
        var outcome: Result<RunningEnvironment, NapboxError>?
        var waiters: [Waiter] = []
    }

    private let state = Mutex(State())

    public init() {}

    /// 虚拟机建好了，服务还没启动
    func created(_ environment: RunningEnvironment) {
        settle { $0.environment = environment }
    }

    /// 服务就绪了（唤醒时跳过的、已经跑完的一次性服务也算）
    func serviceReady(_ name: String) {
        settle { $0.ready.insert(name) }
    }

    /// 起环境结束了：成功是整个环境都就绪了，失败时还在等的都收到这个错误
    public func finished(_ outcome: Result<RunningEnvironment, NapboxError>) {
        settle { $0.outcome = outcome }
    }

    /// 等这些服务都就绪，返回环境；nil 是等整个环境起完。起环境先结束了就按结束的结果。
    public func environment(whenReady services: Set<String>?) async throws(NapboxError) -> RunningEnvironment {
        try await withCheckedContinuation { continuation in
            settle { $0.waiters.append((services, continuation)) }
        }.get()
    }

    /// 改状态，再把能放行的等待者放行（在锁外面放行）
    private func settle(_ change: (inout State) -> Void) {
        let resumed = state.withLock { s -> [(Waiter, Result<RunningEnvironment, NapboxError>)] in
            change(&s)
            var resumed: [(Waiter, Result<RunningEnvironment, NapboxError>)] = []
            s.waiters.removeAll { waiter in
                let result: Result<RunningEnvironment, NapboxError>? = if let outcome = s.outcome {
                    outcome
                } else if let env = s.environment, let needed = waiter.needed, needed.isSubset(of: s.ready) {
                    .success(env)
                } else {
                    nil
                }
                guard let result else { return false }
                resumed.append((waiter, result))
                return true
            }
            return resumed
        }
        for (waiter, result) in resumed { waiter.continuation.resume(returning: result) }
    }
}
