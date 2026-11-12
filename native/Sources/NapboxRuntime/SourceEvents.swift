// 把宿主机挂载目录的变化转给虚拟机（DESIGN.md 第 8 节）：FSEvents 报变化 → SourceChangePlanner 决定发什么 →
// 清虚拟机的目录项缓存（让通知发出后读到的是新内容）→ 发给网络小容器（guard/notify.go）。
import CoreServices
import Foundation
import NapboxCore
import NapboxProtocol

/// 虚拟机在跑的时候才有。发不出去只记日志：通知丢了服务收不到事件，但不影响环境本身；网络小容器真没了由 watchGuard 处理。
actor SourceEventForwarder {
    /// 一次最多发这么多条，发完一批才发下一批：变化多的时候（git checkout）后面的合并着等，不会越攒越多
    static let batchSize = 1000
    /// 刚起环境时网络小容器可能还没开始监听
    static let dialAttempts = 20

    private var planner: SourceChangePlanner
    private let dial: @Sendable () async throws -> FileHandle
    private let refresh: @Sendable () async throws -> Void
    private let environment: String
    private var pending: Set<String> = []
    private var draining = false
    private var closed = false
    private var connection: FileHandle?

    init(environment: String, mounts: [SourceMount], dial: @escaping @Sendable () async throws -> FileHandle,
         refresh: @escaping @Sendable () async throws -> Void) {
        self.environment = environment
        planner = SourceChangePlanner(mounts: mounts)
        self.dial = dial
        self.refresh = refresh
    }

    func add(_ paths: [String]) {
        guard !closed else { return }
        pending.formUnion(paths)
        guard !draining else { return }
        draining = true
        Task { await drain() }
    }

    func close() {
        closed = true
        pending = []
        try? connection?.close()
        connection = nil
    }

    private func drain() async {
        defer { draining = false }
        while !closed, !pending.isEmpty {
            let batch = Array(pending.prefix(Self.batchSize))
            pending.subtract(batch)
            let notifications = planner.notifications(for: batch, stat: SourceFileStat.of)
            if notifications.isEmpty { continue }
            do {
                try await refresh()
                try await send(notifications)
            } catch {
                guard !closed else { return }
                print("环境 \(environment) 发文件变化通知失败：\(error)")
                try? connection?.close()
                connection = nil
            }
        }
    }

    private func send(_ notifications: [SourceNotification]) async throws {
        let handle = try await connected()
        var line = try JSONEncoder().encode(notifications)
        line.append(0x0A)
        let frozen = line
        let reply: Data = try await Blocking.run { () throws(NapboxError) -> Data in
            do {
                try handle.write(contentsOf: frozen)
                // 回话只有一行：不能用 read(upToCount:)，它要读满才返回
                var received = Data()
                var buffer = [UInt8](repeating: 0, count: 4096)
                while !received.contains(0x0A) {
                    let count = read(handle.fileDescriptor, &buffer, buffer.count)
                    guard count > 0 else { throw NapboxError(.internalError, "网络小容器断开了") }
                    received.append(contentsOf: buffer[..<count])
                }
                return received
            } catch let error as NapboxError {
                throw error
            } catch {
                throw NapboxError(.internalError, "\(error)")
            }
        }
        let result = try JSONDecoder().decode(Result.self, from: reply)
        if result.failed > 0 {
            print("环境 \(environment) 有 \(result.failed) 条文件变化通知没发出去，第一条：\(result.first ?? "")")
        }
    }

    private struct Result: Decodable {
        var failed: Int
        var first: String?
    }

    private func connected() async throws -> FileHandle {
        if let connection { return connection }
        var attempt = 0
        while true {
            do {
                let handle = try await dial()
                connection = handle
                return handle
            } catch {
                attempt += 1
                if attempt >= Self.dialAttempts { throw error }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
        }
    }
}

/// FSEvents：宿主机上这些目录里有东西变了就报，一次一批。不用轮询，目录多大都不费事。
/// 这边接得慢时系统会丢掉后面的事件，并在监听的目录上报一条带“丢了事件、自己重扫”标志的事件：这些交给 onDropped。
/// 现在只用来记日志，没有重扫（DESIGN.md 第 2 节「只记日志、没补发的一种情况」）。
public final class SourceEventStream: @unchecked Sendable {
    /// 攒多久报一次。短一点热更新才快；保存一次通常只有一两个事件
    private static let latencySeconds: CFTimeInterval = 0.05
    private static let droppedFlags = FSEventStreamEventFlags(
        kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagUserDropped | kFSEventStreamEventFlagKernelDropped)

    private let queue = DispatchQueue(label: "napbox.source-events")
    private let onChange: @Sendable ([String]) -> Void
    private let onDropped: @Sendable ([String]) -> Void
    private var stream: FSEventStreamRef?

    public init(directories: [String], onChange: @escaping @Sendable ([String]) -> Void,
                onDropped: @escaping @Sendable ([String]) -> Void) throws(NapboxError) {
        self.onChange = onChange
        self.onDropped = onDropped
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
            guard let info else { return }
            let me = Unmanaged<SourceEventStream>.fromOpaque(info).takeUnretainedValue()
            let array = Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue() as NSArray
            let changed = (array as? [String] ?? []).prefix(count).map { $0 }
            let dropped = changed.indices.filter { flags[$0] & SourceEventStream.droppedFlags != 0 }.map { changed[$0] }
            if !dropped.isEmpty { me.onDropped(dropped) }
            me.onChange(changed)
        }
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagNoDefer)
        guard let stream = FSEventStreamCreate(kCFAllocatorDefault, callback, &context, directories as CFArray,
                                               FSEventStreamEventId(kFSEventStreamEventIdSinceNow), Self.latencySeconds, flags) else {
            throw NapboxError(.runtimeUnavailable, "监听不了宿主机的目录：\(directories)")
        }
        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, queue)
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.stream = nil
            throw NapboxError(.runtimeUnavailable, "监听不了宿主机的目录：\(directories)")
        }
    }

    public func stop() {
        guard let stream else { return }
        self.stream = nil
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
    }

    deinit { stop() }
}

/// 宿主机路径的真实写法：FSEvents 报的是解开符号链接后的路径（/tmp 是 /private/tmp）。文件还不存在时解开它所在的目录
public func realDirectory(_ path: String) -> String {
    if let resolved = realpath(path, nil) {
        defer { free(resolved) }
        return String(cString: resolved)
    }
    let parent = (path as NSString).deletingLastPathComponent
    guard parent != path, !parent.isEmpty else { return path }
    return (realDirectory(parent) as NSString).appendingPathComponent((path as NSString).lastPathComponent)
}
