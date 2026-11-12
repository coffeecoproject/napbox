import Foundation
import Testing
@testable import NapboxCore

@Suite struct SubprocessTests {
    /// 很多条命令同一时刻跑（napboxd 同时收到很多个按目录找环境的请求、每个都要问一次 git 时就是这样）：
    /// 全部跑完，两路输出都对。等的那条线程不能再去要一条公用线程来读输出：
    /// 公用线程全被等着的命令占满时谁也等不到，会永远卡住。
    @Test func manyAtOnce() {
        let count = 300
        let correct = Counter()
        let finished = DispatchSemaphore(value: 0)
        Task {
            await withTaskGroup(of: Void.self) { group in
                for _ in 0..<count {
                    group.addTask {
                        let output = await Blocking.run {
                            try? Subprocess.run("/bin/sh", ["-c", "sleep 0.3; echo out; echo err >&2"])
                        }
                        if output?.status == 0, output?.stdout == Data("out\n".utf8), output?.stderr == Data("err\n".utf8) { correct.add() }
                    }
                }
            }
            finished.signal()
        }
        #expect(finished.wait(timeout: .now() + 60) == .success, "60 秒没跑完：卡住了")
        #expect(correct.value == count)
    }

    /// 两路输出都超过管道缓冲（64KB）也读得完
    @Test func largeOutputOnBothPipes() throws {
        let output = try Subprocess.run("/bin/sh", ["-c", "head -c 300000 /dev/zero; head -c 300000 /dev/zero >&2"])
        #expect(output.status == 0)
        #expect(output.stdout.count == 300_000)
        #expect(output.stderr.count == 300_000)
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func add() { lock.withLock { count += 1 } }
    var value: Int { lock.withLock { count } }
}
