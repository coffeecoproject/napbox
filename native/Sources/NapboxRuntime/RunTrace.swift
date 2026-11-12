// 一次起环境的经过：每个服务用的镜像、什么时候启动、什么时候就绪（运行记录用，DESIGN.md 第 9 节）。
// 起到一半失败时也留着已经走到的部分。
import Foundation
import NapboxProtocol
import Synchronization

public final class RunTrace: Sendable {
    private let entries = Mutex<[String: ServiceRun]>([:])

    public init() {}

    /// 按服务名排序
    public var services: [ServiceRun] { entries.withLock { $0.values.sorted { $0.service < $1.service } } }

    func image(_ service: String, reference: String, digest: String, platformDigest: String) {
        entries.withLock { $0[service] = ServiceRun(service: service, image: reference, digest: digest, platformDigest: platformDigest) }
    }

    func skipped(_ service: String) { entries.withLock { $0[service]?.skipped = true } }
    func started(_ service: String) { entries.withLock { $0[service]?.startedAt = Date() } }

    func ready(_ service: String, _ readiness: ServiceRun.Readiness) {
        entries.withLock {
            $0[service]?.readyAt = Date()
            $0[service]?.readiness = readiness
        }
    }
}
