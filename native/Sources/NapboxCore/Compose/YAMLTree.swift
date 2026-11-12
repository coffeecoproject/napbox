// compose 文件读进来后的通用树。标量一律保留原文字符串，等变量替换之后再按字段转类型（compose 也是这个顺序）。
import Foundation
import Yams

indirect enum YAMLTree: Equatable, Sendable {
    case null
    /// quoted：带引号的标量。`"5432"` 和 `5432` 对多数字段一样，但 `"null"` 不是空值。
    case scalar(String, quoted: Bool)
    case sequence([YAMLTree])
    /// 保留原来的顺序，报错和合并时按文件里的顺序来。
    case mapping([(key: String, value: YAMLTree)])

    static func == (a: YAMLTree, b: YAMLTree) -> Bool {
        switch (a, b) {
        case (.null, .null): true
        case let (.scalar(x, qx), .scalar(y, qy)): x == y && qx == qy
        case let (.sequence(x), .sequence(y)): x == y
        case let (.mapping(x), .mapping(y)):
            x.count == y.count && zip(x, y).allSatisfy { $0.key == $1.key && $0.value == $1.value }
        default: false
        }
    }

    subscript(key: String) -> YAMLTree? {
        guard case .mapping(let entries) = self else { return nil }
        return entries.first { $0.key == key }?.value
    }

    var entries: [(key: String, value: YAMLTree)]? {
        if case .mapping(let e) = self { return e }
        return nil
    }

    /// 标量原文。数字、布尔也按字符串给出。
    var string: String? {
        if case .scalar(let s, _) = self { return s }
        return nil
    }

    /// 读一份 compose 文件。重复的键当作问题报出来；YAML 合并键 `<<` 在这里展开。
    static func parse(_ text: String, file: String) throws(ComposeError) -> YAMLTree {
        let node: Node?
        do {
            node = try Yams.compose(yaml: text)
        } catch {
            throw ComposeError([.invalid("\(file)：不是有效的 YAML（\(error)）")])
        }
        guard let node else { return .null }
        var issues: [ComposeIssue] = []
        let tree = convert(node, path: "", file: file, issues: &issues)
        if !issues.isEmpty { throw ComposeError(issues) }
        return tree
    }

    private static let nullWords: Set<String> = ["", "~", "null", "Null", "NULL"]

    private static func convert(_ node: Node, path: String, file: String, issues: inout [ComposeIssue]) -> YAMLTree {
        switch node {
        case .scalar(let s):
            let quoted = s.style == .singleQuoted || s.style == .doubleQuoted
            if !quoted, s.style != .literal, s.style != .folded, nullWords.contains(s.string) { return .null }
            return .scalar(s.string, quoted: quoted || s.style == .literal || s.style == .folded)
        case .sequence(let seq):
            return .sequence(seq.enumerated().map { convert($1, path: "\(path)[\($0)]", file: file, issues: &issues) })
        case .mapping(let map):
            var entries: [(key: String, value: YAMLTree)] = []
            // 合并键 `<<` 带进来的内容：自己写的键优先；`<<` 后面是列表时前面的优先（YAML 的规则，compose 也是）
            var merged: [(key: String, value: YAMLTree)] = []
            for (k, v) in map {
                let key = k.string ?? "\(k)"
                let child = path.isEmpty ? key : "\(path).\(key)"
                if key == "<<", k.scalar?.style == .plain {
                    let sources: [YAMLTree] = switch convert(v, path: child, file: file, issues: &issues) {
                    case .sequence(let items): items
                    case let one: [one]
                    }
                    for source in sources {
                        guard let inherited = source.entries else {
                            issues.append(.invalid("\(file)：\(child)：合并键 `<<` 后面要是映射，或者映射的列表"))
                            continue
                        }
                        for entry in inherited where !merged.contains(where: { $0.key == entry.key }) { merged.append(entry) }
                    }
                    continue
                }
                if entries.contains(where: { $0.key == key }) {
                    issues.append(.invalid("\(file)：\(child)：重复的键"))
                    continue
                }
                entries.append((key, convert(v, path: child, file: file, issues: &issues)))
            }
            return .mapping(merged.filter { inherited in !entries.contains { $0.key == inherited.key } } + entries)
        default:
            issues.append(.unsupported("\(file)：\(path)：不认识的 YAML 写法"))
            return .null
        }
    }

    /// 对所有标量做变量替换（键不替换，和 compose 一致）。
    func interpolated(_ interpolator: Interpolator, path: String, issues: inout [ComposeIssue]) -> YAMLTree {
        switch self {
        case .null: return .null
        case .scalar(let s, let quoted):
            guard s.contains("$") else { return self }
            do {
                return .scalar(try interpolator.interpolate(s), quoted: quoted)
            } catch {
                issues.append(.invalid("\(path)：\(error.message)"))
                return self
            }
        case .sequence(let items):
            return .sequence(items.enumerated().map { $1.interpolated(interpolator, path: "\(path)[\($0)]", issues: &issues) })
        case .mapping(let entries):
            return .mapping(entries.map { e in
                (e.key, e.value.interpolated(interpolator, path: path.isEmpty ? e.key : "\(path).\(e.key)", issues: &issues))
            })
        }
    }
}
