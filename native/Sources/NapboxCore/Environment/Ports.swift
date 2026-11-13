// 端口分配和锁定：从 40000–49999 接着上次往后分配，同一个环境每次一样；
// 分配后 napboxd 一直监听这些端口（休眠时也不放开），别的程序拿不到。
import Darwin
import Foundation
import NapboxProtocol

public struct PortAssignment: Codable, Equatable, Hashable, Sendable {
    public var service: String
    public var containerPort: Int
    public var hostPort: Int

    public init(service: String, containerPort: Int, hostPort: Int) {
        self.service = service
        self.containerPort = containerPort
        self.hostPort = hostPort
    }

    public var request: PortRequest { PortRequest(service: service, containerPort: containerPort) }
}

public struct PortRequest: Hashable, Sendable {
    public var service: String
    public var containerPort: Int

    public init(service: String, containerPort: Int) {
        self.service = service
        self.containerPort = containerPort
    }
}

/// 端口变量：每个登记的端口给一个 `NAPBOX_<服务>_<容器端口>` 变量，值是宿主机上连它的地址。
/// 名字不能撞（compose 检查时用 name 查），status、up 的结果和 ports.json 都按这里拼。
public enum PortVariables {
    /// `NAPBOX_API_3100`：服务名转大写，字母数字以外的字符换成下划线。
    static func name(service: String, port: Int) -> String {
        let s = service.uppercased().unicodeScalars.map { c in
            ("A"..."Z").contains(c) || ("0"..."9").contains(c) ? Character(c) : "_"
        }
        return "NAPBOX_\(String(s))_\(port)"
    }

    /// 变量的值：`127.0.0.1:41217`
    static func value(hostPort: Int) -> String { "127.0.0.1:\(hostPort)" }

    public static func name(of a: PortAssignment) -> String { name(service: a.service, port: a.containerPort) }

    /// 登记的端口对应的变量：名字 → 值
    public static func variables(_ assignments: [PortAssignment]) -> [String: String] {
        Dictionary(uniqueKeysWithValues: assignments.map { (name(of: $0), value(hostPort: $0.hostPort)) })
    }
}

/// napboxd 持有的监听 socket，一个宿主机端口一个，只监听 127.0.0.1。
/// 判断端口有没有被别的程序占用：
/// 1. 不带 SO_REUSEADDR 绑定：绑上了就是完全空闲（别的程序监听在 127.0.0.1、0.0.0.0、[::] 上都会绑不上）。
/// 2. 绑不上时，可能是有程序在监听，也可能只是刚断开的连接还在 TIME_WAIT（napboxd 重启后常见）。
///    这时才连一下 127.0.0.1 的这个端口：连得上就是有程序在监听，跳过。
/// 3. 连不上，当作只是 TIME_WAIT，带 SO_REUSEADDR 再绑。
/// 已知的误判：对方程序卡住、不接受连接、排队又满了时，第 2 步会连不上，被当作空闲。
/// 不用 netstat 查监听列表：从程序里调用时看不到网络连接（2026-11-07 实测，终端里正常），不可靠。
public final class PortLocks {
    private var sockets: [Int: Int32] = [:]

    public init() {}

    deinit {
        for fd in sockets.values { close(fd) }
    }

    public var lockedPorts: [Int] { sockets.keys.sorted() }

    /// 已经锁着也算成功。被别的程序占着返回 false。
    public func lock(_ port: Int) -> Bool {
        if sockets[port] != nil { return true }
        let first = Self.listen(port, reuseAddress: false)
        if let fd = first.fd {
            sockets[port] = fd
            return true
        }
        guard first.error == EADDRINUSE, !Self.someoneListening(port),
              let fd = Self.listen(port, reuseAddress: true).fd else { return false }
        sockets[port] = fd
        return true
    }

    /// 127.0.0.1 上这个端口有没有程序在接受连接。本机回环的连接立刻就有结果，不需要超时。
    static func someoneListening(_ port: Int) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var addr = loopback(port)
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        return rc == 0
    }

    /// 在 127.0.0.1 上绑定并监听，失败时给出 errno。
    private static func listen(_ port: Int, reuseAddress: Bool) -> (fd: Int32?, error: Int32) {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return (nil, errno) }
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        if reuseAddress {
            var one: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
        }
        var addr = loopback(port)
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0, Darwin.listen(fd, 128) == 0 else {
            let code = errno
            close(fd)
            return (nil, code)
        }
        return (fd, 0)
    }

    private static func loopback(_ port: Int) -> sockaddr_in {
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(port).bigEndian)
        addr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        return addr
    }

    /// 给端口代理用的副本（dup）：代理接受连接、关掉自己那份都不影响锁；锁只在 release 时放开。
    public func duplicate(_ port: Int) -> Int32? {
        guard let fd = sockets[port] else { return nil }
        let copy = dup(fd)
        guard copy >= 0 else { return nil }
        _ = fcntl(copy, F_SETFD, FD_CLOEXEC)
        return copy
    }

    public func release(_ port: Int) {
        if let fd = sockets.removeValue(forKey: port) { close(fd) }
    }
}

/// 一次分配的结果。lastNew 是这次新分到的端口里最后分的那个（按查找顺序），由调用方写回登记表的
/// `lastAssignedPort`，下次从它后面接着找；没有新分的端口时是 nil，登记表里的不动。
public struct PortAllocation: Equatable, Sendable {
    public var ports: [PortAssignment]
    public var lastNew: Int?
}

extension NapboxState {
    /// 把一次分配写回登记表的接续位置：有新分的端口，下次从最后那个后面接着找；没有就不动
    public mutating func recordAllocation(_ allocation: PortAllocation) {
        if let last = allocation.lastNew { lastAssignedPort = last }
    }
}

public enum PortAllocator {
    public static let range = 40000...49999

    /// 给一个环境分配端口：已经分配过的沿用（并确保锁着），新的从登记表里上次分到的端口后面接着找，到头了从范围开头
    /// 再找，取第一个没登记、也绑得上的端口；不再需要的释放。哪些端口已被占用由登记表决定：其他环境登记的端口即使
    /// 暂时没锁上，也不能分给这个环境。
    /// 接着找而不是每次从头找：回收的环境放开的端口要轮完整个范围才会再分出去，项目和 agent 手里过期的地址
    /// （启动脚本写出的文件、记下的端口）连上去是没人监听、直接报错，不会悄悄连到别的 worktree 的服务。
    /// 出错时这次新锁的端口都放开。返回新的分配结果，由调用方写回登记表。
    public static func assign(
        _ requests: [PortRequest], environment: String, state: NapboxState,
        locks: PortLocks, range: ClosedRange<Int> = range
    ) throws(NapboxError) -> PortAllocation {
        let current = state.environment(environment)?.ports ?? []
        let takenByOthers = Set(state.environments.filter { $0.name != environment }.flatMap { $0.ports.map(\.hostPort) })
        let wanted = Set(requests)
        var result: [PortAssignment] = []
        var newlyLocked: [Int] = []
        func rollback() { for p in newlyLocked { locks.release(p) } }

        for a in current where wanted.contains(a.request) {
            let wasLocked = locks.lockedPorts.contains(a.hostPort)
            guard locks.lock(a.hostPort) else {
                rollback()
                throw NapboxError(.portUnavailable, "\(a.service) 的 \(a.containerPort) 端口登记的是宿主机 \(a.hostPort)，现在被别的程序占着。先停掉占用它的程序（lsof -nP -iTCP:\(a.hostPort) -sTCP:LISTEN 可以查），或者 napbox down 之后重新 up 换一个端口。")
            }
            if !wasLocked { newlyLocked.append(a.hostPort) }
            result.append(a)
        }
        var used = takenByOthers.union(current.map(\.hostPort))
        // 从上次分到的端口后面开始，绕一圈回到它为止
        let start = state.lastAssignedPort.flatMap { range.contains($0) && $0 < range.upperBound ? $0 + 1 : nil } ?? range.lowerBound
        var candidates = Array(start...range.upperBound) + Array(range.lowerBound..<start)
        candidates.reverse()
        var lastNew: Int?
        var handled = Set(result.map(\.request))
        for r in requests where handled.insert(r).inserted {
            var assigned: Int?
            while let port = candidates.popLast() {
                if used.contains(port) { continue }
                if locks.lock(port) {
                    assigned = port
                    break
                }
            }
            guard let port = assigned else {
                rollback()
                throw NapboxError(.portUnavailable, "\(range.lowerBound)–\(range.upperBound) 里已经没有能用的端口了")
            }
            newlyLocked.append(port)
            used.insert(port)
            lastNew = port
            result.append(PortAssignment(service: r.service, containerPort: r.containerPort, hostPort: port))
        }
        for a in current where !wanted.contains(a.request) { locks.release(a.hostPort) }
        return PortAllocation(ports: result.sorted { ($0.service, $0.containerPort) < ($1.service, $1.containerPort) }, lastNew: lastNew)
    }
}
