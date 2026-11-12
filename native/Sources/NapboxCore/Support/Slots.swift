/// 简单的计数信号量：限制同时做一件事的数量，排队的按先后顺序。
public actor Slots {
    let limit: Int
    var used = 0
    var waiting: [CheckedContinuation<Void, Never>] = []

    public init(limit: Int) { self.limit = limit }

    public func acquire() async {
        if used < limit {
            used += 1
            return
        }
        await withCheckedContinuation { waiting.append($0) }
    }

    public func release() {
        if waiting.isEmpty { used -= 1 } else { waiting.removeFirst().resume() }
    }
}
