// 宿主机地址变化的通知：系统路由套接字（PF_ROUTE）上地址增删、网卡变化的消息。换 Wi-Fi、重启 Clash、
// 连 VPN 时都会有。open 模式要挡住宿主机自己的地址，地址变了就要给在运行的环境重新加规则（DESIGN.md 第 6 节）。
import Darwin
import Dispatch

final class HostAddressMonitor: @unchecked Sendable {
    private let source: DispatchSourceRead
    private let queue = DispatchQueue(label: "napbox.host-addresses")
    /// 只在 queue 上读写
    private var scheduled = false

    /// 一次变化往往连着好几条消息：收到后等 1 秒再调用 onChange，期间的消息合并成一次
    init(onChange: @escaping @Sendable () -> Void) throws(NapboxMonitorError) {
        let fd = socket(PF_ROUTE, SOCK_RAW, 0)
        guard fd >= 0 else { throw NapboxMonitorError(errno: errno) }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [unowned self] in
            var buffer = [UInt8](repeating: 0, count: 2048)
            var changed = false
            // 每次 read 读到一条消息；消息头前 4 字节是长度（2）、版本（1）、类型（1）
            while read(fd, &buffer, buffer.count) >= 4 {
                let type = Int32(buffer[3])
                if type == RTM_NEWADDR || type == RTM_DELADDR || type == RTM_IFINFO { changed = true }
            }
            guard changed, !scheduled else { return }
            scheduled = true
            queue.asyncAfter(deadline: .now() + 1) { [unowned self] in
                scheduled = false
                onChange()
            }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
    }
}

struct NapboxMonitorError: Error {
    let errno: Int32
    var message: String { "打不开路由套接字（PF_ROUTE）：\(String(cString: strerror(errno)))" }
}
