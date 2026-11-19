// 唤醒时连接什么时候放行：它要的服务都就绪了就放行，起环境先结束了就按结束的结果。
import Containerization
import Foundation
import NapboxProtocol
@testable import NapboxRuntime
import Synchronization
import Testing

@Suite struct StartProgressTests {
    @Test func releasedWhenItsOwnServicesAreReady() async throws {
        try await withEnvironment { env in
            let progress = StartProgress()
            let db = Waiting(progress, ["db"])
            let api = Waiting(progress, ["api", "db"])
            progress.created(env)
            progress.serviceReady("cache")
            try await stillWaiting(db, api)

            progress.serviceReady("db")
            #expect(try await db.result.get() === env)
            try await stillWaiting(api)

            progress.serviceReady("api")
            #expect(try await api.result.get() === env)
            // 就绪以后才来的不用等
            #expect(try await progress.environment(whenReady: ["db"]) === env)
        }
    }

    @Test func failureReachesEveryoneStillWaiting() async throws {
        try await withEnvironment { env in
            let progress = StartProgress()
            let api = Waiting(progress, ["api"])
            progress.created(env)
            progress.serviceReady("db")
            // db 的连接已经放行了
            #expect(try await progress.environment(whenReady: ["db"]) === env)
            try await stillWaiting(api)

            let failure = NapboxError(.serviceFailed, "api 起不来")
            progress.finished(.failure(failure))
            #expect(await api.result.failure?.message == failure.message)
            // 结束以后才来的也按结束的结果，它要的服务就绪过也一样：虚拟机已经停了
            #expect(await Waiting(progress, ["db"]).result.failure?.code == failure.code)
        }
    }

    /// 要等整个环境的连接（它等的服务里有 develop.watch 同步规则）：服务都就绪了也不放行，起完才放行
    @Test func wholeEnvironmentWaiterIsReleasedOnlyWhenFinished() async throws {
        try await withEnvironment { env in
            let progress = StartProgress()
            let api = Waiting(progress, nil)
            progress.created(env)
            progress.serviceReady("db")
            progress.serviceReady("api")
            try await stillWaiting(api)
            progress.finished(.success(env))
            #expect(try await api.result.get() === env)
        }
    }

    /// 排在前面的不是这次唤醒（比如正在 up）：唤醒什么都没做就结束了，没有哪个服务报过就绪
    @Test func finishingReleasesWaitersWhoseServicesNeverReported() async throws {
        try await withEnvironment { env in
            let progress = StartProgress()
            let db = Waiting(progress, ["db"])
            try await stillWaiting(db)
            progress.finished(.success(env))
            #expect(try await db.result.get() === env)
        }
    }
}

/// 在后台等着的一个连接
private final class Waiting: Sendable {
    private final class Flag: Sendable {
        private let value = Mutex(false)
        func withLock<R>(_ body: (inout Bool) -> R) -> R { value.withLock { body(&$0) } }
    }

    private let released = Flag()
    private let task: Task<Result<RunningEnvironment, NapboxError>, Never>

    /// - services：nil 是等整个环境起完
    init(_ progress: StartProgress, _ services: Set<String>?) {
        let released = released
        task = Task {
            let result: Result<RunningEnvironment, NapboxError>
            do throws(NapboxError) {
                result = .success(try await progress.environment(whenReady: services))
            } catch {
                result = .failure(error)
            }
            released.withLock { $0 = true }
            return result
        }
    }

    var isReleased: Bool { released.withLock { $0 } }
    var result: Result<RunningEnvironment, NapboxError> { get async { await task.value } }
}

private extension Result {
    var failure: Failure? { if case .failure(let error) = self { error } else { nil } }
}

/// 给它一点时间，确认还没放行（没来得及开始等的也算没放行，不会误报）
private func stillWaiting(_ waiting: Waiting...) async throws {
    try await Task.sleep(for: .milliseconds(50))
    for w in waiting { #expect(!w.isReleased) }
}

/// 一个没有虚拟机的环境：StartProgress 只是把它交给等的连接，不碰它
private func withEnvironment(_ body: (RunningEnvironment) async throws -> Void) async throws {
    struct NoVirtualMachines: VirtualMachineManager {
        func create(config: some VMCreationConfig) async throws -> any VirtualMachineInstance { throw CancellationError() }
    }
    let directory = FileManager.default.temporaryDirectory.appending(path: "napbox-test-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let pod = try LinuxPod("napbox-test", vmm: NoVirtualMachines()) { _ in }
    let env = RunningEnvironment(
        pod: pod, logs: [:], stopSignals: [:], images: [:],
        layout: try EnvironmentLayout(directory: directory), addresses: [:], hostServices: try await HostServices.start([], pod: pod)
    )
    try await body(env)
}
