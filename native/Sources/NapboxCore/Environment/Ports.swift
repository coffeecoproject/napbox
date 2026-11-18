// 端口分配和锁定：从 40000–49999 接着上次往后分配，同一个环境每次一样；
// 服务的端口分配后 napboxd 一直监听（休眠时也不放开），别的程序拿不到。
// 本机进程的端口（x-napbox.host_ports）从同一个范围分，napboxd 不占着，留给项目自己的进程监听。
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

/// 本机进程的端口：x-napbox.host_ports 里的一个名字分到的宿主机端口
public struct HostPortAssignment: Codable, Equatable, Hashable, Sendable {
    public var name: String
    public var hostPort: Int

    public init(name: String, hostPort: Int) {
        self.name = name
        self.hostPort = hostPort
    }
}

public struct PortRequest: Hashable, Sendable {
    public var service: String
    public var containerPort: Int

    public init(service: String, containerPort: Int) {
        self.service = service
        self.containerPort = containerPort
    }
}

/// 端口变量：每个登记的端口给两个变量，名字不能撞（compose 检查时用 name 查），status、up 的结果和 ports.json 都按这里拼。
/// - `NAPBOX_<服务>_<容器端口>` → `127.0.0.1:41217`：程序连它用
/// - `NAPBOX_<服务>_<容器端口>_SITE` → `feat-x--crocwork.localhost:41217`：给浏览器打开的地址用，cookie 按环境分开（Hostnames）
/// 另有一个 `NAPBOX_HOSTNAME` → `feat-x--crocwork.localhost`：本机进程的端口拼浏览器地址用
public enum PortVariables {
    static let siteSuffix = "_SITE"
    public static let hostname = "NAPBOX_HOSTNAME"

    /// `NAPBOX_API_3100`：服务名转大写，字母数字以外的字符换成下划线。
    static func name(service: String, port: Int) -> String {
        let s = service.uppercased().unicodeScalars.map { c in
            ("A"..."Z").contains(c) || ("0"..."9").contains(c) ? Character(c) : "_"
        }
        return "NAPBOX_\(String(s))_\(port)"
    }

    static func siteName(service: String, port: Int) -> String { name(service: service, port: port) + siteSuffix }

    /// 变量的值：`127.0.0.1:41217`
    static func value(hostPort: Int) -> String { "127.0.0.1:\(hostPort)" }

    public static func name(of a: PortAssignment) -> String { name(service: a.service, port: a.containerPort) }
    public static func siteName(of a: PortAssignment) -> String { siteName(service: a.service, port: a.containerPort) }

    /// 服务端口的变量（两种）加上 NAPBOX_HOSTNAME：名字 → 值。compose 里能引用的就是这些（PortReferences）
    public static func variables(_ assignments: [PortAssignment], hostname: String) -> [String: String] {
        Dictionary(uniqueKeysWithValues: entries(assignments, hostname: hostname))
    }

    /// 交给调用方的全部变量：服务的端口、主机名，加上本机程序的端口。几种变量名不会撞（HostPortVariables.isValidName）
    public static func all(_ assignments: [PortAssignment], hostname: String, hostPorts: [HostPortAssignment]) -> [String: String] {
        let host = hostPorts.map { (HostPortVariables.name(of: $0), String($0.hostPort)) }
        return Dictionary(uniqueKeysWithValues: entries(assignments, hostname: hostname) + host)
    }

    private static func entries(_ assignments: [PortAssignment], hostname: String) -> [(String, String)] {
        [(Self.hostname, hostname)] + assignments.flatMap { a in
            [(name(of: a), value(hostPort: a.hostPort)), (siteName(of: a), "\(hostname):\(a.hostPort)")]
        }
    }
}

/// 本机进程的端口变量：`NAPBOX_HOST_<名字>`，值只是端口号（进程要监听它，不是去连它）。
public enum HostPortVariables {
    static let prefix = "NAPBOX_HOST_"

    /// 名字：小写字母开头，只用小写字母、数字和下划线，不以 `_`、`_数字` 或 `_数字_site` 结尾。
    /// 服务端口的变量 NAPBOX_<服务>_<容器端口> 一定以 `_数字` 结尾、浏览器地址的变量以 `_数字_SITE` 结尾，
    /// 所以几种变量名不会撞，也分得开（isVariable）
    public static func isValidName(_ name: String) -> Bool {
        guard let first = name.first, ("a"..."z").contains(first),
              name.allSatisfy({ ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "_" })
        else { return false }
        let parts = name.split(separator: "_", omittingEmptySubsequences: false)
        func isPortNumber(_ p: Substring) -> Bool { !p.isEmpty && p.allSatisfy(\.isNumber) }
        guard let last = parts.last, !last.isEmpty, !(parts.count > 1 && isPortNumber(last)) else { return false }
        return !(parts.count > 2 && last == "site" && isPortNumber(parts[parts.count - 2]))
    }

    public static func name(of a: HostPortAssignment) -> String { prefix + a.name.uppercased() }

    /// 变量名是不是本机进程端口的样子（NAPBOX_HOST_ 后面是一个合规的名字）。服务叫 host 时它的
    /// NAPBOX_HOST_5432 以 `_数字` 结尾、NAPBOX_HOST_5432_SITE 以 `_数字_SITE` 结尾，不算
    public static func isVariable(_ variable: String) -> Bool {
        variable.hasPrefix(prefix) && isValidName(variable.dropFirst(prefix.count).lowercased())
    }
}

/// napboxd 持有的监听 socket：一个宿主机端口两个，127.0.0.1 和 [::1] 各一个。
/// 两边都要占：环境的主机名（*.localhost）先解析到 ::1，只占 127.0.0.1 的话，别的程序在 ::1 上监听同一个端口时，
/// 浏览器会连到它那里去。两边都绑得上才算锁上，有一边绑不上就都放开。
/// 每一边判断端口有没有被别的程序占用：
/// 1. 不带 SO_REUSEADDR 绑定：绑上了就是完全空闲（别的程序监听在这个地址或通配地址上都会绑不上）。
/// 2. 绑不上时，可能是有程序在监听，也可能只是刚断开的连接还在 TIME_WAIT（napboxd 重启后常见）。
///    这时才连一下这个地址的这个端口：连得上就是有程序在监听，跳过。
/// 3. 连不上，当作只是 TIME_WAIT，带 SO_REUSEADDR 再绑。
/// 已知的误判：对方程序卡住、不接受连接、排队又满了时，第 2 步会连不上，被当作空闲。
/// 不用 netstat 查监听列表：从程序里调用时看不到网络连接（2026-11-07 实测，终端里正常），不可靠。
public final class PortLocks {
    /// 本机回环的两个地址
    enum Loopback: CaseIterable, Sendable {
        case v4, v6
    }

    private var sockets: [Int: [Int32]] = [:]

    public init() {}

    deinit {
        for fds in sockets.values { for fd in fds { close(fd) } }
    }

    public var lockedPorts: [Int] { sockets.keys.sorted() }

    /// 已经锁着也算成功。有一边被别的程序占着返回 false，这次绑上的一边也放开。
    /// 不是被占的绑定失败（比如 lo0 上没有 ::1，报 EADDRNOTAVAIL）换哪个端口都一样，直接报错说明，不当成被占
    public func lock(_ port: Int) throws(NapboxError) -> Bool {
        if sockets[port] != nil { return true }
        var fds: [Int32] = []
        for address in Loopback.allCases {
            let fd: Int32?
            do { fd = try Self.acquire(port, address) } catch {
                for fd in fds { close(fd) }
                throw error
            }
            guard let fd else {
                for fd in fds { close(fd) }
                return false
            }
            fds.append(fd)
        }
        sockets[port] = fds
        return true
    }

    /// 被别的程序占着是 nil
    private static func acquire(_ port: Int, _ address: Loopback) throws(NapboxError) -> Int32? {
        let first = listen(port, address, reuseAddress: false)
        if let fd = first.fd { return fd }
        if first.error == EADDRINUSE {
            if someoneListening(port, address) { return nil }
            let again = listen(port, address, reuseAddress: true)
            if let fd = again.fd { return fd }
            if again.error == EADDRINUSE { return nil }
            throw unusable(port, address, again.error)
        }
        throw unusable(port, address, first.error)
    }

    private static func unusable(_ port: Int, _ address: Loopback, _ code: Int32) -> NapboxError {
        let detail = String(cString: strerror(code))
        let hint = address == .v6
            ? "napbox 在 127.0.0.1 和 [::1] 上都要监听（浏览器打开 *.localhost 会连 ::1）；lo0 上没有 ::1 时（ifconfig lo0 可以查）先把它加回来"
            : "napbox 要在 127.0.0.1 上监听，先查本机回环 lo0 是否正常（ifconfig lo0）"
        return NapboxError(.portUnavailable, "在 \(address.display) 上监听端口 \(port) 失败（\(detail)），不是端口被占，换端口也一样。\(hint)。")
    }

    /// 这个地址上这个端口有没有程序在接受连接。本机回环的连接立刻就有结果，不需要超时。
    static func someoneListening(_ port: Int, _ address: Loopback) -> Bool {
        let fd = socket(address.family, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        return address.withSockaddr(port) { connect(fd, $0, $1) } == 0
    }

    /// 在这个地址上绑定并监听，失败时给出 errno。
    private static func listen(_ port: Int, _ address: Loopback, reuseAddress: Bool) -> (fd: Int32?, error: Int32) {
        let fd = socket(address.family, SOCK_STREAM, 0)
        guard fd >= 0 else { return (nil, errno) }
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        var one: Int32 = 1
        if reuseAddress { setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size)) }
        if address == .v6 { setsockopt(fd, IPPROTO_IPV6, IPV6_V6ONLY, &one, socklen_t(MemoryLayout<Int32>.size)) }
        let bound = address.withSockaddr(port) { bind(fd, $0, $1) }
        guard bound == 0, Darwin.listen(fd, 128) == 0 else {
            let code = errno
            close(fd)
            return (nil, code)
        }
        return (fd, 0)
    }

    /// 给端口代理用的副本（dup），两个地址各一个：代理接受连接、关掉自己那份都不影响锁；锁只在 release 时放开。
    public func duplicate(_ port: Int) -> [Int32]? {
        guard let fds = sockets[port] else { return nil }
        var copies: [Int32] = []
        for fd in fds {
            let copy = dup(fd)
            guard copy >= 0 else {
                for c in copies { close(c) }
                return nil
            }
            _ = fcntl(copy, F_SETFD, FD_CLOEXEC)
            copies.append(copy)
        }
        return copies
    }

    public func release(_ port: Int) {
        for fd in sockets.removeValue(forKey: port) ?? [] { close(fd) }
    }

    /// 端口现在有没有被别的程序占着：判断和 lock 一样，判断完马上放开，不占着。只用于不锁的端口（本机进程的端口）
    public func isFree(_ port: Int) throws(NapboxError) -> Bool {
        guard sockets[port] == nil, try lock(port) else { return false }
        release(port)
        return true
    }
}

extension PortLocks.Loopback {
    var family: Int32 { self == .v4 ? AF_INET : AF_INET6 }
    var display: String { self == .v4 ? "127.0.0.1" : "[::1]" }

    /// 127.0.0.1 或 [::1] 的这个端口
    func withSockaddr<T>(_ port: Int, _ body: (UnsafePointer<sockaddr>, socklen_t) -> T) -> T {
        switch self {
        case .v4:
            var addr = sockaddr_in()
            addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = in_port_t(UInt16(port).bigEndian)
            addr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
            return withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { body($0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        case .v6:
            var addr = sockaddr_in6()
            addr.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
            addr.sin6_family = sa_family_t(AF_INET6)
            addr.sin6_port = in_port_t(UInt16(port).bigEndian)
            _ = inet_pton(AF_INET6, "::1", &addr.sin6_addr)
            return withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { body($0, socklen_t(MemoryLayout<sockaddr_in6>.size)) } }
        }
    }
}

/// 一次分配的结果。lastNew 是这次新分到的端口里最后分的那个（按查找顺序），由调用方写回登记表的
/// `lastAssignedPort`，下次从它后面接着找；没有新分的端口时是 nil，登记表里的不动。
public struct PortAllocation: Equatable, Sendable {
    public var ports: [PortAssignment]
    public var hostPorts: [HostPortAssignment]
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
    /// hostPorts 是本机进程的端口名：已经分过的沿用，不再查有没有被占（占着它的多半就是项目自己的进程）；
    /// 新的接在服务端口后面从同一个序列里找，要求这时没人占着，分到后不锁。
    public static func assign(
        _ requests: [PortRequest], hostPorts: [String], environment: String, state: NapboxState,
        locks: PortLocks, range: ClosedRange<Int> = range
    ) throws(NapboxError) -> PortAllocation {
        let record = state.environment(environment)
        let current = record?.ports ?? []
        let currentHost = record?.hostPorts ?? []
        let takenByOthers = Set(state.environments.filter { $0.name != environment }.flatMap { $0.allHostPorts })
        let wanted = Set(requests)
        var result: [PortAssignment] = []
        var newlyLocked: [Int] = []
        func rollback() { for p in newlyLocked { locks.release(p) } }

        for a in current where wanted.contains(a.request) {
            let wasLocked = locks.lockedPorts.contains(a.hostPort)
            let locked: Bool
            do { locked = try locks.lock(a.hostPort) } catch {
                rollback()
                throw error
            }
            guard locked else {
                rollback()
                throw NapboxError(.portUnavailable, "\(a.service) 的 \(a.containerPort) 端口登记的是宿主机 \(a.hostPort)，现在被别的程序占着。先停掉占用它的程序（lsof -nP -iTCP:\(a.hostPort) -sTCP:LISTEN 可以查），或者 napbox down 之后重新 up 换一个端口。")
            }
            if !wasLocked { newlyLocked.append(a.hostPort) }
            result.append(a)
        }
        var used = takenByOthers.union(current.map(\.hostPort)).union(currentHost.map(\.hostPort))
        // 从上次分到的端口后面开始，绕一圈回到它为止
        let start = state.lastAssignedPort.flatMap { range.contains($0) && $0 < range.upperBound ? $0 + 1 : nil } ?? range.lowerBound
        var candidates = Array(start...range.upperBound) + Array(range.lowerBound..<start)
        candidates.reverse()
        var lastNew: Int?
        /// 按顺序找下一个没登记、accept 也认可的端口；找不到时放开这次新锁的，报错
        func next(_ accept: (Int) throws(NapboxError) -> Bool) throws(NapboxError) -> Int {
            while let port = candidates.popLast() {
                if used.contains(port) { continue }
                let accepted: Bool
                do { accepted = try accept(port) } catch {
                    rollback()
                    throw error
                }
                if accepted {
                    used.insert(port)
                    lastNew = port
                    return port
                }
            }
            rollback()
            throw NapboxError(.portUnavailable, "\(range.lowerBound)–\(range.upperBound) 里已经没有能用的端口了")
        }
        var handled = Set(result.map(\.request))
        for r in requests where handled.insert(r).inserted {
            let port = try next(locks.lock)
            newlyLocked.append(port)
            result.append(PortAssignment(service: r.service, containerPort: r.containerPort, hostPort: port))
        }
        var hostResult: [HostPortAssignment] = []
        for name in hostPorts {
            if let kept = currentHost.first(where: { $0.name == name }) { hostResult.append(kept) }
            else { hostResult.append(HostPortAssignment(name: name, hostPort: try next(locks.isFree))) }
        }
        for a in current where !wanted.contains(a.request) { locks.release(a.hostPort) }
        return PortAllocation(
            ports: result.sorted { ($0.service, $0.containerPort) < ($1.service, $1.containerPort) },
            hostPorts: hostResult, lastNew: lastNew
        )
    }
}
