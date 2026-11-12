// 从本机 Docker 导入镜像（napbox image import）：给 Docker Hub 上已经拉不到、只有本机 Docker 里有的镜像用。
// 只执行 docker save（只读 Docker 的数据，不碰它的容器），导出的 OCI 布局导入到 napbox 自己的镜像库。
import Containerization
import Foundation
import NapboxCore
import NapboxProtocol

extension Runtime {
    /// 返回导入后的完整镜像名和 linux/arm64 的 manifest digest。
    public func importFromDocker(_ reference: String) async throws(NapboxError) -> (reference: String, digest: String) {
        let (store, _) = try await prepare()
        let normalized = try Images.normalize(reference)
        guard let docker = DockerCLI.find() else {
            throw NapboxError(.imageUnavailable, "找不到 docker 命令（找过 \(DockerCLI.candidates.joined(separator: "、"))），没法从 Docker 导入")
        }
        let work = supportDirectory.appending(path: "runtime/import-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: work) } // napbox 自己的临时目录
        let tar = work.appending(path: "image.tar"), layout = work.appending(path: "layout")
        do {
            try FileManager.default.createDirectory(at: layout, withIntermediateDirectories: true)
        } catch {
            throw NapboxError(.internalError, "建不了临时目录 \(work.path)：\(error.localizedDescription)")
        }
        // 大镜像要几分钟：不占着 Runtime，期间别的环境照样能起
        try await Blocking.run { () throws(NapboxError) in
            try DockerCLI.run(docker, ["save", reference, "-o", tar.path], what: "docker save \(reference)")
            try DockerCLI.run("/usr/bin/tar", ["-xf", tar.path, "-C", layout.path], what: "解开 docker save 的输出")
        }

        do {
            let loaded = try await store.load(from: layout)
            var image = loaded.first { $0.reference == normalized }
            if image == nil, let only = loaded.first, loaded.count == 1 {
                image = try await store.tag(existing: only.reference, new: normalized)
            }
            guard let image else {
                throw NapboxError(.imageUnavailable, "导入后没找到 \(normalized)，导入的是：\(loaded.map(\.reference).joined(separator: "、"))")
            }
            // 确认里面有 linux/arm64 的内容（docker save 只导出本机有的平台）
            _ = try await image.config(for: linuxArm64)
            return (normalized, try await image.descriptor(for: linuxArm64).digest)
        } catch let error as NapboxError {
            throw error
        } catch {
            throw NapboxError(.imageUnavailable, "导入 \(normalized) 失败：\(error)")
        }
    }
}

enum DockerCLI {
    /// napboxd 作为登录项运行时 PATH 很短，按常见位置找
    static let candidates = ["/usr/local/bin/docker", "/opt/homebrew/bin/docker", "/Applications/Docker.app/Contents/Resources/bin/docker"]

    static func find() -> String? { candidates.first { FileManager.default.isExecutableFile(atPath: $0) } }

    static func run(_ executable: String, _ arguments: [String], what: String) throws(NapboxError) {
        let output: Subprocess.Output
        do { output = try Subprocess.run(executable, arguments, captureStdout: false) } catch {
            throw NapboxError(.imageUnavailable, "\(what) 运行失败：\(error.localizedDescription)")
        }
        guard output.status == 0 else { throw NapboxError(.imageUnavailable, "\(what) 失败：\(output.stderrText)") }
    }
}
