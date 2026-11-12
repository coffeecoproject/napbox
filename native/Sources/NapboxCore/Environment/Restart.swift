// 服务退出后要不要重启、等多久：规则和 Docker 一致。always、unless-stopped 退出就重启，
// on-failure 退出码非 0 才重启、:N 限制次数；要重启时整个环境一起重启。退避：等待从 0.1 秒开始每次翻倍，
// 最多 1 分钟；上次起来后稳定跑了 10 秒以上就从 0.1 秒重新算。
import Foundation
import NapboxProtocol

/// 一个环境的重启记录，napboxd 里每个环境一份（不存盘）
public struct RestartTracker: Sendable {
    /// 上次重启等了多久
    var delay: TimeInterval?
    /// 这次是什么时候起来的
    var launchedAt: Date?
    /// 各服务因为退出重启了几次
    var counts: [String: Int] = [:]
    /// 已经排上重启、还没开始：几个服务一起退出时只重启一次
    public private(set) var pending = false

    static let firstDelay: TimeInterval = 0.1
    static let maxDelay: TimeInterval = 60
    static let stableSeconds: TimeInterval = 10

    public init() {}

    /// 环境起来了。restarting 是按 restart 重启的那次，保留退避和次数；别的（up、唤醒、reset）重新算
    public mutating func launched(at now: Date, restarting: Bool) {
        launchedAt = now
        if !restarting {
            delay = nil
            counts = [:]
            pending = false // 排着的那次重启对着旧环境，到时不会再动；新环境的退出要能排上新的
        }
    }

    public struct Decision: Equatable, Sendable {
        public var action: ServiceExit.Restart
        /// 要排一次重启时等多久；不重启，或者已经排上了时是 nil
        public var delay: TimeInterval?
    }

    /// 环境就绪以后有服务退出
    public mutating func serviceExited(_ service: String, policy: RestartPolicy, code: Int32, at now: Date) -> Decision {
        let restarts = counts[service] ?? 0
        guard policy.restarts(afterExit: code) else { return Decision(action: .none) }
        if case .onFailure(let max?) = policy, restarts >= max { return Decision(action: .gaveUp) }
        if pending { return Decision(action: .restarting) }
        counts[service] = restarts + 1
        let ranFor = now.timeIntervalSince(launchedAt ?? .distantPast)
        let next = ranFor >= Self.stableSeconds ? Self.firstDelay : min((delay ?? Self.firstDelay / 2) * 2, Self.maxDelay)
        delay = next
        pending = true
        return Decision(action: .restarting, delay: next)
    }

    /// 排上的重启开始了（或者不用再重启了）
    public mutating func restartStarted() { pending = false }

    public func restarts(_ service: String) -> Int { counts[service] ?? 0 }
}
