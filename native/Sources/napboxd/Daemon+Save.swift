// save：按 compose 构建、拉好镜像，导出成一个 tar。不登记环境、不起虚拟机里的服务。
import Foundation
import NapboxCore
import NapboxProtocol
import NapboxRuntime

extension Daemon {
    func save(_ params: SaveParams) async throws(NapboxError) -> SaveResult {
        let cwd = URL(fileURLWithPath: params.cwd)
        let location = try await Blocking.run { () throws(NapboxError) in try WorktreeLocation.locate(from: cwd) }
        try requireNotCallerDirectory(location.worktree.path)
        let files = try ComposeFiles.resolve(explicit: params.files, environment: params.environment, cwd: cwd, worktree: location.worktree)
        let project = try loadCompose(files, environment: params.environment, profiles: params.profiles)
        // 报回去的路径照调用方的写法（standardizedFileURL 会去掉开头的 /private）
        let output = URL(fileURLWithPath: PathText.normalized(params.output.hasPrefix("/") ? params.output : params.cwd + "/" + params.output))
        // 构建出来的镜像放在这次导出自己的名字下面，和开发环境、别的导出都不相干；这个名字不登记成环境
        let scratch = "\(store.state.environmentName(for: location))#save-\(UUID().uuidString.lowercased().prefix(8))"
        let images = try await runtime.saveImages(
            project, services: params.services, projectName: store.state.projectName(for: location.mainRepository),
            scratch: scratch, output: output, access: .open
        )
        return SaveResult(output: output.path, images: images)
    }
}
