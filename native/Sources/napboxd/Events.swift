// 事件分发：Daemon 发出事件，每个 subscribe 连接按自己的条件收。
// 不存盘、不补发：断开期间的事件调用方用 status 和 runs 补齐。
import Foundation
import NIOConcurrencyHelpers
import NapboxProtocol

final class EventHub: Sendable {
    private struct Subscriber {
        let filter: SubscribeParams
        let continuation: AsyncStream<EnvironmentEvent>.Continuation
    }

    private let subscribers = NIOLockedValueBox<[UUID: Subscriber]>([:])

    /// 开始收事件；用完调用 unsubscribe
    func subscribe(_ filter: SubscribeParams) -> (id: UUID, events: AsyncStream<EnvironmentEvent>) {
        let (events, continuation) = AsyncStream.makeStream(of: EnvironmentEvent.self)
        let id = UUID()
        subscribers.withLockedValue { $0[id] = Subscriber(filter: filter, continuation: continuation) }
        return (id, events)
    }

    func unsubscribe(_ id: UUID) {
        subscribers.withLockedValue { $0.removeValue(forKey: id) }?.continuation.finish()
    }

    func emit(_ event: EnvironmentEvent) {
        let targets = subscribers.withLockedValue { $0.values.filter { Self.matches($0.filter, event) } }
        for s in targets { s.continuation.yield(event) }
    }

    private static func matches(_ filter: SubscribeParams, _ event: EnvironmentEvent) -> Bool {
        if let owner = filter.owner, event.owner != owner { return false }
        if let names = filter.names, !names.contains(event.environment) { return false }
        return true
    }
}
