// 多份 compose（-f a -f b）按 compose 的合并规则合成一份：后面的文件覆盖前面的。
// - 映射逐键合并；标量和大多数列表直接替换
// - command、entrypoint、healthcheck.test 整个替换
// - environment、depends_on、build.args、networks 的列表写法先转成映射再合并
// - ports、expose、env_file、tmpfs、profiles、secrets 追加并去重
// - volumes 按容器里的路径合并，同一路径以后面的为准
// - 后面的文件里只写了键、没写值（比如下面的条目都注释掉了）：当作没写，沿用前面的。
//   command、entrypoint 是整个替换的，空值就是清掉（2026-11-13 对着 docker compose config 5.1.4 核对过）
enum ComposeMerge {
    static func merge(_ base: YAMLTree, _ override: YAMLTree) -> YAMLTree {
        if override == .null { return base }
        guard let b = base.entries, let o = override.entries else { return override }
        return .mapping(mergeEntries(b, o) { key, x, y in
            if y == .null { return x }
            return switch key {
            case "services": mergeMapping(x, y) { _, s1, s2 in mergeService(s1, s2) }
            case "volumes", "networks": mergeMapping(x, y) { _, _, v in v }
            default: deepMerge(x, y)
            }
        })
    }

    static func mergeService(_ base: YAMLTree, _ override: YAMLTree) -> YAMLTree {
        if override == .null { return base }
        guard let b = base.entries, let o = override.entries else { return override }
        return .mapping(mergeEntries(b, o) { key, x, y in
            if y == .null, key != "command", key != "entrypoint" { return x }
            return switch key {
            case "environment": deepMerge(asMapping(x, listStyle: .keyValue), asMapping(y, listStyle: .keyValue))
            case "depends_on": mergeMapping(asMapping(x, listStyle: .dependency), asMapping(y, listStyle: .dependency)) { _, _, v in v }
            case "networks": deepMerge(asMapping(x, listStyle: .names), asMapping(y, listStyle: .names))
            case "build":
                mergeEntriesTree(asBuild(x), asBuild(y)) { k, p, q in
                    k == "args" ? deepMerge(asMapping(p, listStyle: .keyValue), asMapping(q, listStyle: .keyValue)) : q
                }
            case "healthcheck": mergeEntriesTree(x, y) { _, _, q in q }
            case "ports", "expose", "env_file", "tmpfs", "profiles", "secrets": appendUnique(x, y)
            case "volumes": mergeVolumes(x, y)
            case "x-napbox", "deploy": deepMerge(x, y)
            case "develop": mergeEntriesTree(x, y) { key, p, q in key == "watch" ? appendUnique(p, q) : q }
            default: y
            }
        })
    }

    // MARK: - 工具

    private static func mergeEntries(
        _ b: [(key: String, value: YAMLTree)], _ o: [(key: String, value: YAMLTree)],
        _ combine: (String, YAMLTree, YAMLTree) -> YAMLTree
    ) -> [(key: String, value: YAMLTree)] {
        var result = b
        for (key, value) in o {
            if let i = result.firstIndex(where: { $0.key == key }) {
                result[i].value = combine(key, result[i].value, value)
            } else {
                result.append((key, value))
            }
        }
        return result
    }

    private static func mergeEntriesTree(_ x: YAMLTree, _ y: YAMLTree, _ combine: (String, YAMLTree, YAMLTree) -> YAMLTree) -> YAMLTree {
        guard let a = x.entries, let b = y.entries else { return y }
        return .mapping(mergeEntries(a, b, combine))
    }

    private static func mergeMapping(_ x: YAMLTree, _ y: YAMLTree, _ combine: (String, YAMLTree, YAMLTree) -> YAMLTree) -> YAMLTree {
        mergeEntriesTree(x, y, combine)
    }

    private static func deepMerge(_ x: YAMLTree, _ y: YAMLTree) -> YAMLTree {
        mergeEntriesTree(x, y) { _, p, q in deepMerge(p, q) }
    }

    private static func appendUnique(_ x: YAMLTree, _ y: YAMLTree) -> YAMLTree {
        guard case .sequence(var a) = asSequence(x), case .sequence(let b) = asSequence(y) else { return y }
        for item in b where !a.contains(item) { a.append(item) }
        return .sequence(a)
    }

    private static func asSequence(_ t: YAMLTree) -> YAMLTree {
        if case .scalar = t { return .sequence([t]) } // env_file: 单个字符串
        return t
    }

    private static func mergeVolumes(_ x: YAMLTree, _ y: YAMLTree) -> YAMLTree {
        guard case .sequence(var a) = x, case .sequence(let b) = y else { return y }
        for item in b {
            if let target = volumeTarget(item), let i = a.firstIndex(where: { volumeTarget($0) == target }) {
                a[i] = item
            } else {
                a.append(item)
            }
        }
        return .sequence(a)
    }

    static func volumeTarget(_ t: YAMLTree) -> String? {
        if let s = t.string {
            let parts = s.split(separator: ":", omittingEmptySubsequences: false)
            return parts.count >= 2 ? String(parts[1]) : String(parts[0])
        }
        return t["target"]?.string
    }

    enum ListStyle { case keyValue, dependency, names }

    /// environment 的 `- KEY=VALUE`、depends_on 的 `- db`、networks 的 `- default` 转成映射写法。
    static func asMapping(_ t: YAMLTree, listStyle: ListStyle) -> YAMLTree {
        guard case .sequence(let items) = t else { return t }
        var entries: [(key: String, value: YAMLTree)] = []
        for item in items {
            guard let s = item.string else { return t }
            switch listStyle {
            case .keyValue:
                if let eq = s.firstIndex(of: "=") {
                    entries.append((String(s[..<eq]), .scalar(String(s[s.index(after: eq)...]), quoted: true)))
                } else {
                    entries.append((s, .null))
                }
            case .dependency:
                entries.append((s, .mapping([("condition", .scalar("service_started", quoted: false))])))
            case .names:
                entries.append((s, .null))
            }
        }
        return .mapping(entries)
    }

    static func asBuild(_ t: YAMLTree) -> YAMLTree {
        if case .scalar = t { return .mapping([("context", t)]) }
        return t
    }
}
