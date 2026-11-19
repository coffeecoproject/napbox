// 环境的固定 IP：只用 192.168.64.128–246，前半段留给 container 命令行，247–254 留给构建虚拟机。
// 检查地址有没有被占用，不能靠"连一下试试"（开着 Clash 时空闲地址也连得上），所以看两处：
// napbox 自己的登记，和系统的 ARP 表（这个网段里最近有应答的地址）。
import Foundation
import NapboxProtocol

public enum AddressAllocator {
    static let prefix = "192.168.64."
    static let hosts = 128...246
    static let builderHosts = 247...254
    public static let gateway = "192.168.64.1"

    /// 虚拟机里 `napbox-guard gateway` 查到网关不在它的网络上时给的错误。napbox 用系统共用的 NAT 网，网段由系统定，
    /// 默认就是这个；这个网段被别的程序的虚拟机网络（macOS 26 的 vmnet_network）占着时，系统把虚拟机放进别的网段，
    /// 写死的地址和网关对不上，DNS 和出网都不通。占着它的常见是两种：没固定网段的苹果 container 在 napbox 之前起了网络；
    /// 建过这种网络的程序在网上还挂着虚拟机时退出（崩溃、被强杀），系统一直留着它的网段不放（apple/container#2357）。
    /// napbox 不自己建网就是因为后一种：napboxd 一崩溃，下次就起不了环境（2026-11-18 实测）
    public static func gatewayUnreachable(_ detail: String) -> NapboxError {
        NapboxError(.addressUnavailable, """
            虚拟机连不上网关 \(gateway)（\(detail)）：\(prefix)0/24 这个网段被别的程序的虚拟机网络占了。常见两种：\
            苹果 container 的服务开着、没固定网段，在 ~/.config/container/config.toml 写 [network] subnet = "192.168.65.0/24"，\
            再重启它（container system stop、container system start）；\
            用虚拟机网络的程序崩溃后系统留着它的网段不放，运行 sudo killall InternetSharing（系统会自动重新拉起它）或重启电脑。\
            处理完再重试。
            """)
    }

    /// 构建虚拟机下一次用的地址：每次换一个。napboxd 崩溃时构建虚拟机来不及让引擎先退出，开着 Clash 的 TUN 时，
    /// 这个地址之后可能很久连不上外网；下一次构建换地址就不受影响。
    /// - last：上一次用的地址，没有或看不懂时从头开始
    public static func builderAddress(after last: String) -> String {
        let host = Int(last.dropFirst(prefix.count)).flatMap { last.hasPrefix(prefix) && builderHosts.contains($0) ? $0 : nil }
        guard let host, host < builderHosts.upperBound else { return "\(prefix)\(builderHosts.lowerBound)" }
        return "\(prefix)\(host + 1)"
    }

    /// 环境已经有 IP 就沿用；否则从小到大找第一个没登记、ARP 表里也没有的地址。
    public static func allocate(environment: String, state: NapboxState, inUseOnNetwork: Set<String>) throws(NapboxError) -> String {
        if let ip = state.environment(environment)?.ip { return ip }
        let registered = Set(state.environments.compactMap(\.ip))
        for host in hosts {
            let ip = "\(prefix)\(host)"
            if !registered.contains(ip), !inUseOnNetwork.contains(ip) { return ip }
        }
        throw NapboxError(.addressUnavailable, "\(prefix)\(hosts.lowerBound)–\(hosts.upperBound) 都被占用了，最多同时有 \(hosts.count) 个环境。先 napbox down 掉不用的环境。")
    }

    /// 环境虚拟机网卡的固定 MAC，由它的 IP 推出来：02:6e:62:00:<第 3 段>:<第 4 段>（02 开头是本地分配的地址，
    /// 6e:62 是 "nb"）。不指定的话每次起虚拟机都随机一个新的，而别的环境还在跑时网桥 bridge100 不拆，
    /// 宿主机的 ARP 缓存还指着旧 MAC，停了再起的环境就连不上（2026-11-07 实测）。napbox 的环境 IP 互不相同，
    /// 推出来的 MAC 也不会重复。
    public static func macAddress(for ip: String) throws(NapboxError) -> [UInt8] {
        let parts = ip.split(separator: ".").compactMap { UInt8($0) }
        guard parts.count == 4 else { throw NapboxError(.internalError, "环境的 IP \(ip) 不是 IPv4 地址") }
        return [0x02, 0x6e, 0x62, 0x00, parts[2], parts[3]]
    }
}

/// 环境里每个服务自己的地址。每个环境一台虚拟机，这个网段只在虚拟机里面，所以所有环境用同一个，
/// 互相不影响，宿主机上也看不到它。
public enum ServiceNetwork {
    static let prefix = "10.88.0."
    /// 虚拟机在这个网段里的地址，也是每个服务的默认路由
    public static let gateway = "\(prefix)1"
    public static let prefixLength = 24
    static let hosts = 2...254

    /// 服务名 → 地址：按名字排好序，从 10.88.0.2 起一个一个给。同一组服务每次算出来都一样，
    /// 休眠唤醒、重启之后服务的地址不变。
    public static func addresses(_ services: [String]) throws(NapboxError) -> [String: String] {
        guard services.count <= hosts.count else {
            throw NapboxError(.composeUnsupported, "一个环境最多 \(hosts.count) 个服务，这个项目有 \(services.count) 个")
        }
        return Dictionary(uniqueKeysWithValues: zip(services.sorted(), hosts).map { ($0, "\(prefix)\($1)") })
    }
}

public enum NetworkNeighbors {
    /// ARP 表里有应答的 IPv4 地址（不含 incomplete 的条目）。
    public static func addresses() -> Set<String> {
        guard let output = try? Subprocess.run("/usr/sbin/arp", ["-an"]) else { return [] }
        return parse(String(decoding: output.stdout, as: UTF8.self))
    }

    /// `? (192.168.64.5) at 1a:2b:... on bridge100 ifscope [bridge]`
    static func parse(_ text: String) -> Set<String> {
        var result = Set<String>()
        for line in text.split(separator: "\n") where !line.contains("incomplete") {
            guard let open = line.firstIndex(of: "("), let close = line.firstIndex(of: ")"), open < close else { continue }
            result.insert(String(line[line.index(after: open)..<close]))
        }
        return result
    }
}
