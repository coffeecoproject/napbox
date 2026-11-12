// logs、exec 要的环境：找环境、唤醒、占住不让它闲置休眠。流式收发在 Streams.swift。
import Foundation
import NIOCore
import NapboxCore
import NapboxProtocol
import NapboxRuntime

extension Daemon {
    // MARK: - logs、exec（流式部分在 Streams.swift）

    struct LogsTarget: Sendable {
        let name: String
        let file: URL
    }

    func logsTarget(_ target: EnvironmentTarget, service: String) async throws(NapboxError) -> LogsTarget {
        let record = try await record(for: target)
        try requireService(record, service)
        return LogsTarget(name: record.name, file: runtime.logFile(record, service: service))
    }

    func isRegistered(_ name: String) -> Bool { store.state.environment(name) != nil }

    nonisolated func hold(_ name: String) { activity.hold(name) }
    nonisolated func release(_ name: String) { activity.release(name) }

    /// exec 要的环境：先占住（不让它闲置休眠），休眠的先唤醒。成功时调用方用完要 release。
    func execTarget(_ target: EnvironmentTarget, service: String) async throws(NapboxError) -> (name: String, env: RunningEnvironment) {
        let record = try await record(for: target)
        try requireService(record, service)
        activity.hold(record.name)
        do throws(NapboxError) {
            if running[record.name] == nil { try await wake(record.name) }
            guard let env = running[record.name] else {
                throw NapboxError(.serviceFailed, "环境 \(record.name) 唤醒后又停了，再试一次")
            }
            return (record.name, env)
        } catch {
            activity.release(record.name)
            throw error
        }
    }

    func requireService(_ record: EnvironmentRecord, _ service: String) throws(NapboxError) {
        guard let project = record.definition else { throw NapboxError(.environmentNotFound, "环境 \(record.name) 没有定义，先 napbox up") }
        guard project.service(service) != nil else {
            throw NapboxError(.serviceNotFound, "环境 \(record.name) 里没有服务 \(service)，有：\(project.services.map(\.name).joined(separator: "、"))")
        }
    }
}
