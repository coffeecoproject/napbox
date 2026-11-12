// 解析、合并、校验之后的 compose：只含第一版支持的内容，路径都已换成绝对路径，变量都已替换。
// up 时生成一份并保存下来，之后唤醒都用这一份，直到下次 up（DESIGN.md 第 8 节）。
import CryptoKit
import Foundation

public struct ComposeProject: Codable, Equatable, Sendable {
    /// 已按 profiles 筛过、按名字排好序的服务
    public var services: [Service]
    /// 顶层声明的命名卷
    public var volumes: [String]
    /// x-napbox.idle_minutes
    public var idleMinutes: Int?
    /// 用到了但没设置、也没有默认值的变量（按空字符串处理，和 compose 一样）
    public var unsetVariables: [String]
    /// 没启用的 profile 里的服务写的 ports：服务名 → 容器端口，没有这样的服务是 nil。它们也分配宿主机端口、锁着，
    /// 只是不转发、不列出，换 profile 再 up 时还是同一个端口；服务从 compose 里删掉才释放（DESIGN.md 第 5 节）。
    /// napbox run 不留
    public var reservedPorts: [String: [Int]]? = nil

    public func service(_ name: String) -> Service? { services.first { $0.name == name } }

    /// 要分配宿主机端口的：启用的服务的，加上 reservedPorts
    public var portRequests: [PortRequest] {
        let active = services.flatMap { s in s.ports.map { PortRequest(service: s.name, containerPort: $0) } }
        let reserved = (reservedPorts ?? [:]).sorted { $0.key < $1.key }.flatMap { name, ports in
            ports.map { PortRequest(service: name, containerPort: $0) }
        }
        return active + reserved
    }
}

public struct Service: Codable, Equatable, Sendable {
    public var name: String
    public var image: String?
    public var build: Build?
    public var command: [String]?
    public var entrypoint: [String]?
    /// env_file 和 environment 合并后的结果，environment 优先
    public var environment: [String: String]
    public var workingDir: String?
    public var initProcess: Bool
    public var shmSizeBytes: UInt64?
    public var tmpfs: [String]
    public var pullPolicy: PullPolicy?
    public var stopGracePeriodSeconds: Double?
    /// ports 里的容器端口（宿主机端口由 napbox 分配）
    public var ports: [Int]
    /// expose 的端口：pod 里本来互通，只用来判断端口冲突和"有端口的服务"
    public var expose: [Int]
    public var volumes: [VolumeMount]
    public var dependsOn: [Dependency]
    public var healthcheck: Healthcheck?
    public var restart: RestartPolicy
    public var memoryBytes: UInt64
    public var keepAwake: Bool
    /// develop.watch（DESIGN.md 第 8 节）
    public var watch: [WatchRule] = []

    /// 判断就绪用：写了 ports 或 expose 的算有端口（DESIGN.md 第 7 节）
    public var listeningPorts: [Int] { Array(Set(ports + expose)).sorted() }
}

public struct WatchRule: Codable, Equatable, Sendable {
    public enum Action: String, Codable, Sendable {
        case sync, rebuild, restart
        case syncRestart = "sync+restart"
        case syncExec = "sync+exec"

        public var syncs: Bool { self == .sync || self == .syncRestart || self == .syncExec }
    }

    public var action: Action
    /// 宿主机上的绝对路径
    public var path: String
    /// 容器里的绝对路径，只有同步的规则有
    public var target: String?
    public var ignore: [String]
    public var include: [String]
    public var initialSync: Bool
    /// sync+exec 的命令
    public var exec: [String]?
}

public struct Build: Codable, Equatable, Sendable {
    /// 绝对路径
    public var context: String
    /// 相对 context 的路径，没写就是 Dockerfile
    public var dockerfile: String?
    public var target: String?
    public var args: [String: String]
}

public enum PullPolicy: String, Codable, Sendable {
    case always, never, missing, build
}

public struct VolumeMount: Codable, Equatable, Sendable {
    public enum Source: Codable, Equatable, Sendable {
        /// 顶层 volumes 里声明的命名卷
        case named(String)
        /// 宿主机路径（绝对路径）
        case bind(String)
        /// secrets 的文件（绝对路径）。和 bind 一样挂，差别只在文件不存在时：报错，不建成目录
        case secret(String)

        /// 宿主机上的路径，命名卷没有
        public var hostPath: String? {
            switch self {
            case .named: nil
            case .bind(let path), .secret(let path): path
            }
        }
    }
    public var source: Source
    public var target: String
    public var readOnly: Bool
}

extension Service {
    /// 挂的命名卷，和各自挂在容器里的哪个路径
    public var namedVolumes: [(volume: String, target: String)] {
        volumes.compactMap { if case .named(let name) = $0.source { (name, $0.target) } else { nil } }
    }
}

public struct Dependency: Codable, Equatable, Sendable {
    public enum Condition: String, Codable, Sendable {
        case started = "service_started"
        case healthy = "service_healthy"
        case completedSuccessfully = "service_completed_successfully"
    }
    public var service: String
    public var condition: Condition
}

public struct Healthcheck: Codable, Equatable, Sendable {
    public enum Test: Codable, Equatable, Sendable {
        /// ["CMD", ...]：直接执行
        case exec([String])
        /// ["CMD-SHELL", "..."] 或字符串：用 /bin/sh -c 执行
        case shell(String)
    }
    public var test: Test
    public var intervalSeconds: Double
    public var timeoutSeconds: Double
    public var retries: Int
    public var startPeriodSeconds: Double
    public var startIntervalSeconds: Double
}

public enum RestartPolicy: Codable, Equatable, Sendable {
    case no
    case always
    case unlessStopped
    case onFailure(maxRetries: Int?)

    /// 这个退出码要不要重启（不看 on-failure 的次数上限）。规则和 Docker 一致（DESIGN.md 第 8 节）
    public func restarts(afterExit code: Int32) -> Bool {
        switch self {
        case .no: false
        case .always, .unlessStopped: true
        case .onFailure: code != 0
        }
    }
}

extension ComposeProject {
    /// 这样退出算不算跑完（唤醒、重启时不再启动，DESIGN.md 第 8 节）：退出码 0、不用再起，而且是一次性服务。
    /// compose 没有写明谁是一次性服务：别的服务要等它 service_completed_successfully 的算；
    /// 剩下的看它有没有端口和 healthcheck，有的是要一直提供服务的，退出码 0 也不算跑完。
    public func completes(_ service: Service, exitCode code: Int32) -> Bool {
        guard code == 0, !service.restart.restarts(afterExit: code) else { return false }
        let awaitedToComplete = services.contains { other in
            other.dependsOn.contains { $0.service == service.name && $0.condition == .completedSuccessfully }
        }
        return awaitedToComplete || (service.listeningPorts.isEmpty && service.healthcheck == nil)
    }

    /// 有服务挂了宿主机的目录或文件（命名卷不算）
    public var hasSourceMounts: Bool { !sourcePaths.isEmpty }

    /// 服务挂的宿主机路径（目录，或者单个文件，secrets 的文件也算），排好序去掉重复的
    public var sourcePaths: [String] {
        Set(services.flatMap { $0.volumes.compactMap(\.source.hostPath) }).sorted()
    }

    /// 运行记录里的定义摘要：键排好序的 JSON 的 sha256（DESIGN.md 第 9 节）
    public var digest: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        // 只有字符串、数字、数组和字典，编码不会失败
        let data = try! encoder.encode(self)
        return "sha256:" + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
