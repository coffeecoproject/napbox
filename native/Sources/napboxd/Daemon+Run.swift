// napbox run：起一个临时环境，在前台跑其中一个服务，跑完销毁。流式收发在 Streams.swift。
import Foundation
import NIOCore
import NapboxCore
import NapboxProtocol
import NapboxRuntime

extension Daemon {
    /// 返回前台那个服务的退出码。临时环境的名字是 napbox 自己起的，同一个 worktree 里可以同时跑好几个；
    /// 不管怎么结束（跑完、起不来、命令行断开），环境都销毁。
    /// - stdin：服务的标准输入
    /// - output：服务的输出。出错返回时不再往里写；不关它，由调用方关
    func run(_ params: RunParams, stdin: AsyncStream<Data>, output: ExecOutput) async throws(NapboxError) -> Int32 {
        let cwd = URL(fileURLWithPath: params.cwd)
        let location = try await Blocking.run { () throws(NapboxError) in try WorktreeLocation.locate(from: cwd) }
        try requireNotCallerDirectory(location.worktree.path)
        let files = try ComposeFiles.resolve(explicit: params.files, cwd: cwd, worktree: location.worktree)
        let project = try loadCompose(
            files, environment: params.environment, profiles: params.profiles,
            run: ComposeRun(service: params.service, command: params.command, noDeps: params.noDeps)
        )
        let foreground = ForegroundService(service: params.service, stdin: stdin, output: output)
        // 起不来时 launch 已经把它销毁了
        let name = try await startInWorktree(
            location, temporary: TemporaryEnvironment.generatedName(), project: project, egress: params.egress,
            rebuild: params.build, foreground: foreground
        ).name

        // 跑的期间占住环境：没有连接往来也不算闲置
        activity.hold(name)
        let result: Result<Int32, NapboxError>
        do throws(NapboxError) {
            guard let env = running[name] else { throw NapboxError(.serviceFailed, "临时环境 \(name) 刚起来就停了") }
            result = .success(try await env.foregroundExit(params.service, output: output))
        } catch {
            output.close() // 被堵住的写入方要放开，服务才停得了
            result = .failure(error)
        }
        activity.release(name)
        // 排队里的操作不随调用方取消：命令行断开了也销毁得完
        try? await serialized(name) { () throws(NapboxError) in await self.destroyTemporary(name, reason: "napbox run 结束") }
        return try result.get()
    }
}
