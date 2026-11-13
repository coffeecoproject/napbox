// 宿主机端口代理：环境从登记到回收，napboxd 一直在它的端口上接受连接。
// 环境在运行就直接转发（RelayMux）；在休眠就先暂存连接（不读数据，数据留在 socket 里），唤醒，它连的服务就绪后再转发。
import Foundation
import NIOConcurrencyHelpers
import NIOCore
import NIOPosix

enum PortProxy {
    /// 接管一个已经绑好、正在监听的 socket（PortLocks 给的副本）。每来一个连接调用一次 onAccept，
    /// 由它决定转发到哪里；此时连接还没开始读数据。返回监听的 channel，关掉它就不再接受新连接。
    static func listen(descriptor: Int32, onAccept: @escaping @Sendable (Channel) -> Void) async throws -> Channel {
        try await ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .childChannelOption(ChannelOptions.allowRemoteHalfClosure, value: true)
            .childChannelOption(ChannelOptions.autoRead, value: false)
            .childChannelInitializer { inbound in
                inbound.eventLoop.makeCompletedFuture {
                    try inbound.pipeline.syncOperations.addHandler(AcceptedHandler(onAccept: onAccept))
                }
            }
            .withBoundSocket(descriptor)
            .get()
    }
}

/// 连接激活后才交出去。还没激活时发 read 不算数（连接开着 autoRead = false），之后就再也读不到数据。
private final class AcceptedHandler: ChannelInboundHandler, RemovableChannelHandler {
    typealias InboundIn = NIOAny
    private let onAccept: @Sendable (Channel) -> Void

    init(onAccept: @escaping @Sendable (Channel) -> Void) { self.onAccept = onAccept }

    func channelActive(context: ChannelHandlerContext) {
        onAccept(context.channel)
        context.fireChannelActive()
        context.pipeline.syncOperations.removeHandler(context: context, promise: nil)
    }
}

/// 每个环境最后一次有数据往来的时间（闲置指代理上没有数据往来），
/// 以及正在跑的 napbox exec、napbox logs -f 和正在建立的转发：有它们在时环境不算闲置。
final class ActivityBoard: Sendable {
    private let last = NIOLockedValueBox<[String: Date]>([:])
    private let holds = NIOLockedValueBox<[String: Int]>([:])

    func touch(_ name: String) { last.withLockedValue { $0[name] = Date() } }
    func lastActivity(_ name: String) -> Date? { last.withLockedValue { $0[name] } }
    func forget(_ name: String) { _ = last.withLockedValue { $0.removeValue(forKey: name) } }

    /// exec、logs -f 开始和结束时调用；结束时也算一次活动，闲置从这时开始算
    func hold(_ name: String) {
        holds.withLockedValue { $0[name, default: 0] += 1 }
        touch(name)
    }

    func release(_ name: String) {
        holds.withLockedValue { $0[name] = max(0, ($0[name] ?? 0) - 1) }
        touch(name)
    }

    func isHeld(_ name: String) -> Bool { holds.withLockedValue { ($0[name] ?? 0) > 0 } }
}

/// 每个环境正在转发的连接：休眠时全部断开。
final class ConnectionBoard: Sendable {
    private let open = NIOLockedValueBox<[String: [ObjectIdentifier: Channel]]>([:])

    func add(_ name: String, _ channel: Channel) {
        let id = ObjectIdentifier(channel)
        open.withLockedValue { $0[name, default: [:]][id] = channel }
        channel.closeFuture.whenComplete { [open] _ in
            open.withLockedValue { $0[name]?[id] = nil }
        }
    }

    func closeAll(_ name: String) async {
        let channels = open.withLockedValue { $0.removeValue(forKey: name) ?? [:] }
        for c in channels.values { try? await c.close() }
    }
}
