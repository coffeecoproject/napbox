// napboxd 本地 socket 上的协议：每行一个 JSON。请求 {"id", "method", "params"}，
// 回应 {"id", "result"} 或 {"id", "error": {"code", "message"}}。命令行、MCP 和调用方（CodeOS）都走这一套。
import Foundation

public enum NapboxVersion {
    public static let current = "0.1.1"
}

public enum Paths {
    /// 所有状态都放在这里。设了 NAPBOX_SUPPORT_DIR 时改用它，
    /// 测试用它起一份独立的 napboxd，不碰正在用的那份。
    public static var supportDirectory: URL {
        if let dir = ProcessInfo.processInfo.environment["NAPBOX_SUPPORT_DIR"], !dir.isEmpty {
            return URL(fileURLWithPath: dir, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support/napbox", directoryHint: .isDirectory)
    }
    public static var socket: URL { supportDirectory.appending(path: "napboxd.sock") }
    /// napboxd 运行期间一直锁着这个文件，保证只有一份在运行。
    public static var lock: URL { supportDirectory.appending(path: "napboxd.lock") }
}

public struct Request: Codable, Sendable {
    public var id: Int
    public var method: String
    public var params: JSONValue?

    public init(id: Int, method: String, params: JSONValue? = nil) {
        self.id = id
        self.method = method
        self.params = params
    }
}

public struct Response: Codable, Sendable {
    public var id: Int
    public var result: JSONValue?
    public var error: NapboxError?
    /// 流式方法（logs、exec）在最后的 result 或 error 之前，一条一条发的输出
    public var output: StreamOutput?
    /// subscribe 的第一条：订阅生效了，从这以后的事件都会推过来。调用方收到它以后再查 status、runs，中间不会漏
    public var subscribed: Bool?
    /// subscribe 推送的事件
    public var event: EnvironmentEvent?

    public init(id: Int, output: StreamOutput) {
        self.id = id
        self.output = output
    }

    public init(id: Int, event: EnvironmentEvent) {
        self.id = id
        self.event = event
    }

    public init(id: Int, subscribed: Bool) {
        self.id = id
        self.subscribed = subscribed
    }

    public init(id: Int, result: JSONValue) {
        self.id = id
        self.result = result
    }

    public init(id: Int, error: NapboxError) {
        self.id = id
        self.error = error
    }
}

/// 出错时给 agent 的明确原因：code 固定、可以据此判断，message 说明原因和该怎么做。
public struct NapboxError: Codable, Sendable, Error {
    public var code: String
    public var message: String

    public init(_ code: ErrorCode, _ message: String) {
        self.code = code.rawValue
        self.message = message
    }
}

public enum ErrorCode: String, Sendable {
    case daemonUnavailable = "daemon_unavailable"
    case badRequest = "bad_request"
    case unknownMethod = "unknown_method"
    case protocolError = "protocol_error"
    case usageError = "usage_error"
    case internalError = "internal_error"
    case composeNotFound = "compose_not_found"
    case composeInvalid = "compose_invalid"
    case composeUnsupported = "compose_unsupported"
    case notInRepository = "not_in_repository"
    case portUnavailable = "port_unavailable"
    case stateCorrupted = "state_corrupted"
    case environmentNotFound = "environment_not_found"
    case runtimeUnavailable = "runtime_unavailable"
    case imageUnavailable = "image_unavailable"
    case imageBuildFailed = "image_build_failed"
    case serviceFailed = "service_failed"
    case serviceNotFound = "service_not_found"
    case volumeNotFound = "volume_not_found"
    case healthcheckTimeout = "healthcheck_timeout"
    case addressUnavailable = "address_unavailable"
    /// 调用方创建的环境名已经被别的持有方或别的目录用了
    case nameTaken = "name_taken"
    /// 环境不归这个持有方：按名字操作时持有方对不上，或者在调用方持有的环境的目录里用命令行
    case ownerMismatch = "owner_mismatch"
}

public enum Method {
    public static let status = "status"
    public static let up = "up"
    public static let down = "down"
    public static let sleep = "sleep"
    public static let egress = "egress"
    /// 当前 worktree 的环境信息（不唤醒），napbox env 用
    public static let environment = "environment"
    public static let logs = "logs"
    public static let exec = "exec"
    /// 订阅事件：之后一条一条推 event，直到断开
    public static let subscribe = "subscribe"
    /// 起一个临时环境，在前台跑其中一个服务，跑完销毁
    public static let run = "run"
    /// 这些方法一个连接只发一个请求：先回若干条 output（subscribe 是 event），最后一条是 result 或 error。
    /// exec、run 期间命令行还会在同一个连接上发 StdinMessage
    public static let streaming: Set<String> = [logs, exec, run, subscribe]
    public static let reset = "reset"
    /// 调用方创建环境：同名、同持有方、同目录再调用就和 up 一样
    public static let create = "create"
    /// 唤醒环境，服务都就绪后返回
    public static let wake = "wake"
    /// 环境的运行记录
    public static let runs = "runs"
}

// MARK: - status

public struct StatusResult: Codable, Sendable {
    public var version: String
    public var pid: Int32
    public var startedAt: Date
    public var environments: [EnvironmentInfo]

    public init(version: String, pid: Int32, startedAt: Date, environments: [EnvironmentInfo]) {
        self.version = version
        self.pid = pid
        self.startedAt = startedAt
        self.environments = environments
    }
}

public enum EnvironmentState: String, Codable, Sendable {
    case running
    /// 虚拟机停着（闲置休眠、napboxd 重启过，或者上次 up 失败），端口登记和数据都还在
    case sleeping
}

/// 出网模式。两种都访问不到宿主机和局域网，环境之间也互相访问不到。
public enum EgressMode: String, Codable, Sendable, CaseIterable {
    /// 默认：能上外网
    case open
    /// 只能访问同一环境里的服务，DNS 也不通
    case none
}

/// up 的结果，也是 status 里每个环境的样子。
public struct EnvironmentInfo: Codable, Sendable {
    /// worktree 持有的是 `项目/worktree`（临时环境是 `项目/worktree/临时名`），调用方持有的是调用方给的名字
    public var name: String
    /// 调用方持有时是持有方标识，worktree 持有时是 nil
    public var owner: String?
    public var state: EnvironmentState
    /// 代码所在目录
    public var worktree: String
    public var ports: [PortInfo]
    public var egress: EgressMode
    /// 可以直接 export 的变量：`NAPBOX_API_3100` → `127.0.0.1:41217`
    public var variables: [String: String]
    /// compose 里用到了但没设置、也没默认值的变量（按空字符串处理）
    public var unsetVariables: [String]
    /// 最近一次起环境失败的原因，比如「唤醒失败：……」（up、唤醒、reset、按 restart 重启都算；之后 10 秒内连接进来不再自动唤醒）
    public var lastError: String?
    /// 运行中退出过的服务（最近 10 条，napboxd 重启后清空），以及按 restart 怎么处理的
    public var serviceExits: [ServiceExit]
    /// develop.watch 最近一次同步或重建失败的原因（这时跑的可能还是旧代码），下次成功后清掉
    public var watchError: String?

    public init(name: String, owner: String?, state: EnvironmentState, worktree: String, ports: [PortInfo], egress: EgressMode,
                variables: [String: String], unsetVariables: [String], lastError: String? = nil, serviceExits: [ServiceExit] = [], watchError: String? = nil) {
        self.name = name
        self.owner = owner
        self.state = state
        self.worktree = worktree
        self.ports = ports
        self.egress = egress
        self.variables = variables
        self.unsetVariables = unsetVariables
        self.lastError = lastError
        self.serviceExits = serviceExits
        self.watchError = watchError
    }
}

public struct PortInfo: Codable, Sendable {
    public var service: String
    public var containerPort: Int
    /// 宿主机上 127.0.0.1 的端口
    public var hostPort: Int
    /// 对应的变量名，例如 NAPBOX_API_3100
    public var variable: String

    public init(service: String, containerPort: Int, hostPort: Int, variable: String) {
        self.service = service
        self.containerPort = containerPort
        self.hostPort = hostPort
        self.variable = variable
    }
}

// MARK: - up / down

public struct UpParams: Codable, Sendable {
    /// 命令行所在目录，用来找 worktree 和 compose
    public var cwd: String
    /// -f 指定的 compose 文件（相对 cwd），空表示自动查找
    public var files: [String]
    public var profiles: [String]
    /// 调用方的环境变量，compose 的变量替换用
    public var environment: [String: String]
    /// 写了 build 的服务都重新构建，不管镜像有没有（--build）
    public var build: Bool
    /// 起的是这个 worktree 里叫这个名字的临时环境（--temp），nil 是开发环境
    public var temp: String?

    public init(cwd: String, files: [String], profiles: [String], environment: [String: String], build: Bool, temp: String? = nil) {
        self.cwd = cwd
        self.files = files
        self.profiles = profiles
        self.environment = environment
        self.build = build
        self.temp = temp
    }
}

/// 起一个临时环境，在前台跑其中一个服务，跑完销毁；结果是 ExecResult（那个服务的退出码）
public struct RunParams: Codable, Sendable {
    public var cwd: String
    public var files: [String]
    public var profiles: [String]
    public var environment: [String: String]
    public var build: Bool
    /// 出网模式；nil 是 open
    public var egress: EgressMode?
    /// 在前台跑的服务。它写了 profiles 也照样能跑
    public var service: String
    /// 换掉服务的 command；空就用 compose 里写的
    public var command: [String]
    /// 不起它 depends_on 的服务（--no-deps）
    public var noDeps: Bool

    public init(cwd: String, files: [String], profiles: [String], environment: [String: String], build: Bool,
                egress: EgressMode?, service: String, command: [String], noDeps: Bool) {
        self.cwd = cwd
        self.files = files
        self.profiles = profiles
        self.environment = environment
        self.build = build
        self.egress = egress
        self.service = service
        self.command = command
        self.noDeps = noDeps
    }
}

/// 操作哪个环境：命令行按所在目录找 worktree 持有的环境（`{"cwd"}`，临时环境再带上它的名字 `{"cwd", "temp"}`）；
/// 调用方按环境名，持有方要对上（`{"name", "owner"}`）
public enum EnvironmentTarget: Codable, Sendable, Equatable {
    case directory(String, temporary: String? = nil)
    case named(String, owner: String)

    private enum CodingKeys: String, CodingKey { case cwd, temp, name, owner }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let cwd = try c.decodeIfPresent(String.self, forKey: .cwd)
        let temp = try c.decodeIfPresent(String.self, forKey: .temp)
        let name = try c.decodeIfPresent(String.self, forKey: .name)
        let owner = try c.decodeIfPresent(String.self, forKey: .owner)
        switch (cwd, name, owner) {
        case let (cwd?, nil, nil): self = .directory(cwd, temporary: temp)
        case let (nil, name?, owner?) where temp == nil: self = .named(name, owner: owner)
        default:
            throw DecodingError.dataCorrupted(.init(codingPath: c.codingPath, debugDescription: "target 要么写 cwd（临时环境再加 temp），要么写 name 和 owner"))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .directory(let cwd, let temporary):
            try c.encode(cwd, forKey: .cwd)
            try c.encodeIfPresent(temporary, forKey: .temp)
        case .named(let name, let owner):
            try c.encode(name, forKey: .name)
            try c.encode(owner, forKey: .owner)
        }
    }
}

/// sleep、wake、down、runs、environment 这类只要指定环境的操作
public struct EnvironmentParams: Codable, Sendable {
    public var target: EnvironmentTarget

    public init(target: EnvironmentTarget) {
        self.target = target
    }
}

/// 调用方创建环境。环境由调用方持有：napbox 不按 worktree 回收它，只有调用方能操作它。
public struct CreateParams: Codable, Sendable {
    /// 调用方给的完整环境名，`前缀/名字`，比如 codeos/goal-12-work
    public var name: String
    /// 持有方标识，比如 codeos。之后按名字操作时要带上，对不上就拒绝
    public var owner: String
    /// 代码副本的绝对路径
    public var directory: String
    /// compose 文件（相对 directory 或绝对路径），按顺序合并；空表示和 up 一样从 directory 查找
    public var files: [String]
    public var profiles: [String]
    /// compose 变量替换用的变量，调用方显式给出
    public var environment: [String: String]
    /// 出网模式；nil 时新环境是 open，已有的环境保持原样
    public var egress: EgressMode?

    public init(name: String, owner: String, directory: String, files: [String] = [], profiles: [String] = [],
                environment: [String: String] = [:], egress: EgressMode? = nil) {
        self.name = name
        self.owner = owner
        self.directory = directory
        self.files = files
        self.profiles = profiles
        self.environment = environment
        self.egress = egress
    }
}

/// 环境运行中有服务退出了（restart）
public struct ServiceExit: Codable, Sendable {
    public enum Restart: String, Codable, Sendable {
        /// restart 没写或是 no，或者 on-failure 时正常退出
        case none
        /// 整个环境重启（单个服务不能单独重启）
        case restarting
        /// on-failure:N 的次数用完了，不再重启
        case gaveUp = "gave_up"
    }

    public var service: String
    public var exitCode: Int32
    public var at: Date
    public var restart: Restart

    public init(service: String, exitCode: Int32, at: Date, restart: Restart) {
        self.service = service
        self.exitCode = exitCode
        self.at = at
        self.restart = restart
    }
}

public struct ResetParams: Codable, Sendable {
    public var target: EnvironmentTarget
    public var volume: String

    public init(target: EnvironmentTarget, volume: String) {
        self.target = target
        self.volume = volume
    }
}

public struct EgressParams: Codable, Sendable {
    public var target: EnvironmentTarget
    public var mode: EgressMode

    public init(target: EnvironmentTarget, mode: EgressMode) {
        self.target = target
        self.mode = mode
    }
}

public struct DownResult: Codable, Sendable {
    public var name: String
    public var releasedPorts: [Int]
    /// 数据卷移到这里保留 7 天。临时环境的数据直接删，是 nil
    public var keptDataAt: String?

    public init(name: String, releasedPorts: [Int], keptDataAt: String?) {
        self.name = name
        self.releasedPorts = releasedPorts
        self.keptDataAt = keptDataAt
    }
}

// MARK: - 编码

public enum Wire {
    public static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return e
    }()

    public static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    public static func value<T: Encodable>(_ v: T) throws -> JSONValue {
        try decoder.decode(JSONValue.self, from: encoder.encode(v))
    }

    public static func decode<T: Decodable>(_ type: T.Type, from v: JSONValue) throws -> T {
        try decoder.decode(type, from: encoder.encode(v))
    }
}

// MARK: - 流式输出（logs、exec）

public struct StreamOutput: Codable, Sendable {
    public enum Stream: String, Codable, Sendable {
        case stdout
        case stderr
    }

    public var stream: Stream
    /// 原样的字节（JSON 里是 base64）
    public var data: Data

    public init(stream: Stream, data: Data) {
        self.stream = stream
        self.data = data
    }
}

/// exec 期间命令行发给 napboxd 的标准输入，一行一条：data 是一段内容，end 为 true 表示输入结束
public struct StdinMessage: Codable, Sendable {
    public var data: Data?
    public var end: Bool?

    public init(data: Data? = nil, end: Bool? = nil) {
        self.data = data
        self.end = end
    }
}

public struct LogsParams: Codable, Sendable {
    public var target: EnvironmentTarget
    public var service: String
    /// 最后几行，nil 是全部
    public var tail: Int?
    /// 输出完以后继续跟着新日志，直到命令行断开或环境回收
    public var follow: Bool

    public init(target: EnvironmentTarget, service: String, tail: Int?, follow: Bool) {
        self.target = target
        self.service = service
        self.tail = tail
        self.follow = follow
    }
}

public struct LogsResult: Codable, Sendable {
    /// follow 时 napboxd 这边结束跟着的原因（环境回收了）；没跟着或命令行自己断开时是 nil
    public var ended: String?

    public init(ended: String? = nil) {
        self.ended = ended
    }
}

public struct ExecParams: Codable, Sendable {
    public var target: EnvironmentTarget
    public var service: String
    public var command: [String]

    public init(target: EnvironmentTarget, service: String, command: [String]) {
        self.target = target
        self.service = service
        self.command = command
    }
}

public struct ExecResult: Codable, Sendable {
    public var exitCode: Int32

    public init(exitCode: Int32) {
        self.exitCode = exitCode
    }
}

// MARK: - 运行记录

/// 一次起环境（up、create、唤醒、reset、按 restart 重启）的记录，成功失败都记。放在环境目录里，
/// 每个环境最多留最近 200 条，回收时随数据移到 recycled/ 保留 7 天。
public struct RunRecord: Codable, Sendable {
    public enum Purpose: String, Codable, Sendable {
        /// up 或 create
        case up
        case wake
        case reset
        /// 服务退出后按 restart 整个环境重启
        case restart
    }

    public var id: String
    public var environment: String
    public var purpose: Purpose
    public var startedAt: Date
    public var finishedAt: Date
    /// 失败的原因；成功时是 nil
    public var error: NapboxError?
    /// 这次用的定义（compose 合并、变量替换之后的结果）的 sha256。up 时固定，唤醒、重启沿用
    public var definitionDigest: String
    public var egress: EgressMode
    public var ports: [PortInfo]
    /// 每个服务用的镜像和启动、就绪的时间，按服务名排序；起到一半失败时只有已经走到的部分
    public var services: [ServiceRun]

    public init(id: String, environment: String, purpose: Purpose, startedAt: Date, finishedAt: Date, error: NapboxError?,
                definitionDigest: String, egress: EgressMode, ports: [PortInfo], services: [ServiceRun]) {
        self.id = id
        self.environment = environment
        self.purpose = purpose
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.error = error
        self.definitionDigest = definitionDigest
        self.egress = egress
        self.ports = ports
        self.services = services
    }
}

public struct ServiceRun: Codable, Sendable {
    /// 怎么判断就绪的
    public enum Readiness: String, Codable, Sendable {
        /// healthcheck 通过
        case healthcheck
        /// 端口开始监听
        case port
        /// 没有 healthcheck 和端口：进程在运行，或已经成功退出
        case process
    }

    /// 根文件系统是怎么来的
    public enum Rootfs: String, Codable, Sendable {
        /// 从镜像解包
        case unpacked
        /// 这次起环境已经给同一个镜像的别的服务解包过，克隆那一份
        case cloned
        /// 镜像和服务的定义都没变，沿用上次的，容器里写的东西还在
        case reused
    }

    public var service: String
    /// 完整的镜像名，比如 docker.io/library/postgres:17-alpine
    public var image: String
    /// 镜像的 digest（拉取时的那个，可以用 名字@digest 拉回同一个镜像）
    public var digest: String
    /// 实际用的 linux/arm64 manifest 的 digest
    public var platformDigest: String
    /// 唤醒、重启时跳过的已经跑完的一次性服务：加进了虚拟机但没启动
    public var skipped: Bool
    public var startedAt: Date?
    public var readyAt: Date?
    /// 就绪了才有
    public var readiness: Readiness?
    /// 根文件系统准备好了才有
    public var rootfs: Rootfs?

    public init(service: String, image: String, digest: String, platformDigest: String, skipped: Bool = false,
                startedAt: Date? = nil, readyAt: Date? = nil, readiness: Readiness? = nil, rootfs: Rootfs? = nil) {
        self.service = service
        self.image = image
        self.digest = digest
        self.platformDigest = platformDigest
        self.skipped = skipped
        self.startedAt = startedAt
        self.readyAt = readyAt
        self.readiness = readiness
        self.rootfs = rootfs
    }
}

public struct RunsResult: Codable, Sendable {
    /// 从旧到新
    public var runs: [RunRecord]

    public init(runs: [RunRecord]) {
        self.runs = runs
    }
}

// MARK: - 事件

/// 订阅哪些环境的事件；都不写是全部
public struct SubscribeParams: Codable, Sendable {
    /// 只要这个持有方的环境
    public var owner: String?
    /// 只要这些环境
    public var names: [String]?

    public init(owner: String? = nil, names: [String]? = nil) {
        self.owner = owner
        self.names = names
    }
}

/// 环境状态的变化，subscribe 的连接上一条一条推。断开期间的不补发：重新连上后用 status 和 runs 补齐。
public struct EnvironmentEvent: Codable, Sendable {
    public enum Kind: String, Codable, Sendable {
        /// 起好了（up、create、唤醒、reset、按 restart 重启）：purpose、runId
        case started
        /// 起环境失败了，包括启动、唤醒时 healthcheck 没通过：purpose、runId、error
        case startFailed = "start_failed"
        /// 休眠了：sleepReason
        case slept
        /// 运行中有服务退出了：service、exitCode、restart
        case serviceExited = "service_exited"
        /// 回收了（down、worktree 删掉了，或者临时环境停下来被销毁）：reason
        case destroyed
    }

    public enum SleepReason: String, Codable, Sendable {
        /// 闲置超时
        case idle
        /// 有人要求的（napbox sleep 或调用方）
        case request
        /// 宿主机地址变了，按新地址重新加出网规则失败
        case hostAddress = "host_address"
        /// napboxd 退出
        case shutdown
        /// 虚拟机意外没了（比如崩溃）：环境不再运行，数据卷还在，用到时再起
        case vmLost = "vm_lost"
    }

    public var at: Date
    public var environment: String
    /// 调用方持有时是持有方标识
    public var owner: String?
    public var type: Kind
    public var purpose: RunRecord.Purpose?
    public var runId: String?
    public var error: NapboxError?
    public var sleepReason: SleepReason?
    public var reason: String?
    public var service: String?
    public var exitCode: Int32?
    public var restart: ServiceExit.Restart?

    public init(at: Date, environment: String, owner: String?, type: Kind, purpose: RunRecord.Purpose? = nil, runId: String? = nil,
                error: NapboxError? = nil, sleepReason: SleepReason? = nil, reason: String? = nil, service: String? = nil,
                exitCode: Int32? = nil, restart: ServiceExit.Restart? = nil) {
        self.at = at
        self.environment = environment
        self.owner = owner
        self.type = type
        self.purpose = purpose
        self.runId = runId
        self.error = error
        self.sleepReason = sleepReason
        self.reason = reason
        self.service = service
        self.exitCode = exitCode
        self.restart = restart
    }
}
