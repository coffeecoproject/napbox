// napbox 怎么碰宿主机上的文件：读 compose 用到的文件、定下存进定义的路径、给绑定挂载建目录、起环境前再查。
// 不受限（worktree 持有的、不带 confine 的）照原样；confine 的按 Confinement。碰宿主机文件的地方都走这一份，
// 不在各处自己判断受不受限。虚拟机那边的共享由 NapboxRuntime 的 HostShares 按它来做。
import Foundation
import NapboxProtocol

public enum HostAccess: Equatable, Sendable {
    case open
    case confined(Confinement)

    public var confinement: Confinement? {
        if case .confined(let c) = self { c } else { nil }
    }

    /// 存进定义的路径：不受限原样；confine 换成真实路径，不在代码目录以内是 nil
    public func place(_ path: String) -> String? {
        switch self {
        case .open: path
        case .confined(let c): c.locate(path)
        }
    }

    /// place 是 nil 时怎么说（只有 confine 会是 nil）
    public func outside(_ written: String) -> String {
        confinement?.outside(written) ?? "\(written) 不能用"
    }

    /// 找 compose 文件时算不算有这个文件。confine 时不在代码目录以内（或判断不了）的也算有，读的时候报越界：
    /// 不然越界的路径存不存在会报成不同的错，AI 能拿 COMPOSE_FILE、.napbox.yaml、指出去的 compose.yaml 探宿主机上有什么文件
    public func present(_ path: String) -> Bool {
        if case .confined = self, place(path) == nil { return true }
        return FileManager.default.fileExists(atPath: path)
    }

    /// 读一个文件。不存在是 nil
    public func read(_ path: String) throws(HostReadFailure) -> Data? {
        switch self {
        case .confined(let c):
            return try c.read(path)
        case .open:
            guard FileManager.default.fileExists(atPath: path) else { return nil }
            do {
                return try Data(contentsOf: URL(fileURLWithPath: path))
            } catch {
                throw .unreadable(error.localizedDescription)
            }
        }
    }

    /// 读成文字，不存在是 nil。读不了、越界的说明带上 written 和是哪个字段（p）
    public func readText(_ path: String, written: String, _ p: String) throws(ComposeIssue) -> String? {
        let data: Data?
        do {
            data = try read(path)
        } catch {
            switch error {
            case .outside: throw .outside("\(p)：\(outside(written))")
            case .unreadable(let reason): throw .invalid("\(p)：读不了 \(written)：\(reason)")
            }
        }
        guard let data else { return nil }
        guard let text = String(data: data, encoding: .utf8) else { throw .invalid("\(p)：\(written) 不是 UTF-8 文本") }
        return text
    }

    /// 绑定挂载的来源不存在时建成目录（和 Docker 一样）。confine 的一层层建、不跟符号链接
    public func createDirectory(_ path: String) throws(NapboxError) {
        switch self {
        case .confined(let c):
            try c.createDirectory(path)
        case .open:
            do {
                try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
            } catch {
                throw NapboxError(.internalError, "建不了 \(path)：\(error.localizedDescription)")
            }
        }
    }

    /// 存下来的定义里这个服务的宿主机路径还成不成立（confine 的：还在代码目录以内、还是真实路径）
    public func check(_ service: Service) throws(NapboxError) {
        try confinement?.check(service)
    }
}

public enum HostReadFailure: Error, Equatable {
    /// 不在代码目录里，或者判断不了（confine）
    case outside
    case unreadable(String)
}
