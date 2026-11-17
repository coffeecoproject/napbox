// compose 的问题一次全部报出来，agent 能一次改完，而不是改一处报一处。
import NapboxProtocol

public enum ComposeIssue: Error, Equatable, Sendable, CustomStringConvertible {
    /// 写法本身有错（YAML 错、必填变量没设置、引用了不存在的服务等）
    case invalid(String)
    /// 写法没错，但 napbox 第一版不支持
    case unsupported(String)
    /// confine 的环境用到了代码目录以外的宿主机路径（Confinement）
    case outside(String)

    func prefixed(_ prefix: String) -> ComposeIssue {
        switch self {
        case .invalid(let m): .invalid(prefix + m)
        case .unsupported(let m): .unsupported(prefix + m)
        case .outside(let m): .outside(prefix + m)
        }
    }

    public var description: String {
        switch self {
        case .invalid(let m): "写法有误：\(m)"
        case .unsupported(let m): "不支持：\(m)"
        case .outside(let m): "路径越界：\(m)"
        }
    }
}

public struct ComposeError: Error, Equatable, Sendable {
    public var issues: [ComposeIssue]

    public init(_ issues: [ComposeIssue]) {
        self.issues = issues
    }

    /// 有路径越界（confine）就算 path_outside_directory；其次有任何写法错误算 compose_invalid，
    /// 只剩不支持的写法时算 compose_unsupported。
    public var napboxError: NapboxError {
        let outside = issues.contains { if case .outside = $0 { true } else { false } }
        let invalid = issues.contains { if case .invalid = $0 { true } else { false } }
        return NapboxError(
            outside ? .pathOutsideDirectory : invalid ? .composeInvalid : .composeUnsupported,
            "compose 有 \(issues.count) 处问题：\n" + issues.map { "- \($0)" }.joined(separator: "\n")
        )
    }
}
