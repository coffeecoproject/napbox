// 镜像声明的 VOLUME（Dockerfile 的 VOLUME 指令）：compose 没在那个路径挂卷、绑定目录或 tmpfs 的，和 Docker 一样给它一块
// 匿名卷，数据不写进根文件系统。匿名卷当成 napbox 起名的命名卷处理：挂法、空卷带上镜像里的内容、放在环境目录下、
// down 时跟着环境一起回收，都和命名卷一样。
// 跟着服务走，和 docker compose 一样：休眠唤醒、根文件系统重建（compose 重建容器时默认沿用旧容器的匿名卷，-V 才换新）都沿用；
// 镜像不再声明这个路径、服务删了，就不再用，起环境时删掉（Runtime.start）。不进 seed，也不能单独 reset。
import CryptoKit
import Foundation

extension ComposeProject {
    /// 匿名卷的名字都以它开头。compose 的卷名要以字母或数字开头，不会和它们重名
    public static let anonymousVolumePrefix = "_anon_"

    /// 一个服务的一个路径对应一块匿名卷：同一个服务、同一个路径，每次起环境都是同一块
    public static func anonymousVolumeName(service: String, path: String) -> String {
        let digest = SHA256.hash(data: Data(normalizedMountPath(path).utf8)).prefix(6).map { String(format: "%02x", $0) }.joined()
        return "\(anonymousVolumePrefix)\(service)_\(digest)"
    }

    /// 给镜像声明了 VOLUME、compose 又没在那个路径挂东西的服务加上匿名卷。只看路径完全相同的：
    /// 挂在上一级目录的不算（Docker 也照样在下面再挂一块匿名卷）。
    /// - declared：每个服务的镜像声明的 VOLUME 路径
    public func withImageVolumes(_ declared: [String: [String]]) -> ComposeProject {
        var project = self
        for index in project.services.indices {
            let service = project.services[index]
            let mounted = Set(service.volumes.map { Self.normalizedMountPath($0.target) }
                + service.tmpfs.map { Self.normalizedMountPath(String($0.prefix { $0 != ":" })) })
            let paths = Set((declared[service.name] ?? []).map(Self.normalizedMountPath)).subtracting(mounted).sorted()
            for path in paths {
                let name = Self.anonymousVolumeName(service: service.name, path: path)
                project.services[index].volumes.append(VolumeMount(source: .named(name), target: path, readOnly: false))
                project.volumes.append(name)
            }
        }
        return project
    }

    /// 去掉末尾的 /（根目录除外），VOLUME /data/ 和挂在 /data 的是同一个路径
    static func normalizedMountPath(_ path: String) -> String {
        var path = path
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        return path
    }
}
