// compose 的问题一次全部报出来，agent 能一次改完，而不是改一处报一处。
import NapboxProtocol

public enum ComposeIssue: Equatable, Sendable, CustomStringConvertible {
    /// 写法本身有错（YAML 错、必填变量没设置、引用了不存在的服务等）
    case invalid(String)
    /// 写法没错，但 napbox 第一版不支持
    case unsupported(String)

    func prefixed(_ prefix: String) -> ComposeIssue {
        switch self {
        case .invalid(let m): .invalid(prefix + m)
        case .unsupported(let m): .unsupported(prefix + m)
        }
    }

    public var description: String {
        switch self {
        case .invalid(let m): "写法有误：\(m)"
        case .unsupported(let m): "不支持：\(m)"
        }
    }
}

public struct ComposeError: Error, Equatable, Sendable {
    public var issues: [ComposeIssue]

    public init(_ issues: [ComposeIssue]) {
        self.issues = issues
    }

    /// 有任何写法错误就算 compose_invalid，只剩不支持的写法时算 compose_unsupported。
    public var napboxError: NapboxError {
        let invalid = issues.contains { if case .invalid = $0 { true } else { false } }
        return NapboxError(
            invalid ? .composeInvalid : .composeUnsupported,
            "compose 有 \(issues.count) 处问题：\n" + issues.map { "- \($0)" }.joined(separator: "\n")
        )
    }
}
