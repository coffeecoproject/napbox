// 运行宿主机上的命令（git、arp、docker）：等它结束，拿到退出码和输出。
import Foundation

public enum Subprocess {
    public struct Output: Sendable {
        public var status: Int32
        public var stdout: Data
        public var stderr: Data

        public var stderrText: String { String(decoding: stderr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    /// 运行不了（比如程序不存在）时抛出 Foundation 的错误。
    /// - captureStdout：false 时标准输出丢掉（docker save 的输出很大又用不着）
    public static func run(_ executable: String, _ arguments: [String], captureStdout: Bool = true) throws -> Output {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let out = Pipe(), err = Pipe()
        process.standardOutput = captureStdout ? out : FileHandle.nullDevice
        process.standardError = err
        try process.run()
        // 两个管道在这条线程上一起读：
        // - 先读完一个再读另一个的话，命令往另一个写满管道缓冲（64KB）时双方互相等着
        // - 另要一条公用线程来读的话，公用线程全被等着命令的调用占满时（同一时刻上百个请求各问一次 git）谁也等不到，永远卡住
        let data = readToEnd(captureStdout ? [err.fileHandleForReading, out.fileHandleForReading] : [err.fileHandleForReading])
        process.waitUntilExit()
        return Output(status: process.terminationStatus, stdout: captureStdout ? data[1] : Data(), stderr: data[0])
    }

    /// 几个管道一起读，各自读到对面关掉为止
    private static func readToEnd(_ handles: [FileHandle]) -> [Data] {
        var data = handles.map { _ in Data() }
        var polls = handles.map { pollfd(fd: $0.fileDescriptor, events: Int16(POLLIN), revents: 0) }
        let size = 65536
        var buffer = [UInt8](repeating: 0, count: size)
        var open = handles.count
        while open > 0 {
            if poll(&polls, nfds_t(polls.count), -1) < 0 {
                if errno == EINTR { continue }
                break
            }
            for index in polls.indices where polls[index].revents != 0 {
                let count = read(polls[index].fd, &buffer, size)
                if count > 0 {
                    data[index].append(buffer, count: count)
                } else if count == 0 || errno != EINTR {
                    polls[index].fd = -1 // 读完了：poll 不看负的描述符
                    open -= 1
                }
            }
        }
        return data
    }
}
