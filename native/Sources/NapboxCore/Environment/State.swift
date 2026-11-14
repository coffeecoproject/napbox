// napboxd 的持久状态：有哪些环境、各自的端口登记。只有 napboxd 读写（单实例由锁文件保证）。
import Foundation
import NapboxProtocol

public struct NapboxState: Codable, Equatable, Sendable {
    /// 状态文件格式的版本。格式变了（登记或 compose 模型加了必须有的字段、改了字段）就加 1：napboxd 只认当前版本，
    /// 对不上时报错说明，不去猜旧格式。加可以不写的字段不加 1：旧文件里没有，读出来就是没有
    static let currentVersion = 1
    public var version = currentVersion
    public var environments: [EnvironmentRecord] = []
    /// 上次新分配出去的宿主机端口，下次从它后面接着找（PortAllocator.assign、recordAllocation）。还没分配过时没有
    public var lastAssignedPort: Int?

    public init() {}

    public func environment(_ name: String) -> EnvironmentRecord? { environments.first { $0.name == name } }

    /// 这个名字现在归谁：叫这个名字的环境；没有的话，是挂在它下面的临时环境——那个 worktree 还没起开发环境，
    /// 开发环境的名字也给它留着（它的临时环境已经叫 `名字/临时名` 了）。没人占是 nil
    public func holder(of name: String) -> EnvironmentRecord? {
        environment(name) ?? environments.first { $0.name.hasPrefix(name + "/") }
    }

    /// worktree 持有的环境名：`项目/worktree`，主工作区是 `项目/main`；临时环境在后面再加一段 `/临时名`。
    /// 同一个 worktree 一直用同一个名字；项目名取主仓库目录名的小写，和别的仓库撞名时加 -2、-3。
    public func environmentName(for location: WorktreeLocation, temporary: String? = nil) -> String {
        let base = baseName(for: location)
        return temporary.map { "\(base)/\($0)" } ?? base
    }

    /// 这个 worktree 的开发环境叫什么。它登记过环境（开发环境或临时环境）就沿用那个名字
    private func baseName(for location: WorktreeLocation) -> String {
        if let existing = environments.first(where: { $0.owner == .worktree && $0.worktree == location.worktree.path }) {
            guard let temporary = existing.temporary else { return existing.name }
            return String(existing.name.dropLast(temporary.count + 1))
        }
        let project = projectName(for: location.mainRepository)
        let worktree = location.isMain ? "main" : location.worktree.lastPathComponent.lowercased()
        return Self.unique("\(project)/\(worktree)") { holder(of: $0) != nil }
    }

    /// worktree 里的环境：temporary 是 nil 找开发环境，否则找叫这个名字的临时环境
    public func environment(worktree: String, temporary: String?) -> EnvironmentRecord? {
        environments.first { $0.owner == .worktree && $0.worktree == worktree && $0.temporary == temporary }
    }

    public func projectName(for mainRepository: URL) -> String {
        if let existing = environments.first(where: { $0.mainRepository == mainRepository.path }), let project = existing.project {
            return project
        }
        let base = mainRepository.lastPathComponent.lowercased()
        return Self.unique(base) { name in
            environments.contains { $0.project == name && $0.mainRepository != mainRepository.path }
        }
    }

    private static func unique(_ base: String, taken: (String) -> Bool) -> String {
        if !taken(base) { return base }
        var n = 2
        while taken("\(base)-\(n)") { n += 1 }
        return "\(base)-\(n)"
    }
}

public struct EnvironmentRecord: Codable, Equatable, Sendable {
    public enum Owner: Codable, Equatable, Sendable {
        /// 在 worktree 里 napbox up 创建，worktree 删除后 napbox 自动回收
        case worktree
        /// 调用方（如 CodeOS）创建，只能由调用方操作和回收
        case caller(id: String)

        /// 调用方持有时是持有方标识
        public var callerID: String? {
            if case .caller(let id) = self { id } else { nil }
        }
    }

    public var name: String
    /// worktree 持有的环境才有
    public var project: String?
    public var mainRepository: String?
    /// 代码所在目录（worktree 根目录，或调用方传入的代码副本路径）
    public var worktree: String
    public var owner: Owner
    /// 分配的宿主机端口，包括没启用的 profile 里的服务留着的（definition.reservedPorts）。对外用 activePorts
    public var ports: [PortAssignment]
    /// 本机进程的端口（definition.hostPorts 分到的），napboxd 不锁。没有是 nil
    public var hostPorts: [HostPortAssignment]?
    /// 虚拟机在系统 NAT 网段里的固定 IP
    public var ip: String?
    /// up 时解析好的 compose，之后唤醒都用这一份，直到下次 up
    public var definition: ComposeProject?
    /// 已经成功跑完的一次性服务：唤醒时加进 pod 但不启动
    public var completedServices: [String]
    /// 出网模式：新环境是 open；在运行时切换马上生效，休眠时切换下次唤醒生效
    public var egress: EgressMode
    /// 临时环境的名字；nil 是普通环境。临时环境不休眠，停下来就直接销毁
    public var temporary: String?
    /// 开始了还没做完的操作：动数据之前记上，做完一起去掉。napboxd 中途被杀时，下次启动先把它做完再开始监听
    public var pending: PendingOperation?

    /// 要分几步、中途停下会留下半截状态的操作
    public enum PendingOperation: Codable, Equatable, Sendable {
        /// 回收（down、worktree 删掉、临时环境销毁）：数据移走（或删掉）以后还要放端口、删登记
        case recycle(reason: String, discardData: Bool)
        /// reset 一个数据卷：卷移走以后还要清掉已跑完的一次性服务，下次起来重新初始化
        case resetVolume(String)
    }

    public init(name: String, project: String?, mainRepository: String?, worktree: String, owner: Owner, ports: [PortAssignment] = [],
                ip: String? = nil, definition: ComposeProject? = nil, completedServices: [String] = [], egress: EgressMode = .open,
                temporary: String? = nil) {
        self.name = name
        self.project = project
        self.mainRepository = mainRepository
        self.worktree = worktree
        self.owner = owner
        self.ports = ports
        self.ip = ip
        self.definition = definition
        self.completedServices = completedServices
        self.egress = egress
        self.temporary = temporary
    }

    /// 启用的服务的端口：转发、列出、写进 ports.json。其余只是锁着留给没启用的 profile，连上来直接断开
    public var activePorts: [PortAssignment] {
        ports.filter { definition?.service($0.service)?.ports.contains($0.containerPort) == true }
    }

    /// 登记的全部宿主机端口：服务的加上本机进程的。分配时不能给别的环境，down 时一起放开
    public var allHostPorts: [Int] { ports.map(\.hostPort) + (hostPorts ?? []).map(\.hostPort) }

    /// 环境的数据目录名：环境名里有 `/` 和中文，目录名用一个不会变的短 ID
    public var id: String { Self.id(of: name) }

    /// 还没登记时也能算（第一次构建发生在登记之前）
    public static func id(of name: String) -> String {
        let hash = name.utf8.reduce(UInt64(14695981039346656037)) { ($0 ^ UInt64($1)) &* 1099511628211 }
        return String(hash, radix: 16)
    }
}

public final class StateStore {
    public let url: URL
    public private(set) var state: NapboxState

    private struct Header: Decodable {
        var version: Int
    }

    /// 文件不存在就从空状态开始；文件读不了、坏了或格式版本不对直接报错，不覆盖（里面有端口登记）。
    public init(url: URL) throws(NapboxError) {
        self.url = url
        guard FileManager.default.fileExists(atPath: url.path) else {
            state = NapboxState()
            return
        }
        let keep = "里面有端口登记，napboxd 不会覆盖它，请先把它移走或修好。"
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw NapboxError(.stateCorrupted, "状态文件 \(url.path) 读不了（\(error.localizedDescription)）。\(keep)")
        }
        do {
            let version = try DiskJSON.decoder.decode(Header.self, from: data).version
            guard version == NapboxState.currentVersion else {
                throw NapboxError(.stateCorrupted, "状态文件 \(url.path) 是第 \(version) 版格式，这个 napboxd 只认第 \(NapboxState.currentVersion) 版。\(keep)")
            }
            state = try DiskJSON.decoder.decode(NapboxState.self, from: data)
        } catch let error as NapboxError {
            throw error
        } catch {
            throw NapboxError(.stateCorrupted, "状态文件 \(url.path) 读不了（\(error)）。\(keep)")
        }
    }

    /// 修改并立即写回磁盘（先写临时文件再改名，不会写一半）。body 抛错时什么都不改。
    @discardableResult
    public func update<T>(_ body: (inout NapboxState) throws(NapboxError) -> T) throws(NapboxError) -> T {
        var next = state
        let result = try body(&next)
        do {
            try DiskJSON.encoder.encode(next).write(to: url, options: [.atomic])
            chmod(url.path, 0o600)
        } catch {
            throw NapboxError(.internalError, "写不了状态文件 \(url.path)：\(error.localizedDescription)")
        }
        state = next
        return result
    }
}
