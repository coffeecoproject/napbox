// napboxd：常驻后台，在 ~/Library/Application Support/napbox/napboxd.sock 上按行收发 JSON。
import Darwin
import Foundation
import NIOCore
import NIOExtras
import NIOPosix
import NapboxProtocol
import NapboxRuntime

setvbuf(stdout, nil, _IOLBF, 0)
setvbuf(stderr, nil, _IOLBF, 0)

/// 启动或运行中出错：说明原因，退出码 1（不用顶层 throw，那样会以 Fatal error 崩溃）。
func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("napboxd：\(message)\n".utf8))
    exit(1)
}

// napboxd prepare：准备内核、runc、Rosetta 和 vminit 后退出，不监听（napbox setup 调用）
if CommandLine.arguments.dropFirst().first == "prepare" {
    do {
        try await Prepare.run(supportDirectory: Paths.supportDirectory) { print($0) }
        exit(0)
    } catch {
        fail(error.message)
    }
}

// 登录项的文件描述符上限默认只有 256，每个转发的连接要占一个。调到系统允许的最大值
var maxFiles: Int32 = 0
var maxFilesSize = MemoryLayout<Int32>.size
var fileLimit = rlimit()
if sysctlbyname("kern.maxfilesperproc", &maxFiles, &maxFilesSize, nil, 0) == 0, getrlimit(RLIMIT_NOFILE, &fileLimit) == 0 {
    fileLimit.rlim_cur = min(fileLimit.rlim_max, rlim_t(maxFiles))
    if setrlimit(RLIMIT_NOFILE, &fileLimit) != 0 {
        print("调不了文件描述符上限：\(String(cString: strerror(errno)))")
    }
}

let socketPath = Paths.socket.path
do {
    try FileManager.default.createDirectory(at: Paths.supportDirectory, withIntermediateDirectories: true)
} catch {
    fail("建不了目录 \(Paths.supportDirectory.path)：\(error.localizedDescription)")
}

// 只运行一份：锁住 napboxd.lock，进程退出时系统自动释放。拿到锁之后，已有的 socket 文件
// 一定是上一份留下的，可以放心清掉再监听。
let lockFD = open(Paths.lock.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
guard lockFD >= 0 else { fail("打不开 \(Paths.lock.path)：\(String(cString: strerror(errno)))") }
guard flock(lockFD, LOCK_EX | LOCK_NB) == 0 else {
    if errno == EWOULDBLOCK { fail("已经有一份 napboxd 在运行（\(socketPath)），不再启动第二份。") }
    fail("锁不住 \(Paths.lock.path)：\(String(cString: strerror(errno)))")
}

// 网络小容器的程序是 Linux 版的 napbox-guard，和 napboxd 放在同一目录（scripts/build-native.sh 一起编译）
guard let executable = Bundle.main.executableURL else { fail("找不到 napboxd 自己的路径") }
let guardBinary = executable.resolvingSymlinksInPath().deletingLastPathComponent().appending(path: "napbox-guard")
let daemon: Daemon
do {
    daemon = try Daemon(supportDirectory: Paths.supportDirectory, guardBinary: guardBinary)
} catch {
    fail(error.message)
}
let server: NIOAsyncChannel<NIOAsyncChannel<ByteBuffer, ByteBuffer>, Never>
do {
    server = try await ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
        .serverChannelInitializer { channel in
            channel.eventLoop.makeCompletedFuture {
                try channel.pipeline.syncOperations.addHandler(AcceptErrorFilter())
            }
        }
        // 客户端发完请求就关掉写端（比如 nc、管道）时，连接不能跟着关，还要把回应写回去。
        .childChannelOption(ChannelOptions.allowRemoteHalfClosure, value: true)
        .bind(unixDomainSocketPath: socketPath, cleanupExistingSocketFile: true) { channel in
            channel.eventLoop.makeCompletedFuture {
                try channel.pipeline.syncOperations.addHandler(ByteToMessageHandler(LineBasedFrameDecoder()))
                return try NIOAsyncChannel<ByteBuffer, ByteBuffer>(wrappingChannelSynchronously: channel)
            }
        }
} catch {
    fail("在 \(socketPath) 上监听失败：\(error)")
}
// socket 只给当前用户用。
chmod(socketPath, 0o600)

// 收到 SIGTERM / SIGINT 时先停掉运行中的环境（虚拟机属于 napboxd 进程，不停的话数据卷没卸载就断了），
// 再删掉 socket 文件退出，下次启动不会被旧文件挡住。
signal(SIGTERM, SIG_IGN)
signal(SIGINT, SIG_IGN)
// 虚拟机那头关了连接时写 vsock 要报错，不能让信号把 napboxd 和所有环境一起带走
signal(SIGPIPE, SIG_IGN)
let signalSources = [SIGTERM, SIGINT].map { sig in
    let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
    source.setEventHandler {
        print("napboxd 收到信号 \(sig)，停掉运行中的环境后退出")
        Task {
            await daemon.shutdown()
            unlink(socketPath)
            exit(0)
        }
    }
    source.resume()
    return source
}
print("napboxd \(NapboxVersion.current) 在 \(socketPath) 监听（pid \(getpid())）")
await daemon.begin()
let addressMonitor: HostAddressMonitor
do {
    addressMonitor = try HostAddressMonitor { Task { await daemon.hostAddressesChanged() } }
} catch {
    fail(error.message)
}

do {
    try await withThrowingDiscardingTaskGroup { group in
        try await server.executeThenClose { connections in
            for try await connection in connections {
                group.addTask { await serve(connection) }
            }
        }
    }
} catch {
    unlink(socketPath)
    fail("监听中断：\(error)")
}

/// 普通请求一行一回。流式请求（logs、exec）交给 Streams，这个连接之后收到的行（exec 的标准输入）
/// 都转给它，连接断开时告诉它。
func serve(_ connection: NIOAsyncChannel<ByteBuffer, ByteBuffer>) async {
    do {
        try await connection.executeThenClose { inbound, outbound in
            var feed: AsyncStream<Data>.Continuation?
            var stream: Task<Void, Never>?
            defer { feed?.finish() }
            for try await line in inbound {
                let data = Data(line.readableBytesView)
                if let feed {
                    feed.yield(data)
                    continue
                }
                if let request = try? Wire.decoder.decode(Request.self, from: data), Method.streaming.contains(request.method) {
                    let (input, continuation) = AsyncStream.makeStream(of: Data.self)
                    feed = continuation
                    stream = Task { await Streams.handle(request, daemon: daemon, input: input, output: outbound) }
                    continue
                }
                var reply = ByteBuffer(bytes: await daemon.respond(to: data))
                reply.writeInteger(UInt8(ascii: "\n"))
                try await outbound.write(reply)
            }
            feed?.finish()
            await stream?.value
        }
    } catch {
        print("连接出错：\(error)")
    }
}
/// 接受连接时的错误（比如对方连上就断，fcntl 失败）只影响那一个连接：记下来，不往后传，
/// 否则会结束整个监听循环，napboxd 跟着退出。
final class AcceptErrorFilter: ChannelInboundHandler {
    typealias InboundIn = Any

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        print("接受连接出错，已忽略：\(error)")
    }
}
_ = signalSources
_ = addressMonitor
_ = lockFD
