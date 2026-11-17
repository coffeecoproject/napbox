// 服务卡在内存上：网络小容器看出来（guard/memwatch.go），报给 napboxd 该结束哪个进程，napboxd 结束它并写进服务的日志。
// 虚拟机没有交换空间，内存到顶后内核不结束进程、一直卡着（DESIGN.md 第 2 节「服务卡在内存上限」、第 7 节）。
import Foundation

/// 网络小容器报来的一条（guard/memwatch_logic.go 的 memoryReport）
struct MemoryStall: Codable, Equatable, Sendable {
    enum Scope: String, Codable, Sendable {
        /// 到了这个服务自己的上限
        case service
        /// 没到自己的上限，是整个环境的内存用完了
        case environment
    }

    /// 卡住的服务
    var service: String
    var scope: Scope
    /// 卡住的服务的上限，0 是没有单独的上限
    var limitBytes: UInt64
    /// 过去 10 秒里它的进程全在等内存的时间比例（memory.pressure 的 full avg10）
    var pressure: Double
    /// 要结束的进程：所在的服务、虚拟机里的进程号、名字、占的内存
    var targetService: String
    var pid: Int32
    var process: String
    var processBytes: UInt64

    /// 写进服务日志、napboxd 日志的那一行
    var message: String {
        let stall = "卡住了（过去 10 秒有 \(Int(pressure))% 的时间全在等内存）"
        let killed = "\(process)（进程号 \(pid)，占 \(Self.size(processBytes))）"
        switch scope {
        case .service:
            return "napbox：\(service) 的内存到了上限 \(Self.size(limitBytes))，\(stall)，结束了它里面占内存最多的进程 \(killed)。"
                + "要更多内存就调大它的 mem_limit，或者去掉上限、和环境里其他没写上限的服务共用内存。"
        case .environment:
            return "napbox：整个环境的内存用完了，\(service) \(stall)，结束了占内存最多的进程：\(targetService) 里的 \(killed)。"
                + "环境的内存是各服务那一份加起来（写了 mem_limit 的按它算，没写的每个 1G）：用得多的服务写上够用的 mem_limit。"
        }
    }

    static func size(_ bytes: UInt64) -> String {
        bytes >= 1 << 30 ? String(format: "%.1fGB", Double(bytes) / Double(1 << 30)) : "\(bytes >> 20)MB"
    }
}
