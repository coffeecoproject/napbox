// 环境连本机程序（x-napbox.host_services）的本机这一头。
//
//	服务 ──TCP──> host.docker.internal:端口（网桥地址，网络小容器在听，guard/hostservices.go）
//	     ──vsock──> napboxd 在这个虚拟机上听的 vsock 端口（vsockPort，这里）
//	     ──TCP──> 本机 127.0.0.1:端口
//
// 不走网络：出网规则一条不改，到网关、局域网、别的本机端口照样挡着，也不依赖环境所在的网段。
// 本机的程序只要听 127.0.0.1，局域网连不到它。出网模式是 none 时连进来的直接断开（setAllowed）。
// 直接用 vsock，不经本机的 unix socket 文件：socket 路径有 104 字节的上限，环境目录深一点就放不下。
import Containerization
import Foundation
import NapboxCore
import NIOConcurrencyHelpers
import NIOCore
import NIOPosix

final class HostServices: Sendable {
    private let listeners: [VsockListener]
    private let allowed: NIOLockedValueBox<Bool>

    private init(listeners: [VsockListener], allowed: NIOLockedValueBox<Bool>) {
        self.listeners = listeners
        self.allowed = allowed
    }

    /// 本机端口在 vsock 上对应的端口（guard/hostservices.go 的 hostServiceVsockPort 要和它一致）。
    /// 避开 napbox-guard 的 5300 几个、Containerization 自己分的（0x1000_0000 起）和传文件用的（0x2000_0000 起）
    static func vsockPort(_ port: Int) -> UInt32 { 0x3000_0000 + UInt32(port) }

    /// 在虚拟机上给每个端口听一个 vsock 端口。开始时不放行，按出网模式定（setAllowed）
    static func start(_ ports: [Int], pod: LinuxPod) async throws -> HostServices {
        let allowed = NIOLockedValueBox(false)
        if ports.isEmpty { return HostServices(listeners: [], allowed: allowed) }
        let listeners = try await pod.withVirtualMachineInstance { vm in
            var listeners: [VsockListener] = []
            do {
                for port in ports { listeners.append(try vm.listen(vsockPort(port))) }
            } catch {
                for l in listeners { try? l.finish() }
                throw error
            }
            return listeners
        }
        for (port, listener) in zip(ports, listeners) {
            Task.detached {
                for await connection in listener {
                    guard allowed.withLockedValue({ $0 }) else {
                        connection.closeFile()
                        continue
                    }
                    connect(connection, to: port)
                }
            }
        }
        return HostServices(listeners: listeners, allowed: allowed)
    }

    /// 接管环境那头的 vsock，连本机的 127.0.0.1:端口，两头接上。连不上（本机程序没在跑）时两头都关掉，环境那头被断开
    private static func connect(_ connection: FileHandle, to port: Int) {
        // 复制一份交给 NIO 管，它负责关
        let descriptor = dup(connection.fileDescriptor)
        connection.closeFile()
        guard descriptor >= 0 else { return }
        let group = MultiThreadedEventLoopGroup.singleton
        let loop = group.next()
        // 两头接上之前都先不读：先到的数据没有人接就丢了
        let inbound = ClientBootstrap(group: loop)
            .channelOption(ChannelOptions.allowRemoteHalfClosure, value: true)
            .channelOption(ChannelOptions.autoRead, value: false)
            .withConnectedSocket(descriptor)
        inbound.whenSuccess { inbound in
            ClientBootstrap(group: loop)
                .channelOption(ChannelOptions.allowRemoteHalfClosure, value: true)
                .channelOption(ChannelOptions.autoRead, value: false)
                .connect(host: "127.0.0.1", port: port)
                .flatMap { outbound in
                    let (a, b) = Glue.pair()
                    return outbound.pipeline.addHandler(a)
                        .flatMap { inbound.pipeline.addHandler(b) }
                        .flatMap { outbound.setOption(ChannelOptions.autoRead, value: true) }
                        .flatMap { inbound.setOption(ChannelOptions.autoRead, value: true) }
                        .flatMapError { error in
                            outbound.close(promise: nil)
                            return loop.makeFailedFuture(error)
                        }
                }
                .whenFailure { _ in inbound.close(promise: nil) }
        }
    }

    /// 出网模式换了时调用：open 放行，none 不放行（已经连着的不断，和换模式时外网连接的处理不同：
    /// 这里拦的是新连接，本机程序那头不是外网）
    func setAllowed(_ value: Bool) { allowed.withLockedValue { $0 = value } }

    func close() {
        for l in listeners { try? l.finish() }
    }
}

/// 两条连接接在一起，一边读到的写给另一边。对面写不动时这边先不读（背压）；一边不再发了，另一边也关掉发送那半边。
/// 两条连接在同一个 event loop 上，互相调用不用加锁。
private final class Glue: ChannelDuplexHandler, @unchecked Sendable {
    typealias InboundIn = NIOAny
    typealias OutboundIn = NIOAny
    typealias OutboundOut = NIOAny

    private var partner: Glue?
    private var context: ChannelHandlerContext?
    private var pendingRead = false

    static func pair() -> (Glue, Glue) {
        let a = Glue(), b = Glue()
        a.partner = b
        b.partner = a
        return (a, b)
    }

    func handlerAdded(context: ChannelHandlerContext) { self.context = context }

    func handlerRemoved(context: ChannelHandlerContext) {
        self.context = nil
        partner = nil
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) { partner?.context?.write(data, promise: nil) }
    func channelReadComplete(context: ChannelHandlerContext) { partner?.context?.flush() }
    func channelInactive(context: ChannelHandlerContext) { partner?.context?.close(promise: nil) }
    func errorCaught(context: ChannelHandlerContext, error: Error) { context.close(promise: nil) }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if case .inputClosed = event as? ChannelEvent {
            partner?.context?.close(mode: .output, promise: nil)
        }
        context.fireUserInboundEventTriggered(event)
    }

    func channelWritabilityChanged(context: ChannelHandlerContext) {
        if context.channel.isWritable, let partner, partner.pendingRead {
            partner.pendingRead = false
            partner.context?.read()
        }
    }

    func read(context: ChannelHandlerContext) {
        if partner?.context?.channel.isWritable ?? false { context.read() } else { pendingRead = true }
    }
}
