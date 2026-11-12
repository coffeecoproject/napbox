// 启动容器用的东西。虚拟机里的 vminitd 自己启动的容器都在虚拟机的网络里，
// 没法每个一个网络；所以让它改用 runc 来启动（LinuxPod 的 ociRuntimePath），前面垫一层 napbox 自己的程序
// （guard/runtime.go，就是 napbox-guard 换个名字），建服务的容器时给它接上自己的网络。
// 这一层、runc、每个服务的地址（net.json）放在一块单独的盘上，这块盘算作 pod 里的一个容器，虚拟机里就看得到它。
import Foundation
import NapboxCore

enum RuntimeContainer {
    /// 在 pod 里的容器名，也是那块盘的文件名。这个容器只加不启动：启动过的容器，停环境时框架会把它的盘卸掉，
    /// 顺序不定，排在它后面停的容器找不到 runc，每个白等 3 秒；没启动过的，盘一直挂到虚拟机关掉。
    static let name = InternalContainers.runtimeName
    /// 垫在 runc 前面那一层在盘里的路径。名字和 guard/runtime.go 的 runtimeProgram 一致：它按这个名字认出自己的用途
    static let program = "/napbox-runc"
    /// runc 和 net.json 要和它在同一个目录（guard/runtime.go）
    static let runc = "/runc"
    static let networkFile = "/net.json"
    /// vminitd 叫它来启动容器的路径（虚拟机里的）
    static let guestProgram = GuardContainer.guestRootfs(name) + program

    static let runcVersion = "1.5.1"
    /// napbox setup 把 runc 放在这（Prepare）
    static func runc(in supportDirectory: URL) -> URL {
        supportDirectory.appending(path: "runc/runc-\(runcVersion)")
    }

    /// net.json 的内容（guard/runcargs.go 的 networkConfig）。键排好序：内容没变，那块盘就沿用
    static func networkConfiguration(_ addresses: [String: String]) throws -> Data {
        struct File: Encodable {
            var gateway: String
            var prefix: Int
            var services: [String: String]
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(File(gateway: ServiceNetwork.gateway, prefix: ServiceNetwork.prefixLength, services: addresses))
    }
}
