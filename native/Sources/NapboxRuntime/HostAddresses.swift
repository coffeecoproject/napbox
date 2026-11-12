// 宿主机自己的地址：open 模式下环境要连不到它们（DESIGN.md 第 6 节）。私有网段之外的也算，
// 比如 Clash TUN 网卡的 198.18.0.1、直接分到的公网 IP。
import Darwin
import NapboxProtocol

enum HostAddresses {
    /// 所有网卡当前的 IPv4、IPv6 地址（不含回环），排好序去重。读不了时报错：当成「没有地址」的话规则会漏挡宿主机
    static func current() throws(NapboxError) -> [String] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0 else {
            throw NapboxError(.runtimeUnavailable, "读不了宿主机的网卡地址（getifaddrs：\(String(cString: strerror(errno)))）")
        }
        defer { freeifaddrs(head) }
        var result = Set<String>()
        var cursor = head
        while let ifa = cursor {
            defer { cursor = ifa.pointee.ifa_next }
            guard let addr = ifa.pointee.ifa_addr, ifa.pointee.ifa_flags & UInt32(IFF_LOOPBACK) == 0 else { continue }
            let family = Int32(addr.pointee.sa_family)
            guard family == AF_INET || family == AF_INET6 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            // 链路本地的 IPv6 带 %网卡名，规则里只要地址
            let text = String(decoding: host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            result.insert(String(text.split(separator: "%")[0]))
        }
        return result.sorted()
    }
}
