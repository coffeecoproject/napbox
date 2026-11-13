// 会阻塞线程的事（跑外部命令 git、arp，删大文件）放到别的线程上做：调用方的 actor 在等待期间照常处理
// 别的请求（比如删一个大数据卷的时候，别的环境照样能唤醒）。用 Dispatch 的线程，不占 Swift 并发的线程池。
import Dispatch
import NapboxProtocol

public enum Blocking {
    public static func run<T: Sendable>(_ body: @escaping @Sendable () throws(NapboxError) -> T) async throws(NapboxError) -> T {
        let result = await withCheckedContinuation { (continuation: CheckedContinuation<Result<T, NapboxError>, Never>) in
            DispatchQueue.global().async {
                do throws(NapboxError) { continuation.resume(returning: .success(try body())) } catch {
                    continuation.resume(returning: .failure(error))
                }
            }
        }
        return try result.get()
    }

    public static func run<T: Sendable>(_ body: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async { continuation.resume(returning: body()) }
        }
    }
}
