// 环境停下的情况（RunningEnvironment.stop）：没正常停下时说清是哪一步，日志、status 和 snapshot_not_found 都用这一份说明
import Foundation

public struct StopOutcome: Sendable, Equatable {
    /// 过了 stop_grace_period 还没退出、被强制结束的服务
    public struct Overdue: Sendable, Equatable {
        public var service: String
        /// 等了多少秒（compose 的 stop_grace_period，没写是默认的 10 秒）
        public var grace: Double

        public init(service: String, grace: Double) {
            self.service = service
            self.grace = grace
        }
    }

    public var overdue: [Overdue] = []
    /// 停服务之后在虚拟机里存盘（sync）失败
    public var syncFailed = false
    /// 开始停之前虚拟机已经不在了（崩了或被关掉）：里面的服务都没机会正常退出
    public var vmGone = false
    /// 最后一步（卸载磁盘、关虚拟机）报了错时是那个错误：磁盘有没有卸干净、虚拟机有没有关掉都不知道
    public var shutdownFailed: String?
    /// 超过停环境的总时限、直接关掉了虚拟机时是那个时限（秒）
    public var timeLimit: Double?

    public init(overdue: [Overdue] = [], syncFailed: Bool = false, vmGone: Bool = false, shutdownFailed: String? = nil,
                timeLimit: Double? = nil) {
        self.overdue = overdue
        self.syncFailed = syncFailed
        self.vmGone = vmGone
        self.shutdownFailed = shutdownFailed
        self.timeLimit = timeLimit
    }

    public var clean: Bool { problem == nil }

    /// 没正常停下的原因，一句话；正常停下是 nil。服务超时的带上怎么查
    public var problem: String? {
        var parts: [String] = []
        if vmGone { parts.append("停之前虚拟机已经不在了") }
        if !overdue.isEmpty {
            let list = overdue.map { "\($0.service)（等了 \(Self.seconds($0.grace))）" }.joined(separator: "、")
            parts.append("\(list)过了 stop_grace_period 还没退出，被强制结束；先看服务日志里停下那段为什么慢，确实要这么久的再在 compose 里设更长的 stop_grace_period")
        }
        if syncFailed { parts.append("存盘（sync）失败") }
        if let shutdownFailed { parts.append("最后关虚拟机那一步报错：\(shutdownFailed)") }
        if let timeLimit { parts.append("停了 \(Self.seconds(timeLimit))还没停完，直接关掉了虚拟机") }
        return parts.isEmpty ? nil : parts.joined(separator: "；")
    }

    private static func seconds(_ value: Double) -> String {
        value == value.rounded() ? "\(Int(value)) 秒" : "\(value) 秒"
    }
}
