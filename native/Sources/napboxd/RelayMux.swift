// 端口转发的 napboxd 这一头：每个环境一条 vsock，所有转发的连接复用它。
// 协议和原因见 guard/mux.go。一个连接一条 vsock 不行：同时一两百条时虚拟化进程会崩溃。
//
// 线程：RelayMux 的状态只在 vsock 这条 channel 的 event loop 上碰；RelayStreamHandler 的状态只在客户端连接的 event loop 上碰。
import Foundation
import NIOCore
import NIOPosix

private enum Frame {
    static let open: UInt8 = 1
    static let data: UInt8 = 2
    static let window: UInt8 = 3
    static let fin: UInt8 = 4
    static let reset: UInt8 = 5

    static let headerSize = 9
    static let maxPayload = 64 * 1024
    /// 每个方向一开始能发多少，对方写出去多少还多少
    static let initialCredit = 1024 * 1024
    /// 攒够这么多才还额度：每收到一点就还的话，一次小查询要多跑两趟，延迟明显变大
    static let windowBatch = initialCredit / 4
}

private struct DecodedFrame {
    var id: UInt32
    var kind: UInt8
    var payload: ByteBuffer
}

private struct FrameDecoder: ByteToMessageDecoder {
    typealias InboundOut = DecodedFrame

    mutating func decode(context: ChannelHandlerContext, buffer: inout ByteBuffer) throws -> DecodingState {
        guard buffer.readableBytes >= Frame.headerSize,
              let id = buffer.getInteger(at: buffer.readerIndex, as: UInt32.self),
              let kind = buffer.getInteger(at: buffer.readerIndex + 4, as: UInt8.self),
              let length = buffer.getInteger(at: buffer.readerIndex + 5, as: UInt32.self) else { return .needMoreData }
        guard length <= Frame.maxPayload else { throw NapboxRelayError.frameTooLong(length) }
        guard buffer.readableBytes >= Frame.headerSize + Int(length) else { return .needMoreData }
        buffer.moveReaderIndex(forwardBy: Frame.headerSize)
        let payload = buffer.readSlice(length: Int(length))!
        context.fireChannelRead(NIOAny(DecodedFrame(id: id, kind: kind, payload: payload)))
        return .continue
    }
}

enum NapboxRelayError: Error {
    case frameTooLong(UInt32)
    case closed
}

final class RelayMux: @unchecked Sendable {
    private var channel: Channel!
    private var streams: [UInt32: Stream] = [:]
    private var nextID: UInt32 = 1

    private struct Stream {
        let inbound: Channel
        let handler: RelayStreamHandler
        let onData: @Sendable () -> Void
        /// 对方发了 fin：等客户端那边写完再关
        var outputClosed: EventLoopFuture<Void>?
        /// 已经写给客户端、还没还的额度
        var owedCredit = 0
    }

    var isActive: Bool { channel.isActive }

    /// 接管 dialRelay 连好的 vsock
    static func connect(_ relay: FileHandle) async throws -> RelayMux {
        // 复制一份交给 NIO 管，它负责关
        let descriptor = dup(relay.fileDescriptor)
        try relay.close()
        guard descriptor >= 0 else { throw IOError(errnoCode: errno, reason: "dup") }
        let mux = RelayMux()
        mux.channel = try await ClientBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .channelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.addHandler(ByteToMessageHandler(FrameDecoder()))
                    try channel.pipeline.syncOperations.addHandler(RelayMuxHandler(mux: mux))
                }
            }
            .withConnectedSocket(descriptor)
            .get()
        return mux
    }

    /// 把一个接受下来的连接接到虚拟机里的 target（环境的 IP:端口），原样双向转发。
    /// 每收到一段数据调用一次 onData（用来判断闲置）。目标连不上时那头发 reset，连接随之断开。
    func open(_ inbound: Channel, target: String, onData: @escaping @Sendable () -> Void) async throws {
        let handler = RelayStreamHandler(mux: self, onData: onData)
        let loop = channel.eventLoop
        let id: UInt32 = try await loop.submit { [self] in
            guard channel.isActive else { throw NapboxRelayError.closed }
            let id = nextID
            nextID &+= 1
            streams[id] = Stream(inbound: inbound, handler: handler, onData: onData)
            var payload = channel.allocator.buffer(capacity: target.utf8.count)
            payload.writeString(target)
            send(id, Frame.open, payload)
            return id
        }.get()
        try await inbound.eventLoop.submit {
            handler.id = id
            try inbound.pipeline.syncOperations.addHandler(handler)
            // 等唤醒期间客户端已经断开了：channelInactive 不会再来
            if !inbound.isActive { handler.clientGone() }
        }.get()
    }

    // MARK: - 以下都在 vsock 的 event loop 上

    private func send(_ id: UInt32, _ kind: UInt8, _ payload: ByteBuffer?) {
        var header = channel.allocator.buffer(capacity: Frame.headerSize)
        header.writeInteger(id)
        header.writeInteger(kind)
        header.writeInteger(UInt32(payload?.readableBytes ?? 0))
        channel.write(header, promise: nil)
        if let payload { channel.write(payload, promise: nil) }
        channel.flush()
    }

    fileprivate func received(_ frame: DecodedFrame) {
        guard var stream = streams[frame.id] else { return } // 这边已经结束了，路上的帧不用管
        switch frame.kind {
        case Frame.data:
            stream.onData()
            let length = frame.payload.readableBytes
            // 写给客户端之后才还额度：客户端读得慢时虚拟机里的服务跟着等，内存不随输出总量增长
            stream.inbound.writeAndFlush(frame.payload).hop(to: channel.eventLoop).whenSuccess { [self] in
                guard var current = streams[frame.id] else { return }
                current.owedCredit += length
                if current.owedCredit >= Frame.windowBatch {
                    var window = channel.allocator.buffer(capacity: 4)
                    window.writeInteger(UInt32(current.owedCredit))
                    send(frame.id, Frame.window, window)
                    current.owedCredit = 0
                }
                streams[frame.id] = current
            }
        case Frame.window:
            guard let credit = frame.payload.getInteger(at: frame.payload.readerIndex, as: UInt32.self) else { return }
            let handler = stream.handler
            stream.inbound.eventLoop.execute { handler.addCredit(Int(credit)) }
        case Frame.fin:
            let promise = stream.inbound.eventLoop.makePromise(of: Void.self)
            stream.inbound.close(mode: .output, promise: promise)
            stream.outputClosed = promise.futureResult
            streams[frame.id] = stream
        case Frame.reset:
            streams[frame.id] = nil
            // 有 fin 时等写完再关，否则排着队的数据会丢
            if let closed = stream.outputClosed {
                let inbound = stream.inbound
                closed.whenComplete { _ in inbound.close(promise: nil) }
            } else {
                stream.inbound.close(promise: nil)
            }
        default:
            break
        }
    }

    fileprivate func closedAll() {
        for stream in streams.values { stream.inbound.close(promise: nil) }
        streams = [:]
    }

    // MARK: - 客户端连接这边调用，转到 vsock 的 event loop

    fileprivate func clientData(_ id: UInt32, _ data: ByteBuffer) {
        channel.eventLoop.execute { [self] in
            var rest = data
            while let slice = rest.readSlice(length: min(rest.readableBytes, Frame.maxPayload)), slice.readableBytes > 0 {
                send(id, Frame.data, slice)
            }
        }
    }

    fileprivate func clientFinishedSending(_ id: UInt32) {
        channel.eventLoop.execute { [self] in
            if streams[id] != nil { send(id, Frame.fin, nil) }
        }
    }

    fileprivate func clientClosed(_ id: UInt32) {
        channel.eventLoop.execute { [self] in
            if streams.removeValue(forKey: id) != nil { send(id, Frame.reset, nil) }
        }
    }
}

private final class RelayMuxHandler: ChannelInboundHandler {
    typealias InboundIn = DecodedFrame
    private let mux: RelayMux

    init(mux: RelayMux) { self.mux = mux }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) { mux.received(unwrapInboundIn(data)) }
    func channelInactive(context: ChannelHandlerContext) { mux.closedAll() }
    func errorCaught(context: ChannelHandlerContext, error: Error) { context.close(promise: nil) }
}

/// 放在客户端连接上。连接开着 autoRead = false：只有有额度时才读，没读的数据留在 socket 里。
final class RelayStreamHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer

    private let mux: RelayMux
    private let onData: @Sendable () -> Void
    private var context: ChannelHandlerContext?
    private var credit = Frame.initialCredit
    private var reading = false
    private var ended = false
    var id: UInt32 = 0

    fileprivate init(mux: RelayMux, onData: @escaping @Sendable () -> Void) {
        self.mux = mux
        self.onData = onData
    }

    func handlerAdded(context: ChannelHandlerContext) {
        self.context = context
        readIfAllowed()
    }

    func handlerRemoved(context: ChannelHandlerContext) { self.context = nil }

    func addCredit(_ amount: Int) {
        credit += amount
        readIfAllowed()
    }

    private func readIfAllowed() {
        guard credit > 0, !reading, !ended, let context else { return }
        reading = true
        context.read()
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let buffer = unwrapInboundIn(data)
        credit -= buffer.readableBytes
        onData()
        mux.clientData(id, buffer)
    }

    func channelReadComplete(context: ChannelHandlerContext) {
        reading = false
        readIfAllowed()
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if let event = event as? ChannelEvent, case .inputClosed = event { mux.clientFinishedSending(id) }
    }

    func channelInactive(context: ChannelHandlerContext) { clientGone() }
    func errorCaught(context: ChannelHandlerContext, error: Error) { context.close(promise: nil) }

    func clientGone() {
        guard !ended else { return }
        ended = true
        mux.clientClosed(id)
    }
}
