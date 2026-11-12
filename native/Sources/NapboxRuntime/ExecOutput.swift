import Foundation
import NapboxProtocol

/// 一条 exec 的输出缓冲。积压到上限时写入方等着：Containerization 不再读，虚拟机里的管道满了，命令就停在写输出上，
/// 和命令接在一个读得慢的管道后面一样。这样内存不随输出总量增长，输出也不用丢。
///
/// 写入方在 Containerization 读输出的线程（GCD）上同步调用，等待时占住这个线程：一条被堵的流占一个。
/// 2026-11-08 实测 50 条命令同时被堵，别的命令照常（约 40 毫秒）。
public final class ExecOutput: @unchecked Sendable {
    /// 积压上限（字节）。stdout 和 stderr 共用：调用方只读一条连接，分开算也不会更快
    static let capacity = 1 << 20
    /// 命令退出后没有新输出多久，算读完了。还在途中的输出会在这段时间里到达
    private static let quiet: TimeInterval = 0.5
    /// 命令退出后最多再收这么多字节。虚拟机里 vminitd 这时把管道里剩下的转完就关（还在途中的不到 1MB），
    /// 但后台进程不停往管道里写时，它一直读不空，不设限就等不到读完。超过这个量的只会是后台进程的输出
    private static let afterExitLimit = 16 << 20

    /// 按顺序取出输出。发完一块要调用 sent
    public let chunks: AsyncStream<StreamOutput>
    private let continuation: AsyncStream<StreamOutput>.Continuation
    private let condition = NSCondition()
    private var queued = 0
    private var total = 0
    private var open = true
    private var everFull = false
    private var lastWrite = Date.distantPast

    public init() {
        (chunks, continuation) = AsyncStream.makeStream(of: StreamOutput.self)
    }

    /// 排进队列；积压到上限时等到有空位或 close。close 之后的输出丢弃
    func write(_ chunk: StreamOutput) {
        condition.lock()
        while open, queued >= Self.capacity {
            everFull = true
            condition.wait()
        }
        guard open else {
            condition.unlock()
            return
        }
        queued += chunk.data.count
        total += chunk.data.count
        lastWrite = Date()
        condition.unlock()
        continuation.yield(chunk)
    }

    /// 这一块发完了（或者发不出去了），腾出空位
    public func sent(_ chunk: StreamOutput) {
        condition.lock()
        queued -= chunk.data.count
        condition.broadcast()
        condition.unlock()
    }

    /// 不再收新输出，放开等着的写入方。已经排队的照常取出。可以重复调用
    public func close() {
        condition.lock()
        open = false
        condition.broadcast()
        condition.unlock()
        continuation.finish()
    }

    /// 命令退出后调用，等还没读的输出。LinuxProcess.wait 只等输出 3 秒，之后 delete 会关掉输出的连接，
    /// 调用方读得慢时（写入方在等）还在途中的输出就丢了。这里等它们读完、发完。
    /// 没堵过的命令读取一直跟得上，wait 返回时已经读完，不用等。等待不设时限：调用方一直不读就一直等，直到断开（任务被取消）。
    /// Containerization 不告诉写入方输出读到头了，所以用“队列空了，而且一段时间没有新输出”来判断。
    func waitForUnread() async {
        guard let start = totalIfEverFull() else { return }
        while !Task.isCancelled, !isDrained(since: start) {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    private func totalIfEverFull() -> Int? {
        condition.lock()
        defer { condition.unlock() }
        return everFull ? total : nil
    }

    private func isDrained(since start: Int) -> Bool {
        condition.lock()
        defer { condition.unlock() }
        return !open
            || total - start >= Self.afterExitLimit
            || (queued == 0 && Date().timeIntervalSince(lastWrite) >= Self.quiet)
    }
}
