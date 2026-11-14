// 停环境的时限：到时不取消，做一件能让等待结束的事，再接着等。
import Foundation
import Testing
@testable import NapboxCore

@Suite struct DeadlineTests {
    /// 一个只能由别人放开的等待，代替“请求发给卡住的虚拟机、虚拟机关了才失败返回”
    actor Gate {
        private var waiters: [CheckedContinuation<Void, Never>] = []
        private var open = false
        func wait() async {
            if open { return }
            await withCheckedContinuation { waiters.append($0) }
        }
        func release() {
            open = true
            for w in waiters { w.resume() }
            waiters = []
        }
        var released: Bool { open }
    }

    @Test func finishesInTimeWithoutCallingOnTimeout() async {
        let gate = Gate()
        let timedOut = await Deadline.run(seconds: 5, onTimeout: { await gate.release() }) {}
        #expect(!timedOut)
        try? await Task.sleep(nanoseconds: 50_000_000)
        #expect(await !gate.released)
    }

    @Test func onTimeoutLetsTheWaitFinish() async {
        let gate = Gate()
        let started = Date()
        let timedOut = await Deadline.run(seconds: 0.2, onTimeout: { await gate.release() }) { await gate.wait() }
        #expect(timedOut)
        #expect(Date().timeIntervalSince(started) >= 0.2)
    }
}
