// 按镜像留着解好的根文件系统（模板），放在 rootfs-templates/<napbox 版本>/ 下：环境要某个镜像的根文件系统时克隆模板
// （APFS 克隆，不占额外空间，几乎不花时间），一个镜像只在第一次用到时解一遍，别的环境、销毁后重新起的临时环境都不再解。
// 模板从不挂进虚拟机，一直是刚解出来的样子。
// 模板跟着镜像走：镜像库里没有这个镜像了（重新构建换了内容、环境回收时删了它构建的镜像、标签指到了新内容）就删。
// 按版本分目录：解出来的磁盘什么样（大小、日志、Containerization 的版本）跟着 napbox 的版本变，换了版本重新解，
// 别的版本留下的整个删掉。
import Foundation
import NapboxProtocol

actor RootfsTemplates {
    /// rootfs-templates/
    let root: URL
    /// 这个版本的模板：<平台清单的 digest，冒号换成 ->.ext4，正在解的是 .partial
    private let directory: URL
    /// 正在解的镜像。同时要同一个镜像的都等这一次
    private var unpacking: [String: Task<Void, Error>] = [:]

    init(root: URL) {
        self.root = root
        directory = root.appending(path: NapboxVersion.current)
    }

    private static func name(_ digest: String) -> String { digest.replacingOccurrences(of: ":", with: "-") }

    /// 把这个镜像的根文件系统放到 path（那里不能已经有文件）。还没有模板就先解一份。
    /// - digest：镜像在这个平台的清单的 digest
    /// - unpack：把镜像解到给它的路径
    /// - 返回这次是不是新解的（等别人解完再克隆的不算）
    func clone(_ digest: String, to path: URL, unpack: @escaping @Sendable (URL) async throws -> Void) async throws -> Bool {
        let template = directory.appending(path: Self.name(digest) + ".ext4")
        var unpacked = false
        // 等完再看一遍：等的时候模板可能被清掉（purge 拿到的镜像清单是它开始之前的）
        while !FileManager.default.fileExists(atPath: template.path) {
            if let running = unpacking[digest] {
                try await running.value
                continue
            }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            // 先解到旁边再改名：解到一半停下（napboxd 被杀）不会留下一个看着完整的模板
            let partial = directory.appending(path: Self.name(digest) + ".partial")
            try? FileManager.default.removeItem(at: partial)
            let task = Task {
                do {
                    try await unpack(partial)
                    try FileManager.default.moveItem(at: partial, to: template)
                } catch {
                    try? FileManager.default.removeItem(at: partial)
                    throw error
                }
            }
            unpacking[digest] = task
            defer { unpacking[digest] = nil }
            try await task.value
            unpacked = true
        }
        // 从看到模板在到克隆之间没有等待，purge 插不进来
        guard clonefile(template.path, path.path, 0) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        return unpacked
    }

    /// 删掉用不上的：镜像已经不在镜像库里的模板、解到一半留下的、别的版本留下的。删不掉的下次再删。
    /// - digests：镜像库里现有镜像各平台清单的 digest
    func purge(keeping digests: Set<String>) {
        let files = FileManager.default
        for version in (try? files.contentsOfDirectory(atPath: root.path)) ?? [] where version != NapboxVersion.current {
            try? files.removeItem(at: root.appending(path: version))
        }
        let kept = Set(digests.map { Self.name($0) + ".ext4" }).union(unpacking.keys.map { Self.name($0) + ".partial" })
        for file in (try? files.contentsOfDirectory(atPath: directory.path)) ?? [] where !kept.contains(file) {
            try? files.removeItem(at: directory.appending(path: file))
        }
    }
}
