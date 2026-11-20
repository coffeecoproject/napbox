// 环境的定义是从哪些文件读出来的。up、create 时记进登记，之后看这些文件在那次之后有没有改过：
// 唤醒、watch 重建、reset 用的都是那次存下的定义，改了 compose 要重新 up 才生效（napboxd 的 composeChanges）。
// 只比文件，不比调用方的环境变量：唤醒是连接触发的，拿不到那些变量。
import CryptoKit
import Foundation

public struct ComposeSource: Codable, Equatable, Sendable {
    /// 找 compose、读 compose 时碰过的一个宿主机文件
    public struct File: Codable, Equatable, Sendable {
        /// 绝对路径
        public var path: String
        /// 当时内容的 sha256；看过但不存在的是 nil（之后冒出来同样算改过，比如新加了 compose.override.yaml）
        public var digest: String?

        public init(path: String, digest: String?) {
            self.path = path
            self.digest = digest
        }

        /// 读到了内容的
        public init(path: String, text: String) {
            self.init(path: path, digest: ComposeSource.digest(text))
        }
    }

    /// 改过的一个文件
    public struct Change: Equatable, Sendable {
        public enum Kind: Equatable, Sendable {
            case modified
            /// 那次读过，现在没了
            case removed
            /// 那次没有，现在有了
            case added
            /// 现在读不了（没权限、不是文本、confine 的环境里指到了代码目录外面）
            case unreadable
        }

        public var path: String
        public var kind: Kind
    }

    /// 每个路径一条，按给的顺序（napboxd 把读进定义的放前面：compose 文件、.env、env_file，然后是找文件时看过的）
    public var files: [File]

    /// - seen：同一个文件碰过几次的（找的时候看过、后来又读了）只记一条，留读到的内容；路径留先给的那个写法。
    ///   是不是同一个文件按 located 认，不按字面：启动目录和找到 compose 的目录可能是同一个地方的两种写法
    public init(_ seen: [File]) {
        var files: [File] = []
        var located: [String] = []
        for file in seen {
            let place = Self.located(file.path)
            if let i = located.firstIndex(of: place) {
                if let digest = file.digest { files[i].digest = digest }
            } else {
                files.append(file)
                located.append(place)
            }
        }
        self.files = files
    }

    /// 认文件用的路径：所在目录解成真实路径，文件名照原样。同一个文件的两种写法（/var 和 /private/var、
    /// 经过符号链接的目录）得到同一个；文件自己是符号链接时不跟过去，还是写的那个名字。目录解不开的照原样
    private static func located(_ path: String) -> String {
        let path = PathText.normalized(path)
        let directory = (path as NSString).deletingLastPathComponent
        guard let real = Confinement.realPath(directory) else { return path }
        return (real as NSString).appendingPathComponent((path as NSString).lastPathComponent)
    }

    static func digest(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// 现在和记下的不一样的文件，按记下的顺序。读法和那次一样（access）
    public func changes(access: HostAccess) -> [Change] {
        files.compactMap { file -> Change? in
            guard let recorded = file.digest else {
                return access.present(file.path) ? Change(path: file.path, kind: .added) : nil
            }
            let text: String?
            do {
                text = try access.readText(file.path, written: file.path, "")
            } catch {
                return Change(path: file.path, kind: .unreadable)
            }
            guard let text else { return Change(path: file.path, kind: .removed) }
            return Self.digest(text) == recorded ? nil : Change(path: file.path, kind: .modified)
        }
    }

    /// 给人看的一串：改过的文件，在 directory 里面的写相对路径。没改过是 nil
    public func changeSummary(access: HostAccess, relativeTo directory: String) -> String? {
        let changes = changes(access: access)
        guard !changes.isEmpty else { return nil }
        // 在不在 directory 里面按真实路径看（两边的写法可能不一样）；不在里面的照记下的写法显示
        let base = Confinement.realPath(PathText.normalized(directory)) ?? PathText.normalized(directory)
        return changes.map { change in
            let path = Self.located(change.path)
            let shown = path.hasPrefix(base + "/") ? String(path.dropFirst(base.count + 1)) : PathText.normalized(change.path)
            switch change.kind {
            case .modified: return shown
            case .removed: return "\(shown)（没了）"
            case .added: return "\(shown)（新加的）"
            case .unreadable: return "\(shown)（读不了）"
            }
        }.joined(separator: "、")
    }
}
