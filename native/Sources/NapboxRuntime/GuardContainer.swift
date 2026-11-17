// 网络小容器：程序是 napbox 自带的 napbox-guard，直接写进一个根文件系统，不用镜像。
// 服务各有自己的网络，它留在虚拟机的网络里：加出网规则、转发端口连接、查服务的端口有没有在监听、发文件变化通知、
// 给新的命名卷带上镜像内容、宿主机换掉单个文件后让服务重新挂上、停之前 sync。
import Containerization
import Foundation
import NapboxCore

enum GuardContainer {
    /// 在 pod 里的容器名，也是它的根文件系统的文件名
    static let name = InternalContainers.guardName
    /// 程序在根文件系统里的路径
    static let program = "/napbox-guard"
    /// 它接受端口转发连接的 vsock 端口（guard/relay.go）
    static let relayPort: UInt32 = 5300
    /// 它接受文件变化通知的 vsock 端口（guard/notify.go）
    static let notifyPort: UInt32 = 5301
    /// 它报告卡在内存上的服务的 vsock 端口（guard/memwatch.go）
    static let memoryPort: UInt32 = 5302
    /// confine 的环境：代码目录本身挂在它这里，虚拟机才共享它（HostShares.root）。它自己不用
    static let confinedRoot = "/napbox-confined"

    /// 环境里的源码挂载在它这边怎么放：它也挂一份，通知才发得到（同一个目录在虚拟机里是同一份文件）。
    /// 服务挂单个文件时它挂这个文件所在的目录：虚拟机只能共享目录，服务那边也是共享这个目录再绑定其中的文件
    /// （Containerization 的 FileMount），从这个目录进去碰到的才是同一份文件。
    struct Sources {
        /// 它要挂的宿主机目录（解开符号链接后的路径，FSEvents 报的也是这种），第 i 个挂在 /napbox-src/i
        var directories: [String]
        var mounts: [SourceMount]
    }

    /// 要在服务的容器配好之后算：不存在的来源那时已经建成目录（ContainerPlan）
    static func sources(_ project: ComposeProject) -> Sources {
        let paths = project.sourcePaths.map { path -> (path: String, isFile: Bool) in
            let real = realDirectory(path)
            var isDirectory: ObjCBool = false
            return (real, FileManager.default.fileExists(atPath: real, isDirectory: &isDirectory) && !isDirectory.boolValue)
        }
        let directories = Set(paths.map { $0.isFile ? ($0.path as NSString).deletingLastPathComponent : $0.path }).sorted()
        let mounts = paths.map { source in
            let directory = source.isFile ? (source.path as NSString).deletingLastPathComponent : source.path
            let root = "/napbox-src/\(directories.firstIndex(of: directory)!)"
            return SourceMount(
                hostRoot: source.path,
                guardRoot: source.isFile ? root + "/" + (source.path as NSString).lastPathComponent : root,
                isFile: source.isFile
            )
        }
        return Sources(directories: directories, mounts: mounts)
    }

    /// 挂进服务的一个单独的文件，和它挂在哪些服务的哪个路径。宿主机把它换成另一个文件以后（先写临时文件再改名），
    /// 要让这些服务重新挂上（guard/rebind.go）
    struct FileBinding: Sendable {
        struct Use: Hashable, Sendable {
            var service: String
            var target: String
            var readOnly: Bool
        }

        var hostPath: String
        var guardPath: String
        var uses: [Use]
    }

    static func fileBindings(_ project: ComposeProject, _ sources: Sources) -> [FileBinding] {
        var seen: Set<String> = []
        return sources.mounts.filter { $0.isFile && seen.insert($0.hostRoot).inserted }.map { mount in
            FileBinding(hostPath: mount.hostRoot, guardPath: mount.guardRoot, uses: project.services.flatMap { s in
                s.volumes.compactMap { v in
                    guard let path = v.source.hostPath, realDirectory(path) == mount.hostRoot else { return nil }
                    return FileBinding.Use(service: s.name, target: v.target, readOnly: v.readOnly)
                }
            })
        }
    }

    /// 查服务在监听哪些端口要看它的网络，重新挂文件要进它的挂载命名空间，都从服务的进程拿，
    /// 得看得到虚拟机里所有的进程（它自己的 /proc 里只有它自己的）：把虚拟机的 /proc 挂进来。
    /// 和 guard/serviceproc.go 里的 vmProc 是同一个路径
    static var vmProcMount: Containerization.Mount {
        .any(type: "none", source: "/proc", destination: "/napbox-vmproc", options: ["bind"])
    }

    /// 虚拟机的 cgroup，只读：看各服务的内存压力和上限（guard/memwatch.go）。它自己的 /sys/fs/cgroup 只看得到它自己
    static var vmCgroupMount: Containerization.Mount {
        .any(type: "none", source: "/sys/fs/cgroup", destination: "/napbox-vmcgroup", options: ["bind", "ro"])
    }

    /// 容器的根文件系统在虚拟机里挂在哪（Containerization 的 LinuxPod.guestRootfsPath，pod.create 时就挂好）
    static func guestRootfs(_ container: String) -> String { "/run/container/\(container)/rootfs" }
    /// 服务的根文件系统、命名卷在它里面的路径
    static func rootfsRoot(_ service: String) -> String { "/napbox-rootfs/\(service)" }
    static func volumeRoot(_ volume: String) -> String { "/napbox-volume/\(volume)" }

    /// 给新的命名卷带上镜像内容（guard/populate.go）要同时看得到两边：服务用到的命名卷，和这些服务的根文件系统，
    /// 都在它里面挂一份。根文件系统看到的是镜像本来的样子，服务自己的挂载不在里面。
    static func populateMounts(_ project: ComposeProject) -> [Containerization.Mount] {
        var services: [String] = []
        var volumes: Set<String> = []
        for s in project.services {
            let named = s.namedVolumes
            if named.isEmpty { continue }
            services.append(s.name)
            volumes.formUnion(named.map(\.volume))
        }
        return services.map { .any(type: "none", source: guestRootfs($0), destination: rootfsRoot($0), options: ["bind"]) }
            + volumes.sorted().map { .sharedMount(name: $0, destination: volumeRoot($0)) }
    }
}
