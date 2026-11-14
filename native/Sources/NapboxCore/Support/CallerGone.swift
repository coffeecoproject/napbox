// 调用方走了（命令行断开、超时）的记号。排在环境队列里的操作不随调用方取消（取消到一半会留下半截状态），
// 由它在还没动东西的地方自己看一眼，停下来。
import Synchronization

public final class CallerGone: Sendable {
    private let gone = Atomic<Bool>(false)

    public init() {}

    public func mark() { gone.store(true, ordering: .relaxed) }

    public var isGone: Bool { gone.load(ordering: .relaxed) }
}
