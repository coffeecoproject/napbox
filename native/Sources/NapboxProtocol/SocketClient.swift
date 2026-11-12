// 连 napboxd 的同步客户端：命令行用它发请求。
import Darwin
import Foundation

public enum SocketClient {
    /// 发一个请求，等一行回应。
    public static func call(_ request: Request, socketPath: String = Paths.socket.path) throws -> Response {
        let fd = try connect(socketPath)
        defer { close(fd) }
        try writeLine(fd, try Wire.encoder.encode(request))
        var reply = Data()
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let n = read(fd, &chunk, chunk.count)
            if n < 0 {
                if errno == EINTR { continue }
                throw NapboxError(.protocolError, "读取 napboxd 回应失败：\(String(cString: strerror(errno)))")
            }
            if n == 0 { break }
            if let nl = chunk[0..<n].firstIndex(of: 0x0A) {
                reply.append(contentsOf: chunk[0..<nl])
                break
            }
            reply.append(contentsOf: chunk[0..<n])
        }
        do {
            return try Wire.decoder.decode(Response.self, from: reply)
        } catch {
            throw NapboxError(.protocolError, "napboxd 的回应不是有效的 JSON：\(error)")
        }
    }

    /// 流式方法（logs、exec）：发请求，把 output 逐条交给 onOutput，返回最后那条 result 或 error。
    /// - forwardStdin：exec 用。另起一个线程把本进程的标准输入转给 napboxd；标准输入是终端时直接告诉它
    ///   输入结束（不做交互）
    public static func stream(_ request: Request, forwardStdin: Bool, socketPath: String = Paths.socket.path,
                              onOutput: (StreamOutput) -> Void) throws -> Response {
        let fd = try connect(socketPath)
        defer { close(fd) }
        try writeLine(fd, try Wire.encoder.encode(request))
        if forwardStdin {
            // 线程用自己的副本：主线程返回后会关掉 fd，编号可能被别的文件重用
            let copy = dup(fd)
            Thread.detachNewThread { forwardStandardInput(to: copy) }
        }
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            if let nl = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<nl]
                buffer.removeSubrange(buffer.startIndex...nl)
                let response: Response
                do { response = try Wire.decoder.decode(Response.self, from: line) } catch {
                    throw NapboxError(.protocolError, "napboxd 的回应不是有效的 JSON：\(error)")
                }
                if let output = response.output {
                    onOutput(output)
                    continue
                }
                return response
            }
            let n = read(fd, &chunk, chunk.count)
            if n < 0 {
                if errno == EINTR { continue }
                throw NapboxError(.protocolError, "读取 napboxd 回应失败：\(String(cString: strerror(errno)))")
            }
            if n == 0 { throw NapboxError(.protocolError, "napboxd 没给最后的结果就断开了") }
            buffer.append(contentsOf: chunk[0..<n])
        }
    }

    private static func forwardStandardInput(to fd: Int32) {
        defer { close(fd) }
        func send(_ message: StdinMessage) -> Bool {
            guard let data = try? Wire.encoder.encode(message) else { return false }
            return (try? writeLine(fd, data)) != nil
        }
        if isatty(STDIN_FILENO) != 0 {
            _ = send(StdinMessage(end: true))
            return
        }
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let n = read(STDIN_FILENO, &chunk, chunk.count)
            if n < 0, errno == EINTR { continue }
            if n <= 0 {
                _ = send(StdinMessage(end: true))
                return
            }
            if !send(StdinMessage(data: Data(chunk[0..<n]))) { return } // napboxd 那边已经结束了
        }
    }

    static func writeLine(_ fd: Int32, _ data: Data) throws {
        var line = data
        line.append(0x0A)
        try line.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let n = Darwin.write(fd, raw.baseAddress! + offset, raw.count - offset)
                if n < 0 {
                    if errno == EINTR { continue }
                    throw NapboxError(.protocolError, "写入 napboxd 失败：\(String(cString: strerror(errno)))")
                }
                offset += n
            }
        }
    }

    static func connect(_ socketPath: String) throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw NapboxError(.daemonUnavailable, "创建 socket 失败：\(String(cString: strerror(errno)))") }
        // napboxd 中途断开时让 write 返回 EPIPE，而不是用 SIGPIPE 把命令行直接杀掉、什么都不输出。
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: addr.sun_path)
        guard socketPath.utf8.count < capacity else {
            close(fd)
            throw NapboxError(.daemonUnavailable, "socket 路径太长（\(socketPath.utf8.count) 字节，上限 \(capacity - 1)）：\(socketPath)")
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { buf in
            buf.copyBytes(from: socketPath.utf8)
            buf[socketPath.utf8.count] = 0
        }
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard rc == 0 else {
            let reason = String(cString: strerror(errno))
            close(fd)
            throw NapboxError(.daemonUnavailable, "连不上 napboxd（\(socketPath)：\(reason)）。它由 napbox setup 注册的登录项运行。")
        }
        return fd
    }
}
