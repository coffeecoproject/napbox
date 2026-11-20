// confine：调用方持有的环境只能用代码副本目录里的东西。compose 里 napbox 会读或会挂进环境的宿主机路径
// （compose 文件、.env、.napbox.yaml、env_file、volumes 的绑定、secrets 的文件、build 的 context 和 Dockerfile、
// .dockerignore、develop.watch 的 path），解开符号链接后都要在这个目录以内，否则报 path_outside_directory，不起环境。
// 代码目录的真实路径 create 时定下、记进登记，之后不再按目录名重新解析：目录本身被换成符号链接时检查不通过，
// 而不是跟着链接把别的目录当成代码目录。
// 读 compose 时查一遍、换成真实路径存进定义；之后每次起环境前按存下来的定义再查一遍（检查之后 AI 还能改目录里的东西）。
// 检查和使用之间被换掉的情况：napboxd 自己读的文件用 O_NOFOLLOW_ANY 打开（路径里有一段变成符号链接就打不开）；
// 挂进虚拟机的只共享代码目录本身，子路径在虚拟机里绑定（NapboxRuntime 的 HostShares），符号链接由虚拟机解析，到不了宿主机。
// 代码目录本身在检查之后、虚拟机打开它之前被换掉，这里挡不住：调用方要保证受限的一方删不掉、建不了这个目录。
// 调用处不直接用它，走 HostAccess。
import Darwin
import Foundation
import NapboxProtocol

public struct Confinement: Equatable, Sendable {
    /// 代码目录的真实路径（create 时定下的）
    public let root: String

    /// create 时：按真实路径算（/tmp 是 /private/tmp）
    public init(directory: String) {
        root = Self.realPath(directory) ?? directory
    }

    /// 登记里记着的
    public init(root: String) {
        self.root = root
    }

    /// 真实路径：解开每一段符号链接。还不存在的部分接在最深的、存在的那一层的真实路径后面。
    /// 中间有一段存在却解不开（指向不存在位置的符号链接、没有权限）时是 nil：判断不了它最后会落到哪
    public static func realPath(_ path: String) -> String? {
        if let resolved = realpath(path, nil) {
            defer { free(resolved) }
            return String(cString: resolved)
        }
        var info = stat()
        if lstat(path, &info) == 0 { return nil }
        let parent = (path as NSString).deletingLastPathComponent
        guard parent != path, !parent.isEmpty, let real = realPath(parent) else { return nil }
        return (real as NSString).appendingPathComponent((path as NSString).lastPathComponent)
    }

    func contains(_ realPath: String) -> Bool { realPath == root || realPath.hasPrefix(root + "/") }

    /// 这个宿主机路径在代码目录里时返回它的真实路径
    func locate(_ path: String) -> String? {
        guard rootIntact, let real = Self.realPath(path), contains(real) else { return nil }
        return real
    }

    /// 代码目录本身还是 create 时那个：是目录、不是符号链接，真实路径没变
    var rootIntact: Bool {
        var info = stat()
        return lstat(root, &info) == 0 && info.st_mode & S_IFMT == S_IFDIR && Self.realPath(root) == root
    }

    /// 报错时怎么说一个越界的路径。不带解出来的真实路径：AI 可以拿符号链接探宿主机上有没有某个文件
    func outside(_ written: String) -> String {
        if !rootIntact {
            return "代码目录 \(root) 本身被换掉了（不再是 create 时的那个目录，比如换成了符号链接），confine 的环境不再起来"
        }
        return "\(written) 解开符号链接后不在代码目录 \(root) 以内（或者指向还不存在的位置），confine 的环境只能用这个目录里的文件"
    }

    /// 读代码目录里的一个文件。不存在是 nil。按真实路径用 O_NOFOLLOW_ANY 打开：查完之后路径里有一段被换成符号链接就打不开
    func read(_ path: String) throws(HostReadFailure) -> Data? {
        guard let real = locate(path) else { throw .outside }
        let fd = open(real, O_RDONLY | O_CLOEXEC | O_NONBLOCK | O_NOFOLLOW_ANY)
        guard fd >= 0 else {
            if errno == ENOENT { return nil }
            if errno == ELOOP { throw .outside }
            throw .unreadable(String(cString: strerror(errno)))
        }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { throw .unreadable("不是普通文件") }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count == 0 { return data }
            guard count > 0 else { throw .unreadable(String(cString: strerror(errno))) }
            data.append(contentsOf: buffer[..<count])
        }
    }

    /// 绑定挂载的来源不存在时建成目录（和 Docker 一样）。从代码目录开始一层层打开，每一层都不跟符号链接：
    /// 查完之后有一段（或者代码目录本身）被换成了符号链接，就停下报错，不会在代码目录外面建目录
    func createDirectory(_ path: String) throws(NapboxError) {
        guard contains(path) else { throw NapboxError(.pathOutsideDirectory, outside(path)) }
        var fd = open(root, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW_ANY)
        guard fd >= 0 else { throw NapboxError(.pathOutsideDirectory, outside(path)) }
        defer { close(fd) }
        for part in path.dropFirst(root.count).split(separator: "/").map(String.init) {
            if mkdirat(fd, part, 0o755) != 0, errno != EEXIST {
                throw NapboxError(.internalError, "建不了 \(path)：\(String(cString: strerror(errno)))")
            }
            let next = openat(fd, part, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
            guard next >= 0 else {
                throw NapboxError(.pathOutsideDirectory, "建 \(path) 时 \(part) 不是目录（可能被换成了符号链接）：\(outside(path))")
            }
            close(fd)
            fd = next
        }
    }

    /// 存下来的定义里一个服务的宿主机路径再查一遍：读 compose 时存的都是真实路径，现在还得是——中间哪一段
    /// （或者代码目录本身）被换成了符号链接，解出来就不是它了。错误里写出服务、字段和路径
    func check(_ s: Service) throws(NapboxError) {
        var problems: [String] = []
        func verify(_ path: String, _ p: String) {
            if !rootIntact || Self.realPath(path) != path || !contains(path) { problems.append("\(p)：\(outside(path))") }
        }
        for v in s.volumes {
            guard let path = v.source.hostPath else { continue }
            let field = if case .secret = v.source { "secrets" } else { "volumes" }
            verify(path, "services.\(s.name).\(field)（挂到 \(v.target)）")
        }
        if let build = s.build {
            verify(build.context, "services.\(s.name).build.context")
            verify(build.dockerfilePath, "services.\(s.name).build.dockerfile")
        }
        for (i, rule) in s.watch.enumerated() {
            verify(rule.path, "services.\(s.name).develop.watch[\(i)].path")
        }
        guard problems.isEmpty else {
            throw NapboxError(.pathOutsideDirectory, "有 \(problems.count) 处宿主机路径不在代码目录以内：\n" + problems.map { "- \($0)" }.joined(separator: "\n"))
        }
    }
}

extension Build {
    /// Dockerfile 在宿主机上的路径：dockerfile 写的是绝对路径就是它，否则相对 context（没写是 context 里的 Dockerfile）
    public var dockerfilePath: String { Self.dockerfilePath(context: context, written: dockerfile) }

    static func dockerfilePath(context: String, written: String?) -> String {
        let written = written ?? "Dockerfile"
        return PathText.normalized(written.hasPrefix("/") ? written : context + "/" + written)
    }
}

/// 只按写法处理路径，不碰文件系统。Foundation 的 standardizedFileURL 会把开头的 /private 去掉，真实路径就对不上了
public enum PathText {
    /// 去掉 `.`、空段，`..` 往上一层
    public static func normalized(_ path: String) -> String {
        var parts: [Substring] = []
        for part in path.split(separator: "/") {
            switch part {
            case ".": continue
            case "..": if !parts.isEmpty { parts.removeLast() }
            default: parts.append(part)
            }
        }
        return "/" + parts.joined(separator: "/")
    }

    /// 从目录 base 到 path 的相对写法（两个都是规整过的绝对路径），比如 ../docker/Dockerfile
    static func relative(_ path: String, from base: String) -> String {
        let a = base.split(separator: "/"), b = path.split(separator: "/")
        var common = 0
        while common < a.count, common < b.count, a[common] == b[common] { common += 1 }
        return (Array(repeating: "..", count: a.count - common) + b[common...].map(String.init)).joined(separator: "/")
    }
}
