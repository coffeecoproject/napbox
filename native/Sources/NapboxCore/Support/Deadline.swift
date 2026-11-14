// 给一段不能取消的等待加时限：到时不取消它，而是做一件能让它结束的事（比如直接关掉它等着的虚拟机），再接着等它。
import Foundation

public enum Deadline {
    /// 跑 body；超过 seconds 还没完就调一次 onTimeout，然后接着等 body 完。返回 body 有没有超时。
    /// onTimeout 要能让 body 结束，否则还是一直等。body 在调用方的 actor 上跑。
    @discardableResult
    public static func run(seconds: Double, isolation: isolated (any Actor)? = #isolation,
                           onTimeout: @escaping @Sendable () async -> Void, _ body: () async -> Void) async -> Bool {
        let timer = Task { () -> Bool in
            do { try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) } catch { return false }
            await onTimeout()
            return true
        }
        await body()
        timer.cancel()
        return await timer.value
    }
}
