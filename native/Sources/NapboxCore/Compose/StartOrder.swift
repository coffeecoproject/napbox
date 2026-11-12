// 按 depends_on 排出启动顺序：依赖的服务排在前面，同一层按名字排，结果稳定。循环依赖在解析时已经报错。
public enum StartOrder {
    public static func order(_ services: [Service]) -> [Service] {
        let byName = Dictionary(uniqueKeysWithValues: services.map { ($0.name, $0) })
        var done = Set<String>()
        var result: [Service] = []
        func visit(_ name: String) {
            guard !done.contains(name), let s = byName[name] else { return }
            done.insert(name)
            for d in s.dependsOn.map(\.service).sorted() { visit(d) }
            result.append(s)
        }
        for s in services.sorted(by: { $0.name < $1.name }) { visit(s.name) }
        return result
    }

    /// 按依赖分层：不依赖别的服务的在第 0 层，其余在它依赖的最深一层的下一层；层内按名字排。
    /// 停服务时倒过来一层一层停（和 docker compose 一样先停依赖别人的）。
    public static func levels(_ services: [Service]) -> [[Service]] {
        var level: [String: Int] = [:]
        for s in order(services) {
            level[s.name] = s.dependsOn.compactMap { level[$0.service] }.max().map { $0 + 1 } ?? 0
        }
        var result = Array(repeating: [Service](), count: (level.values.max() ?? -1) + 1)
        for s in services.sorted(by: { $0.name < $1.name }) { result[level[s.name]!].append(s) }
        return result
    }
}
