// 调用方持有的环境（DESIGN.md 第 3、9 节）：名字和持有方标识的格式、代码副本目录。
import Foundation
import NapboxProtocol

public enum CallerEnvironment {
    /// 名字是 `前缀/名字`（比如 codeos/goal-12-work），持有方标识是一段（比如 codeos）：小写字母或数字开头，
    /// 后面可以有小写字母、数字和 . _ -。名字里的 / 和 worktree 持有的 `项目/worktree` 一样分两段
    public static func validate(name: String, owner: String) throws(NapboxError) {
        let parts = name.split(separator: "/", omittingEmptySubsequences: false)
        guard name.count <= 100, parts.count == 2, parts.allSatisfy(isSegment) else {
            throw NapboxError(.badRequest, "环境名 \(name) 的写法不对：要写成 前缀/名字（比如 codeos/goal-12-work），每段小写字母或数字开头，只用小写字母、数字和 . _ -，总长不超过 100")
        }
        guard owner.count <= 50, isSegment(Substring(owner)) else {
            throw NapboxError(.badRequest, "持有方标识 \(owner) 的写法不对：小写字母或数字开头，只用小写字母、数字和 . _ -，不超过 50 个字符")
        }
    }

    static func isSegment(_ s: Substring) -> Bool {
        guard let first = s.first, first.isASCII, first.isLowercase || first.isNumber else { return false }
        return s.allSatisfy { $0.isASCII && ($0.isLowercase || $0.isNumber || ".-_".contains($0)) }
    }

    /// 代码副本目录：要是已经存在的绝对路径，返回解析过符号链接的路径（和 worktree 一样按真实路径登记）
    public static func directory(_ path: String) throws(NapboxError) -> URL {
        guard path.hasPrefix("/") else { throw NapboxError(.badRequest, "代码副本目录要写绝对路径，收到 \(path)") }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw NapboxError(.badRequest, "代码副本目录 \(path) 不存在或不是目录")
        }
        return URL(fileURLWithPath: path).resolvingSymlinksInPath()
    }
}
