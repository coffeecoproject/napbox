// 临时环境（DESIGN.md 第 3 节）：同一个 worktree 里，开发环境之外另起的环境，给测试用，用完销毁。
import Foundation
import NapboxProtocol

public enum TemporaryEnvironment {
    /// 名字是一段：小写字母或数字开头，后面可以有小写字母、数字和 . _ -，不超过 40 个字符
    public static func validate(name: String) throws(NapboxError) {
        guard name.count <= 40, CallerEnvironment.isSegment(Substring(name)) else {
            throw NapboxError(.badRequest, "临时环境的名字 \(name) 的写法不对：小写字母或数字开头，只用小写字母、数字和 . _ -，不超过 40 个字符")
        }
    }

    /// napbox run 自己起的名字
    public static func generatedName() -> String {
        "run-\(UUID().uuidString.prefix(8).lowercased())"
    }
}
