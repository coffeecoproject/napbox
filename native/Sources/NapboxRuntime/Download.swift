// 可以接着下的下载（napbox setup 下载内核包和 runc 用）。国内直连 GitHub 可能只有几十 KB/s，一次下不完很常见：
// 已经下到的部分留在 partial 文件里，断了就带 Range 从断开的地方接着要，这次 setup 放弃了，下次 setup 也从这里接着下。
// 用 URLSession 的默认配置，走系统代理；GitHub 的下载会跳到另一个签了名的地址，每次都从原地址重新要，不存跳转后的地址。
import Foundation
import NapboxProtocol

enum Download {
    /// 连着失败、中间一个字节都没收到时，每次等多久再试；用完就放弃。收到过数据就从头算
    static let retryDelays: [Duration] = [.seconds(2), .seconds(4), .seconds(8), .seconds(15), .seconds(30)]
    /// 这么久收不到数据算一次失败（交给重试）；总时长不限
    static let idleTimeout: TimeInterval = 60

    /// 把 url 的内容接着下到 partial 里。返回时 partial 是完整的内容，还没校验，校验由调用方做。
    /// 放弃时 partial 留着。
    static func resume(_ url: URL, into partial: URL, label: String, retryDelays: [Duration] = retryDelays,
                       idleTimeout: TimeInterval = idleTimeout, log: @Sendable @escaping (String) -> Void) async throws(NapboxError) {
        var failures = 0
        let existing = size(of: partial)
        if existing > 0 { log("\(label)：接着上次没下完的下，已有 \(megabytes(existing))") }
        while true {
            let before = size(of: partial)
            let outcome: Transfer.Outcome
            do {
                outcome = try await Transfer.run(url, into: partial, offset: before, idleTimeout: idleTimeout, label: label, log: log)
            } catch {
                throw NapboxError(.runtimeUnavailable, "下载失败（\(label)）：\(error.localizedDescription)")
            }
            switch outcome {
            case .complete:
                return
            case .fatal(let reason):
                throw NapboxError(.runtimeUnavailable, "下载失败（\(label)）：\(reason)")
            case .interrupted(let reason):
                let after = size(of: partial)
                if after > before { failures = 0 }
                guard failures < retryDelays.count else {
                    throw NapboxError(.runtimeUnavailable,
                                      "下载失败（\(label)）：\(reason)。已下 \(megabytes(after))，留在 \(partial.path)，再运行一次 napbox setup 会接着下")
                }
                let delay = retryDelays[failures]
                failures += 1
                log("\(label)：下载中断（\(reason)），已下 \(megabytes(after))，\(delay.components.seconds) 秒后接着下")
                try? await Task.sleep(for: delay)
            }
        }
    }

    static func size(of file: URL) -> Int64 {
        ((try? FileManager.default.attributesOfItem(atPath: file.path))?[.size] as? NSNumber)?.int64Value ?? 0
    }

    static func megabytes(_ bytes: Int64) -> String {
        bytes < 1_048_576 ? "\(bytes / 1024)KB" : String(format: "%.1fMB", Double(bytes) / 1_048_576)
    }
}

/// 进度每过 5% 报一行
struct ProgressSteps {
    var total: Int64 = 0
    var received: Int64 = 0
    private var reported = -1

    /// 过了新的 5% 时返回要报的一行。第一次只记下起点：接着下时不从 0% 报起
    mutating func next() -> String? {
        guard total > 0 else { return nil }
        let step = Int(min(received, total) * 20 / total)
        guard step > reported else { return nil }
        defer { reported = step }
        return reported < 0 ? nil : "已下 \(step * 5)%（\(Download.megabytes(received)) / \(Download.megabytes(total))）"
    }
}

/// 一次请求：从 offset 开始要，收到的写进 partial。URLSession 的回调在它自己的串行队列上，状态只在回调里改。
private final class Transfer: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    enum Outcome {
        case complete
        /// 网络断了、超时、服务器 5xx 之类，可以接着下
        case interrupted(String)
        /// 重试也没用的，比如 404
        case fatal(String)
    }

    private let offset: Int64
    private let label: String
    private let log: @Sendable (String) -> Void
    private let handle: FileHandle
    private var continuation: CheckedContinuation<Outcome, Never>?
    /// 收到响应之前就定下的结果（不用这次的内容），完成时用它
    private var decided: Outcome?
    private var writeError: Error?
    /// 整个文件的大小（知道的话）和已有的字节数
    private var total: Int64?
    private var received: Int64
    private var steps = ProgressSteps()

    static func run(_ url: URL, into partial: URL, offset: Int64, idleTimeout: TimeInterval, label: String,
                    log: @Sendable @escaping (String) -> Void) async throws -> Outcome {
        if !FileManager.default.fileExists(atPath: partial.path) {
            guard FileManager.default.createFile(atPath: partial.path, contents: nil) else {
                throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: partial.path])
            }
        }
        let handle = try FileHandle(forWritingTo: partial)
        defer { try? handle.close() }
        try handle.seekToEnd()
        let transfer = Transfer(offset: offset, handle: handle, label: label, log: log)
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = idleTimeout
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        let session = URLSession(configuration: configuration, delegate: transfer, delegateQueue: nil)
        // session 一直拿着 delegate，用完要放开
        defer { session.finishTasksAndInvalidate() }
        var request = URLRequest(url: url)
        if offset > 0 { request.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range") }
        return await withCheckedContinuation { continuation in
            transfer.continuation = continuation
            session.dataTask(with: request).resume()
        }
    }

    private init(offset: Int64, handle: FileHandle, label: String, log: @Sendable @escaping (String) -> Void) {
        self.offset = offset
        self.handle = handle
        self.label = label
        self.log = log
        received = offset
    }

    /// 跳转后还要带着 Range
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        var next = request
        if let range = task.originalRequest?.value(forHTTPHeaderField: "Range") {
            next.setValue(range, forHTTPHeaderField: "Range")
        }
        completionHandler(next)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse else {
            decided = .fatal("不是 HTTP 的回应")
            return completionHandler(.cancel)
        }
        switch http.statusCode {
        case 206:
            // Content-Range: bytes <start>-<end>/<total>
            let range = http.value(forHTTPHeaderField: "Content-Range") ?? ""
            let numbers = range.split(whereSeparator: { !$0.isNumber }).compactMap { Int64($0) }
            guard numbers.count == 3, numbers[0] == offset else {
                // 对不上就清掉从头下：不拼接来历不明的内容
                truncate()
                decided = .interrupted("服务器给的范围（\(range)）和已有的 \(offset) 字节接不上，从头下")
                return completionHandler(.cancel)
            }
            total = numbers[2]
        case 200:
            // 服务器不认 Range，给的是整个文件：从头写
            if offset > 0 { log("\(label)：服务器不支持接着下，从头下") }
            truncate()
            total = http.expectedContentLength >= 0 ? http.expectedContentLength : nil
        case 416:
            // 要的范围超出文件末尾：已有的就是全部，校验时见分晓
            decided = .complete
            return completionHandler(.cancel)
        case 408, 429, 500...599:
            decided = .interrupted("HTTP \(http.statusCode)")
            return completionHandler(.cancel)
        default:
            decided = .fatal("HTTP \(http.statusCode)")
            return completionHandler(.cancel)
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard writeError == nil else { return }
        do {
            try handle.write(contentsOf: data)
        } catch {
            writeError = error
            dataTask.cancel()
            return
        }
        received += Int64(data.count)
        steps.total = total ?? 0
        steps.received = received
        if let line = steps.next() { log("\(label)：\(line)") }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let outcome: Outcome
        if let decided {
            outcome = decided
        } else if let writeError {
            outcome = .fatal("写不了下载的文件：\(writeError.localizedDescription)")
        } else if let error {
            outcome = .interrupted(error.localizedDescription)
        } else if let total, received < total {
            outcome = .interrupted("连接提前结束")
        } else {
            outcome = .complete
        }
        continuation?.resume(returning: outcome)
        continuation = nil
    }

    private func truncate() {
        do {
            try handle.truncate(atOffset: 0)
            received = 0
        } catch {
            writeError = error
        }
    }
}
