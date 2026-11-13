// 当前目录属于哪个项目、哪个 worktree。项目以主仓库路径为标识。
import Foundation
import NapboxProtocol

public struct WorktreeLocation: Equatable, Sendable {
    /// 主工作区（主仓库）的路径
    public var mainRepository: URL
    /// 当前所在 worktree 的根目录
    public var worktree: URL

    public var isMain: Bool { worktree.path == mainRepository.path }

    public init(mainRepository: URL, worktree: URL) {
        self.mainRepository = mainRepository
        self.worktree = worktree
    }

    /// 从某个目录出发，用 git 找到它所在的 worktree 和主仓库。
    public static func locate(from directory: URL) throws(NapboxError) -> WorktreeLocation {
        let output: String
        do {
            output = try Git.run(["-C", directory.path, "rev-parse", "--path-format=absolute", "--show-toplevel", "--git-common-dir"])
        } catch {
            throw NapboxError(.notInRepository, "\(directory.path) 不在 git 仓库里。napbox 按 git worktree 区分环境，请在项目的 worktree 里执行。（\(error.message)）")
        }
        let lines = output.split(separator: "\n").map(String.init)
        guard lines.count == 2 else { throw NapboxError(.notInRepository, "git rev-parse 的输出看不懂：\(output)") }
        let worktree = URL(fileURLWithPath: lines[0]).resolvingSymlinksInPath()
        let commonDir = URL(fileURLWithPath: lines[1]).resolvingSymlinksInPath()
        guard commonDir.lastPathComponent == ".git" else {
            throw NapboxError(.notInRepository, "\(commonDir.path) 不是普通仓库的 .git 目录（比如裸仓库），napbox 暂不支持")
        }
        return WorktreeLocation(mainRepository: commonDir.deletingLastPathComponent(), worktree: worktree)
    }
}

/// worktree 持有的环境，它的 worktree 还在不在。
/// 只有确定不在了才算 gone；git 查不了、所在的卷没挂载时是 unknown，这次不回收，免得误删还在用的环境。
public enum WorktreePresence: Equatable, Sendable {
    case present
    /// 不在了，附上原因
    case gone(String)
    /// 判断不了，附上原因
    case unknown(String)

    /// - worktree、mainRepository：登记里的绝对路径
    public static func check(worktree: String, mainRepository: String, volumesRoot: String = "/Volumes") -> WorktreePresence {
        let fm = FileManager.default
        // 外接盘、磁盘映像、网络盘都挂在 /Volumes/<卷名>：挂载点不在就是卷没挂上，下面的目录看不到不代表删了
        for path in [worktree, mainRepository] {
            if let volume = unmountedVolume(of: path, volumesRoot: volumesRoot) { return .unknown("\(path) 所在的卷 \(volume) 没挂载") }
        }
        guard fm.fileExists(atPath: worktree) else { return .gone("目录 \(worktree) 不在了") }
        guard fm.fileExists(atPath: mainRepository + "/.git") else { return .gone("主仓库 \(mainRepository) 不在了") }
        let output: String
        do {
            output = try Git.run(["-C", mainRepository, "worktree", "list", "--porcelain", "-z"])
        } catch {
            return .unknown("git worktree list 失败：\(error.message)")
        }
        // -z：每一项以 NUL 结尾，worktree 那一项是 "worktree <路径>"。两边按同样的方式解析符号链接再比
        // （Foundation 会把 /private/var 写成 /var，git 给的和登记的写法可能不同）
        func canonical(_ path: String) -> String { URL(fileURLWithPath: path).resolvingSymlinksInPath().path }
        let paths = output.split(separator: "\0").filter { $0.hasPrefix("worktree ") }
            .map { canonical(String($0.dropFirst("worktree ".count))) }
        return paths.contains(canonical(worktree)) ? .present : .gone("\(worktree) 不在主仓库的 git worktree list 里了")
    }

    /// path 在 `<volumesRoot>/<卷名>/` 下面而这个挂载点不在时，返回挂载点
    private static func unmountedVolume(of path: String, volumesRoot: String) -> String? {
        guard path.hasPrefix(volumesRoot + "/"), let name = path.dropFirst(volumesRoot.count + 1).split(separator: "/").first else { return nil }
        let volume = "\(volumesRoot)/\(name)"
        return FileManager.default.fileExists(atPath: volume) ? nil : volume
    }
}

enum Git {
    struct Failure: Error {
        var message: String
    }

    static func run(_ arguments: [String]) throws(Failure) -> String {
        let output: Subprocess.Output
        do { output = try Subprocess.run("/usr/bin/git", arguments) } catch {
            throw Failure(message: "运行 git 失败：\(error.localizedDescription)")
        }
        guard output.status == 0 else { throw Failure(message: output.stderrText) }
        return String(decoding: output.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
