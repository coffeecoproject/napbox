// 宿主机文件变化 → 要在虚拟机里发的通知（DESIGN.md 第 8 节）。这里只决定发什么，真正去发的是 NapboxRuntime/SourceEvents。
import Foundation

/// 一条源码挂载：宿主机上的路径，和它在网络小容器里的路径。挂的可以是目录，也可以是单个文件
public struct SourceMount: Equatable, Sendable {
    public var hostRoot: String
    public var guardRoot: String
    public var isFile: Bool

    public init(hostRoot: String, guardRoot: String, isFile: Bool = false) {
        self.hostRoot = hostRoot
        self.guardRoot = guardRoot
        self.isFile = isFile
    }
}

/// 一条通知，直接发给 guard/notify.go。mode 为空表示对这个挂载的根目录发信号（根目录改不了属性）
public struct SourceNotification: Codable, Equatable, Sendable {
    public var path: String
    public var mode: UInt32?

    public init(path: String, mode: UInt32?) {
        self.path = path
        self.mode = mode
    }
}

/// 文件现在的样子。比较它来判断文件真的变了没有
public struct SourceFileStat: Codable, Equatable, Sendable {
    public var inode: UInt64
    public var modifiedNanoseconds: Int64
    public var size: Int64
    public var mode: UInt32
    public var isSymlink: Bool
    public var isDirectory: Bool
    /// 管道、套接字这类：既没有内容可同步，打开还可能卡住
    public var isSpecial: Bool

    public init(inode: UInt64, modifiedNanoseconds: Int64, size: Int64, mode: UInt32, isSymlink: Bool, isDirectory: Bool = false, isSpecial: Bool = false) {
        self.inode = inode
        self.modifiedNanoseconds = modifiedNanoseconds
        self.size = size
        self.mode = mode
        self.isSymlink = isSymlink
        self.isDirectory = isDirectory
        self.isSpecial = isSpecial
    }

    /// develop.watch 判断要不要再同步：目录只看权限，下面的东西变了目录的修改时间也变，那不算目录变了（被 ignore 的文件也会让它变）
    public func unchanged(from old: SourceFileStat?) -> Bool {
        guard let old else { return false }
        if isDirectory, old.isDirectory { return mode == old.mode }
        return self == old
    }
}

public struct SourceChangePlanner {
    /// 在虚拟机里建又删的临时目录（guard/notify.go）的名字开头，宿主机也会收到这些变化
    public static let signalPrefix = ".napbox-notify-"
    /// 记多久：足够等到通知引起的那次宿主机事件
    static let memorySeconds: TimeInterval = 30
    static let pruneAbove = 4096

    private let mounts: [SourceMount]
    /// 发过通知时文件的样子（nil 是不存在）。通知本身会让宿主机再报一次变化，样子没变就不再发，否则没完没了
    private var seen: [String: (stat: SourceFileStat?, at: Date)] = [:]

    public init(mounts: [SourceMount]) {
        self.mounts = mounts
    }

    /// 这批路径要发的通知，按路径排序（目录在它里面的文件之前）。
    public mutating func notifications(for paths: [String], now: Date = Date(), stat: (String) -> SourceFileStat?) -> [SourceNotification] {
        if seen.count > Self.pruneAbove {
            seen = seen.filter { now.timeIntervalSince($0.value.at) < Self.memorySeconds }
        }
        var result: [String: SourceNotification] = [:]
        for path in paths {
            // relative 为空：挂的就是这个文件
            let matches: [(SourceMount, String?)] = mounts.compactMap { mount in
                if mount.isFile { return path == mount.hostRoot ? (mount, nil) : nil }
                return Self.relative(path, to: mount.hostRoot).flatMap { Self.ignored($0) ? nil : (mount, $0) }
            }
            guard !matches.isEmpty else { continue }
            let current = stat(path)
            if let before = seen[path], before.stat == current, now.timeIntervalSince(before.at) < Self.memorySeconds { continue }
            seen[path] = (current, now)
            for (mount, relative) in matches {
                let notification: SourceNotification
                if let current, !current.isSymlink {
                    notification = SourceNotification(path: relative.map { mount.guardRoot + "/" + $0 } ?? mount.guardRoot, mode: current.mode)
                } else if let relative {
                    // 删掉了就没东西可 chmod；符号链接 chmod 会改到它指向的文件。都改成通知所在的目录
                    notification = parentNotification(of: relative, in: mount, now: now, stat: stat)
                } else {
                    // 挂的单个文件在宿主机上没了（或者换成了符号链接）：容器里挂着的是原来那个文件，没有可通知的
                    continue
                }
                result[notification.path] = notification
            }
        }
        return result.values.sorted { $0.path < $1.path }
    }

    /// 还在的最近一层目录，一直没有就是挂载的根目录
    private mutating func parentNotification(of relative: String, in mount: SourceMount, now: Date, stat: (String) -> SourceFileStat?) -> SourceNotification {
        var parts = relative.split(separator: "/").dropLast()
        while !parts.isEmpty {
            let parent = parts.joined(separator: "/")
            let host = mount.hostRoot + "/" + parent
            if let s = stat(host), !s.isSymlink {
                seen[host] = (s, now)
                return SourceNotification(path: mount.guardRoot + "/" + parent, mode: s.mode)
            }
            parts = parts.dropLast()
        }
        return SourceNotification(path: mount.guardRoot, mode: nil)
    }

    /// 相对挂载目录的路径。根目录自己不算：里面每次增删它都会变，而且发信号本身也会让它变
    private static func relative(_ path: String, to root: String) -> String? {
        guard path.hasPrefix(root + "/") else { return nil }
        return String(path.dropFirst(root.count + 1))
    }

    /// .git 里每次 git 操作都有一堆变化，开发服务器不看这里；自己建的临时目录不用通知
    private static func ignored(_ relative: String) -> Bool {
        relative.split(separator: "/").contains { $0 == ".git" || $0.hasPrefix(signalPrefix) }
    }
}
