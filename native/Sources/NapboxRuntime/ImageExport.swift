// 导出镜像（napbox save）：把 compose 里服务的镜像写成一个 tar，内容是 OCI 镜像布局，docker image load 能读。
// 给项目的发版脚本用：在本机构建要发到服务器的镜像（服务器是 x86 的就在服务上写 platform: linux/amd64），
// 上传、部署是项目自己的事。
import Containerization
import ContainerizationArchive
import Foundation
import NapboxCore
import NapboxProtocol

extension Runtime {
    /// - services：只导出这几个服务的；空是全部
    /// - projectName：没写 image 的服务，包里的镜像叫 <项目名>-<服务名>:latest（和 docker compose build 一样）
    /// - scratch：这次导出专用的名字，构建出来的镜像都放在它下面（和环境名一个用法），导出完就删
    public func saveImages(_ project: ComposeProject, services names: [String], projectName: String, scratch: String,
                           output: URL, access: HostAccess) async throws(NapboxError) -> [SavedImage] {
        let selected = try Self.select(names, in: project)
        // 只构建要导出的：留下选中的服务，加上替它们构建镜像的服务（image 相同、写了 build 的那个）
        var needed = project
        let owners = Set(selected.compactMap { Images.buildOwner(of: $0, in: project)?.name })
        needed.services = project.services.filter { s in selected.contains { $0.name == s.name } || owners.contains(s.name) }

        let id = EnvironmentRecord.id(of: scratch)
        let layout = FileManager.default.temporaryDirectory.appending(path: "napbox-save-\(id)-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: layout) }
        do throws(NapboxError) {
            _ = try await buildImages(needed, environment: scratch, force: false, access: access)
            let (store, _) = try await prepare()
            var exports: [Export] = []
            for s in selected {
                let image = if Images.build(of: s, in: needed) == nil {
                    try await Images.resolve(s, store: store)
                } else {
                    try await Images.forStart(s, project: needed, environment: id, store: store)
                }
                let name = try Images.normalize(s.image ?? "\(projectName)-\(s.name):latest")
                if let other = exports.first(where: { $0.name == name && ($0.reference != image.reference || $0.platform != s.imagePlatform) }) {
                    throw NapboxError(.composeInvalid, "\(other.service) 和 \(s.name) 的镜像在包里都叫 \(name)，内容却不一样：给它们写不同的 image")
                }
                exports.append(Export(service: s.name, name: name, reference: image.reference, platform: s.imagePlatform))
            }
            let saved = try await Self.write(exports, store: store, layout: layout, output: output)
            try? await removeBuiltImages(environment: scratch)
            return saved
        } catch {
            // 构建失败时日志留着：报错里写了它在哪
            try? await removeBuiltImages(environment: scratch, keepLogs: true)
            throw error
        }
    }

    private struct Export: Sendable {
        var service: String
        /// 包里的名字
        var name: String
        /// 镜像库里的名字
        var reference: String
        var platform: ImagePlatform
    }

    private static func select(_ names: [String], in project: ComposeProject) throws(NapboxError) -> [Service] {
        guard !names.isEmpty else {
            guard !project.services.isEmpty else { throw NapboxError(.composeInvalid, "compose 里没有服务，没有镜像可以导出") }
            return project.services
        }
        var selected: [Service] = []
        for name in names where !selected.contains(where: { $0.name == name }) {
            guard let service = project.service(name) else {
                throw NapboxError(.composeInvalid, "compose 里没有服务 \(name)（写了 profiles 的服务要用 --profile 启用）")
            }
            selected.append(service)
        }
        return selected
    }

    /// 镜像库一次只能按一个架构导出，名字也是镜像库里的名字：按架构各导一次到同一个目录（层按 digest 存，重复的只有一份），
    /// 最外层的 index.json 自己写，名字换成包里要的。名字只记在 index.json 的注解里，换名字不改镜像的 digest。
    private static func write(_ exports: [Export], store: ImageStore, layout: URL,
                              output: URL) async throws(NapboxError) -> [SavedImage] {
        var entries: [[String: Any]] = []
        var saved: [SavedImage] = []
        do {
            for platform in [ImagePlatform.arm64, .amd64] {
                let group = exports.filter { $0.platform == platform }
                guard !group.isEmpty else { continue }
                var references: [String] = []
                for e in group where !references.contains(e.reference) { references.append(e.reference) }
                try await store.save(references: references, out: layout, platform: platform.oci)
                let index = try JSONSerialization.jsonObject(with: Data(contentsOf: layout.appending(path: "index.json"))) as? [String: Any]
                let manifests = index?["manifests"] as? [[String: Any]] ?? []
                for e in group {
                    guard var entry = manifests.first(where: { Self.reference(of: $0) == e.reference }), let digest = entry["digest"] as? String else {
                        throw NapboxError(.internalError, "导出的内容里没有 \(e.reference)")
                    }
                    saved.append(SavedImage(service: e.service, image: e.name, digest: digest, platform: platform.rawValue))
                    // 两个服务用同一个镜像、同一个名字时，包里只记一条
                    if entries.contains(where: { Self.reference(of: $0) == e.name && $0["digest"] as? String == digest }) { continue }
                    entry["annotations"] = Dictionary(uniqueKeysWithValues: Self.nameAnnotations.map { ($0, e.name) })
                    entries.append(entry)
                }
            }
            let index: [String: Any] = ["schemaVersion": 2, "mediaType": "application/vnd.oci.image.index.v1+json", "manifests": entries]
            try JSONSerialization.data(withJSONObject: index, options: [.sortedKeys]).write(to: layout.appending(path: "index.json"))
        } catch let error as NapboxError {
            throw error
        } catch {
            throw NapboxError(.internalError, "导出镜像失败：\(error)")
        }
        // 先写到旁边的临时文件再改名：写到一半出错不会留下半个包，也不会把原来的弄坏
        let partial = output.deletingLastPathComponent().appending(path: ".\(output.lastPathComponent).\(UUID().uuidString.prefix(8)).partial")
        try await Blocking.run { () throws(NapboxError) in
            do {
                let writer = try ArchiveWriter(configuration: ArchiveWriterConfiguration(format: .pax, filter: .none))
                try writer.open(file: partial)
                try writer.archiveDirectory(layout)
                try writer.finishEncoding()
                // rename 会把已有的文件一次换掉
                guard rename(partial.path, output.path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            } catch {
                try? FileManager.default.removeItem(at: partial)
                throw NapboxError(.internalError, "写不了 \(output.path)：\(error)")
            }
        }
        return saved
    }

    /// 镜像库导出时在这三个注解里写镜像名，docker 和 containerd 各认其中一个
    private static let nameAnnotations = ["org.opencontainers.image.ref.name", "io.containerd.image.name", "com.apple.containerization.image.name"]

    private static func reference(of entry: [String: Any]) -> String? {
        (entry["annotations"] as? [String: String])?["com.apple.containerization.image.name"]
    }
}
