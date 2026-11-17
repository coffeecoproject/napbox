// 宿主机上的目录和文件怎么给到虚拟机（服务的绑定挂载、网络小容器的源码目录、构建的 context），按 HostAccess 来：
// - 不受限：每个来源各自共享（单个文件由框架共享它所在的目录、再绑定这个文件）。
// - confine：只共享代码目录本身（root），来源都在虚拟机里从这份共享里按相对路径绑定。虚拟机启动时按路径打开共享，
//   各自共享的话，查完之后、启动之前路径里有一段被换成符号链接，打开的就是链接指向的宿主机目录；从代码目录里绑定，
//   路径里的符号链接由虚拟机解析，指到的是虚拟机里的位置，到不了宿主机上别的目录（实测过）。
// 两部分要一起用：mount 绑定出来的都靠 root 那份共享，它要挂在同一个 pod 里随虚拟机一起启动的某个容器上。
import Containerization
import CryptoKit
import Foundation
import NapboxCore
import NapboxProtocol

struct HostShares: Sendable {
    let access: HostAccess
    /// 共享只读（构建）：不受限时每份共享只读，confine 时代码目录那份只读
    let readOnly: Bool

    init(_ access: HostAccess, readOnly: Bool = false) {
        self.access = access
        self.readOnly = readOnly
    }

    /// 把宿主机上的 path 挂到容器里的 destination
    func mount(_ path: String, destination: String) throws(NapboxError) -> Containerization.Mount {
        guard let root = access.confinement?.root else {
            return .share(source: path, destination: destination, options: readOnly ? ["ro"] : [])
        }
        guard path == root || path.hasPrefix(root + "/") else {
            throw NapboxError(.pathOutsideDirectory, "\(path) 不在代码目录 \(root) 以内")
        }
        return .any(type: "none", source: "/run/virtiofs/\(Self.tag(root))" + path.dropFirst(root.count), destination: destination,
                    options: ["bind"])
    }

    /// confine 时 mount 绑定的来源都在这份共享里：用到了 mount 的 pod 要把它挂在某个随虚拟机启动的容器上（挂在哪不要紧，
    /// 虚拟机的共享来自各容器的挂载）。不受限时是 nil
    func root(destination: String) -> Containerization.Mount? {
        access.confinement.map { .share(source: $0.root, destination: destination, options: readOnly ? ["ro"] : []) }
    }

    /// 共享在虚拟机里的目录名（/run/virtiofs/<tag>）。和 Containerization 0.53.0 的 hashFilePath 一样算：
    /// URL.resolvingSymlinksInPath 之后的路径的 sha256，取前 36 位。框架锁定了版本，升级时要对一遍
    /// （算错了不会挂错地方，只会因为找不到来源起不来；vm.test.ts、build.test.ts 的 confine 用例会失败）
    static func tag(_ root: String) -> String {
        let resolved = URL(fileURLWithPath: root).resolvingSymlinksInPath().path
        return String(SHA256.hash(data: Data(resolved.utf8)).map { String(format: "%02x", $0) }.joined().prefix(36))
    }
}
