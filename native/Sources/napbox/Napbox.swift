// napbox 命令行：只和 napboxd 通信，自身不保存状态。默认输出 JSON；出错时（包括命令写错）
// 也输出 {"error": {"code", "message"}}，退出码 1。标准输出是原样内容的命令（env、logs、exec、run，见 RawOutput）
// 把这个错误写到标准错误，不和内容混在一起。
import ArgumentParser
import Foundation
import NapboxProtocol

@main
struct Napbox: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "napbox",
        abstract: "给 agent 用的本地开发环境。",
        discussion: "npm 包里的 napbox 还有 setup [claude|codex]：准备内核、注册后台程序 napboxd，可以顺便把 MCP 服务加进 agent。",
        version: NapboxVersion.current,
        subcommands: [Up.self, Run.self, Env.self, Logs.self, Exec.self, Reset.self, Sleep.self, Egress.self, Down.self, Status.self]
    )

    /// 替换 ArgumentParser 默认的入口：它把错误按文本打印，退出码也不统一。
    static func main() {
        var command: ParsableCommand
        do {
            command = try parseAsRoot()
        } catch {
            exitIfClean(error)
            Output.fail(NapboxError(.usageError, fullMessage(for: error)))
        }
        let raw = command is RawOutput
        do {
            try command.run()
        } catch let error as NapboxError {
            Output.fail(error, toStandardError: raw)
        } catch {
            // --help 时 parseAsRoot 返回帮助命令，它在 run 里才抛出"要看帮助"
            exitIfClean(error)
            Output.fail(NapboxError(.internalError, "\(error)"), toStandardError: raw)
        }
    }

    /// --help、--version 照常输出文本，退出码 0。
    private static func exitIfClean(_ error: Error) {
        if exitCode(for: error) == .success { exit(withError: error) }
    }
}

/// 标准输出是原样内容（不是 JSON）的命令：出错时的 JSON 写到标准错误。命令写错时还没解析出是哪个命令，
/// 照常写到标准输出
protocol RawOutput {}

struct Status: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "查看 napboxd 和环境的状态。")

    @Flag(help: "输出给人看的表格，而不是 JSON。")
    var text = false

    func run() throws {
        let result = try Output.call(Method.status, as: StatusResult.self)
        guard text else { return try Output.json(result) }
        print("napboxd \(result.version)（pid \(result.pid)）运行中，启动于 \(result.startedAt.formatted(date: .numeric, time: .standard))")
        if result.environments.isEmpty {
            print("没有环境")
        }
        for env in result.environments {
            print("\n\(env.name)  \(env.state.rawValue)  \(env.worktree)")
            if let owner = env.owner { print("  持有方：\(owner)") }
            for p in env.ports { print("  \(p.service):\(p.containerPort)\t\(env.variables[p.variable] ?? "")\t\(p.variable)") }
            for p in env.hostPorts { print("  本机 \(p.name)\t\(p.hostPort)\t\(p.variable)") }
            if let error = env.lastError { print("  最近出错：\(error)") }
            if let error = env.snapshotError { print("  \(error)") }
        }
    }
}

struct Up: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "创建或唤醒当前 worktree 的环境，服务都就绪后返回端口和环境变量。")

    @Option(name: .shortAndLong, help: "compose 文件，可以写多次，按顺序合并。不写就自动查找。")
    var file: [String] = []

    @Option(name: .long, help: "启用的 profile，可以写多次。")
    var profile: [String] = []

    @Flag(help: "写了 build 的服务都重新构建。不加时只在镜像还没有时构建；改了 Dockerfile 或打进镜像的文件后要加。")
    var build = false

    @Option(name: .long, help: "起一个叫这个名字的临时环境，和开发环境互不影响（给测试用，可以同时起好几个）。用完 napbox down --temp <名字>，数据直接删掉；它不休眠，闲置了自己销毁。")
    var temp: String?

    func run() throws {
        let params = UpParams(
            cwd: FileManager.default.currentDirectoryPath, files: file, profiles: profile,
            environment: ProcessInfo.processInfo.environment, build: build, temp: temp
        )
        try Output.json(try Output.call(Method.up, params: try Wire.value(params), as: EnvironmentInfo.self))
    }
}

struct Run: ParsableCommand, RawOutput {
    static let configuration = CommandConfiguration(
        abstract: "临时起一个环境，在前台跑 compose 里的一个服务，跑完整个销毁：napbox run <服务> [-- <命令>]。它依赖的服务先起好；输出原样转回，标准输入不是终端时转给它（可以 < 文件），退出码和它一样。和开发环境互不影响，数据不保留。不支持交互终端。"
    )

    @Option(name: .shortAndLong, help: "compose 文件，可以写多次，按顺序合并。不写就自动查找。")
    var file: [String] = []

    @Option(name: .long, help: "启用的 profile，可以写多次。要跑的服务自己的 profile 不用写。")
    var profile: [String] = []

    @Flag(help: "写了 build 的服务都重新构建。")
    var build = false

    @Flag(name: .customLong("no-deps"), help: "不起它 depends_on 的服务。")
    var noDeps = false

    @Option(help: "出网模式：open（默认）能上外网，none 只能访问同一环境里的服务。")
    var egress: EgressMode?

    @Argument(help: "服务名")
    var service: String

    @Argument(parsing: .postTerminator, help: "-- 之后的命令和参数，换掉服务的 command；不写就用 compose 里写的")
    var command: [String] = []

    func run() throws {
        let params = RunParams(
            cwd: FileManager.default.currentDirectoryPath, files: file, profiles: profile,
            environment: ProcessInfo.processInfo.environment, build: build, egress: egress, service: service,
            command: command, noDeps: noDeps
        )
        let response = try SocketClient.stream(Request(id: 1, method: Method.run, params: try Wire.value(params)), forwardStdin: true) {
            Output.raw($0)
        }
        if let error = response.error { throw error }
        guard let result = response.result, let exec = try? Wire.decode(ExecResult.self, from: result) else {
            throw NapboxError(.protocolError, "看不懂 napboxd 对 run 的回应")
        }
        Foundation.exit(exec.exitCode)
    }
}

/// 按当前目录找环境的命令共用
struct TargetOptions: ParsableArguments {
    @Option(name: .long, help: "操作这个 worktree 里叫这个名字的临时环境（napbox up --temp 起的）。不写是开发环境。")
    var temp: String?

    var target: EnvironmentTarget { .directory(FileManager.default.currentDirectoryPath, temporary: temp) }
}

struct Env: ParsableCommand, RawOutput {
    static let configuration = CommandConfiguration(abstract: "输出当前 worktree 环境的端口变量（export NAPBOX_API_3100=127.0.0.1:41217），可以直接 eval \"$(napbox env)\"。不唤醒环境；出错时的 JSON 写到标准错误。")

    @OptionGroup var options: TargetOptions

    func run() throws {
        let params = EnvironmentParams(target: options.target)
        let info = try Output.call(Method.environment, params: try Wire.value(params), as: EnvironmentInfo.self)
        // 值只有 127.0.0.1:端口 或端口号，变量名只有大写字母、数字和下划线，不用转义
        for (name, value) in info.variables.sorted(by: { $0.key < $1.key }) { print("export \(name)=\(value)") }
    }
}

struct Logs: ParsableCommand, RawOutput {
    static let configuration = CommandConfiguration(abstract: "输出服务的日志（每次启动前有一行 ----- napbox 启动 … -----）。不唤醒环境；-f 跟着期间环境不闲置休眠。")

    @Argument(help: "服务名")
    var service: String

    @Option(help: "最后几行，或者 all。")
    var tail: String = "200"

    @Flag(name: .shortAndLong, help: "输出完以后继续跟着新日志，直到按 Ctrl-C 或环境回收。")
    var follow = false

    @OptionGroup var options: TargetOptions

    func run() throws {
        let lines: Int?
        if tail == "all" { lines = nil } else if let n = Int(tail), n >= 0 { lines = n } else {
            throw NapboxError(.usageError, "--tail 要写非负整数或 all，收到 \(tail)")
        }
        let params = LogsParams(target: options.target, service: service, tail: lines, follow: follow)
        let response = try SocketClient.stream(Request(id: 1, method: Method.logs, params: try Wire.value(params)), forwardStdin: false) {
            Output.raw($0)
        }
        if let error = response.error { throw error }
        guard let result = response.result, let logs = try? Wire.decode(LogsResult.self, from: result) else {
            throw NapboxError(.protocolError, "看不懂 napboxd 对 logs 的回应")
        }
        // 跟着的时候 napboxd 那边结束了（比如环境回收了）：说明一下，和日志内容分开
        if let ended = logs.ended { FileHandle.standardError.write(Data("napbox logs 结束：\(ended)\n".utf8)) }
    }
}

struct Exec: ParsableCommand, RawOutput {
    static let configuration = CommandConfiguration(
        abstract: "在服务的容器里执行命令：napbox exec <服务> -- <命令>。输出原样转回，标准输入不是终端时转给命令（可以 < 文件），退出码和命令一样。环境在休眠时先唤醒。不支持交互终端。"
    )

    @Argument(help: "服务名")
    var service: String

    @Argument(parsing: .postTerminator, help: "-- 之后的命令和参数")
    var command: [String] = []

    @OptionGroup var options: TargetOptions

    func run() throws {
        guard !command.isEmpty else { throw NapboxError(.usageError, "要给出命令：napbox exec <服务> -- <命令>") }
        let params = ExecParams(target: options.target, service: service, command: command)
        let response = try SocketClient.stream(Request(id: 1, method: Method.exec, params: try Wire.value(params)), forwardStdin: true) {
            Output.raw($0)
        }
        if let error = response.error { throw error }
        guard let result = response.result, let exec = try? Wire.decode(ExecResult.self, from: result) else {
            throw NapboxError(.protocolError, "看不懂 napboxd 对 exec 的回应")
        }
        Foundation.exit(exec.exitCode)
    }
}

struct Reset: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "换掉数据卷：停掉环境，旧卷保留 7 天，换成空的（或者 --from 那个 worktree 的环境最新快照里的那份），再像 up 一样起来（一次性服务重新跑，迁移在新数据上跑），返回和 up 一样的结果。")

    @Argument(help: "数据卷名（compose 里 volumes 下的名字），可以给几个")
    var volumes: [String]

    @Option(help: "从这个目录所在 worktree 的开发环境最新的快照复制（同一个项目，比如主目录的路径）。快照要那边的 compose 声明了 x-napbox.seed，环境正常停下时才拍；源环境不用停")
    var from: String?

    func run() throws {
        let source = from.map { URL(fileURLWithPath: $0, relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)).standardizedFileURL.path }
        let params = ResetParams(target: .currentDirectory, volumes: volumes, from: source)
        try Output.json(try Output.call(Method.reset, params: try Wire.value(params), as: EnvironmentInfo.self))
    }
}

struct Sleep: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "让当前 worktree 的环境马上休眠：停掉虚拟机、断开连接，端口和数据保留，有连接进来会自动唤醒。")

    func run() throws {
        let params = EnvironmentParams(target: .currentDirectory)
        try Output.json(try Output.call(Method.sleep, params: try Wire.value(params), as: EnvironmentInfo.self))
    }
}

extension EgressMode: ExpressibleByArgument {}

struct Egress: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "切换当前 worktree 环境的出网模式：open 能上外网，none 只能访问同一环境里的服务；两种都访问不到宿主机和局域网。在运行的马上生效，休眠的下次唤醒生效。")

    @Argument(help: "open 或 none")
    var mode: EgressMode

    @OptionGroup var options: TargetOptions

    func run() throws {
        let params = EgressParams(target: options.target, mode: mode)
        try Output.json(try Output.call(Method.egress, params: try Wire.value(params), as: EnvironmentInfo.self))
    }
}

struct Down: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "回收当前 worktree 的环境：停掉服务、释放端口，数据卷保留 7 天。加 --temp 是销毁临时环境，它的数据直接删掉。")

    @OptionGroup var options: TargetOptions

    func run() throws {
        let params = DownParams(target: options.target)
        try Output.json(try Output.call(Method.down, params: try Wire.value(params), as: DownResult.self))
    }
}

extension EnvironmentTarget {
    /// 命令行都按当前目录找环境。reset、sleep 只对开发环境（临时环境没有这两样）
    static var currentDirectory: EnvironmentTarget { .directory(FileManager.default.currentDirectoryPath) }
}

enum Output {
    /// 发请求，返回 result；napboxd 回了 error 时原样抛出。
    static func call<T: Decodable>(_ method: String, params: JSONValue? = nil, as type: T.Type) throws -> T {
        let response = try SocketClient.call(Request(id: 1, method: method, params: params))
        if let error = response.error { throw error }
        guard let result = response.result else {
            throw NapboxError(.protocolError, "napboxd 的回应既没有 result 也没有 error")
        }
        do {
            return try Wire.decode(type, from: result)
        } catch {
            throw NapboxError(.protocolError, "看不懂 napboxd 对 \(method) 的回应（\(error)）。napbox 是 \(NapboxVersion.current)，可能和正在运行的 napboxd 版本不一致，用 napbox status 查看它的版本。")
        }
    }

    /// logs、exec 的输出：原样写到标准输出或标准错误
    static func raw(_ output: StreamOutput) {
        (output.stream == .stdout ? FileHandle.standardOutput : FileHandle.standardError).write(output.data)
    }

    static func json<T: Encodable>(_ value: T) throws {
        print(String(decoding: try Wire.encoder.encode(value), as: UTF8.self))
    }

    static func fail(_ error: NapboxError, toStandardError: Bool = false) -> Never {
        struct Failure: Encodable { var error: NapboxError }
        // 只有两个字符串，编码不会失败
        var line = try! Wire.encoder.encode(Failure(error: error))
        line.append(0x0A)
        (toStandardError ? FileHandle.standardError : FileHandle.standardOutput).write(line)
        Foundation.exit(1)
    }
}
