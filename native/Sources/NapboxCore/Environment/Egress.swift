// 出网规则的内容（DESIGN.md 第 6 节）：open 模式放行哪个 DNS、挡哪些网段和地址。napbox-guard 只按参数加规则，
// 挡什么由这里决定。
import Foundation
import NapboxProtocol

public enum EgressRules {
    /// open 模式整段挡住的网段：私有网段（网关所在网段、宿主机的局域网 IP、Tailscale IP 都在里面）、链路本地、
    /// IPv6 的本地地址。Clash fake-ip 的 198.18.0.0/15 不能整段挡，否则外网全断，宿主机在那里的地址单独挡
    static let blockedRanges = [
        "10.0.0.0/8", "100.64.0.0/10", "169.254.0.0/16", "172.16.0.0/12", "192.168.0.0/16", "fc00::/7", "fe80::/10",
    ]

    /// `napbox-guard egress` 后面的参数：`open <DNS 服务器> <要挡的网段或地址...>` 或 `none`
    /// - hostAddresses：宿主机自己的地址（先用 uncovered 去掉已经整段挡了的），只有 open 模式要
    public static func guardArguments(_ mode: EgressMode, hostAddresses: [String]) -> [String] {
        switch mode {
        case .open: ["open", AddressAllocator.gateway] + blockedRanges + hostAddresses
        case .none: ["none"]
        }
    }

    /// 不在 blockedRanges 里的地址。在里面的已经整段挡了，不用单独列；宿主机在这些网段里的地址
    /// （比如网桥 bridge100 的 192.168.64.1 和 fe80 地址）还会随虚拟机起停出现、消失，列进来会让规则跟着反复重加。
    public static func uncovered(_ addresses: [String]) -> [String] {
        let ranges = blockedRanges.compactMap(Network.init)
        return addresses.filter { a in
            guard let bytes = Network.bytes(of: a) else { return true }
            return !ranges.contains { $0.contains(bytes) }
        }
    }

    private struct Network {
        let bytes: [UInt8]
        let prefix: Int

        init?(_ cidr: String) {
            let parts = cidr.split(separator: "/")
            guard parts.count == 2, let bytes = Self.bytes(of: String(parts[0])), let prefix = Int(parts[1]),
                  prefix >= 0, prefix <= bytes.count * 8 else { return nil }
            self.bytes = bytes
            self.prefix = prefix
        }

        func contains(_ address: [UInt8]) -> Bool {
            guard address.count == bytes.count else { return false }
            for bit in 0..<prefix {
                let mask = UInt8(0x80) >> UInt8(bit % 8)
                if address[bit / 8] & mask != bytes[bit / 8] & mask { return false }
            }
            return true
        }

        /// IPv4 是 4 字节，IPv6 是 16 字节；不是 IP 时是 nil
        static func bytes(of address: String) -> [UInt8]? {
            var v4 = in_addr()
            if inet_pton(AF_INET, address, &v4) == 1 { return withUnsafeBytes(of: &v4) { Array($0) } }
            var v6 = in6_addr()
            if inet_pton(AF_INET6, address, &v6) == 1 { return withUnsafeBytes(of: &v6) { Array($0) } }
            return nil
        }
    }
}
