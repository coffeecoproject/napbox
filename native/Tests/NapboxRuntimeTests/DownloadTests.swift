// setup 下载内核包和 runc：断了从断开的地方接着下、卡住了算一次失败、服务器不认 Range 时从头下、
// 跳转后还带着 Range、404 不重试、一直失败就放弃但已下的留着；校验不对删掉；给了本地文件就不下载。
// 用本机的一个小 HTTP 服务模拟，每个请求怎么回由测试决定。
import CryptoKit
import Foundation
import NapboxProtocol
@testable import NapboxRuntime
import Synchronization
import Testing

@Suite struct DownloadTests {
    private static let content = Data((0..<300_000).map { _ in UInt8.random(in: 0...255) })
    private static let fast: [Duration] = [.milliseconds(10), .milliseconds(10)]

    private func scratch() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appending(path: "nbx-download-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    @Test func resumesAfterConnectionDrops() async throws {
        let directory = try scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let server = try TestServer { index, request, connection in
            if index == 0 {
                // 说好整个文件，只给 100000 字节就断
                connection.send(TestServer.head(200, length: Self.content.count))
                connection.send(Self.content.prefix(100_000))
            } else {
                connection.respond(range: request.range, of: Self.content)
            }
        }
        let partial = directory.appending(path: ".file.partial")
        try await Download.resume(server.url("/file"), into: partial, label: "测试", retryDelays: Self.fast) { _ in }
        #expect(try Data(contentsOf: partial) == Self.content)
        #expect(server.requests.map(\.range) == [nil, "bytes=100000-"])
    }

    @Test func stallCountsAsFailureAndResumes() async throws {
        let directory = try scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let server = try TestServer { index, request, connection in
            if index == 0 {
                connection.send(TestServer.head(200, length: Self.content.count))
                connection.send(Self.content.prefix(50_000))
                // 连接开着，不再给数据
                Thread.sleep(forTimeInterval: 5)
            } else {
                connection.respond(range: request.range, of: Self.content)
            }
        }
        let partial = directory.appending(path: ".file.partial")
        try await Download.resume(server.url("/file"), into: partial, label: "测试", retryDelays: Self.fast, idleTimeout: 1) { _ in }
        #expect(try Data(contentsOf: partial) == Self.content)
        #expect(server.requests.map(\.range) == [nil, "bytes=50000-"])
    }

    @Test func restartsWhenServerIgnoresRange() async throws {
        let directory = try scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let partial = directory.appending(path: ".file.partial")
        try Data(repeating: 7, count: 1000).write(to: partial)
        let server = try TestServer { _, _, connection in
            connection.send(TestServer.head(200, length: Self.content.count))
            connection.send(Self.content)
        }
        try await Download.resume(server.url("/file"), into: partial, label: "测试", retryDelays: Self.fast) { _ in }
        #expect(try Data(contentsOf: partial) == Self.content)
        #expect(server.requests.map(\.range) == ["bytes=1000-"])
    }

    /// GitHub 的下载先跳到另一个地址：跳过去的那次也要带 Range
    @Test func keepsRangeAcrossRedirect() async throws {
        let directory = try scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let partial = directory.appending(path: ".file.partial")
        try Self.content.prefix(120_000).write(to: partial)
        let server = try TestServer { _, request, connection in
            if request.path == "/release" {
                connection.send(Data("HTTP/1.1 302 Found\r\nLocation: /asset\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8))
            } else {
                connection.respond(range: request.range, of: Self.content)
            }
        }
        try await Download.resume(server.url("/release"), into: partial, label: "测试", retryDelays: Self.fast) { _ in }
        #expect(try Data(contentsOf: partial) == Self.content)
        #expect(server.requests.map { "\($0.path) \($0.range ?? "-")" } == ["/release bytes=120000-", "/asset bytes=120000-"])
    }

    @Test func alreadyCompleteIsAccepted() async throws {
        let directory = try scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let partial = directory.appending(path: ".file.partial")
        try Self.content.write(to: partial)
        let server = try TestServer { _, request, connection in connection.respond(range: request.range, of: Self.content) }
        try await Download.resume(server.url("/file"), into: partial, label: "测试", retryDelays: Self.fast) { _ in }
        #expect(try Data(contentsOf: partial) == Self.content)
    }

    @Test func notFoundIsNotRetried() async throws {
        let directory = try scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let server = try TestServer { _, _, connection in connection.send(TestServer.head(404, length: 0)) }
        let partial = directory.appending(path: ".file.partial")
        let error = await #expect(throws: NapboxError.self) {
            try await Download.resume(server.url("/file"), into: partial, label: "测试", retryDelays: Self.fast) { _ in }
        }
        #expect(error?.message.contains("HTTP 404") == true)
        #expect(server.requests.count == 1)
    }

    /// 连着几次一个字节都没收到就放弃；中间收到过的留着，下次接着下
    @Test func givesUpButKeepsWhatItHas() async throws {
        let directory = try scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let server = try TestServer { index, request, connection in
            if index == 0 {
                connection.send(TestServer.head(200, length: Self.content.count))
                connection.send(Self.content.prefix(10_000))
            } else {
                connection.send(TestServer.head(503, length: 0))
            }
        }
        let partial = directory.appending(path: ".file.partial")
        let error = await #expect(throws: NapboxError.self) {
            try await Download.resume(server.url("/file"), into: partial, label: "测试", retryDelays: Self.fast) { _ in }
        }
        #expect(error?.message.contains("接着下") == true)
        // 第一次收到了数据，不算连着失败；之后 503：重试两次都没数据，放弃
        #expect(server.requests.map(\.range) == [nil, "bytes=10000-", "bytes=10000-"])
        #expect(try Data(contentsOf: partial) == Self.content.prefix(10_000))
    }

    @Test func obtainDeletesMismatchedDownload() async throws {
        let directory = try scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let server = try TestServer { _, request, connection in connection.respond(range: request.range, of: Self.content) }
        let partial = directory.appending(path: ".file-2.partial")
        // 旧版本没下完的顺手删掉
        let stale = directory.appending(path: ".file-1.partial")
        try Data([1]).write(to: stale)
        let error = await #expect(throws: NapboxError.self) {
            _ = try await Prepare.obtain(server.url("/file"), sha256: String(repeating: "0", count: 64), variable: "NAPBOX_TEST_NONE",
                                         partial: partial, label: "测试", size: "", environment: [:]) { _ in }
        }
        #expect(error?.message.contains("校验值不对") == true)
        #expect(!FileManager.default.fileExists(atPath: partial.path))
        #expect(!FileManager.default.fileExists(atPath: stale.path))
    }

    @Test func obtainUsesGivenFileWithoutDownloading() async throws {
        let directory = try scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let given = directory.appending(path: "given")
        try Self.content.write(to: given)
        let digest = SHA256.hash(data: Self.content).map { String(format: "%02x", $0) }.joined()
        let nowhere = URL(string: "http://127.0.0.1:9/file")!
        let partial = directory.appending(path: ".file.partial")
        let file = try await Prepare.obtain(nowhere, sha256: digest, variable: "NAPBOX_X", partial: partial, label: "测试", size: "",
                                            environment: ["NAPBOX_X": given.path]) { _ in }
        #expect(file == given)

        let error = await #expect(throws: NapboxError.self) {
            _ = try await Prepare.obtain(nowhere, sha256: String(repeating: "0", count: 64), variable: "NAPBOX_X", partial: partial,
                                         label: "测试", size: "", environment: ["NAPBOX_X": given.path]) { _ in }
        }
        #expect(error?.message.contains("NAPBOX_X") == true)
    }
}

/// 本机的小 HTTP 服务：一个连接一个请求，回完就关。handler 收到第几个请求、请求本身和连接，自己写回应
private final class TestServer: Sendable {
    struct Request: Sendable {
        var path: String
        var range: String?
    }

    final class Connection {
        let fd: Int32
        init(fd: Int32) { self.fd = fd }

        func send(_ data: Data) {
            data.withUnsafeBytes { buffer in
                var offset = 0
                while offset < buffer.count {
                    let written = write(fd, buffer.baseAddress! + offset, buffer.count - offset)
                    if written <= 0 { return }
                    offset += written
                }
            }
        }

        /// 按 Range 回 206，没有 Range 回 200；范围超出末尾回 416
        func respond(range: String?, of content: Data) {
            guard let range, let start = Int(range.dropFirst("bytes=".count).prefix { $0.isNumber }) else {
                send(TestServer.head(200, length: content.count))
                return send(content)
            }
            guard start < content.count else {
                return send(Data("HTTP/1.1 416 Range Not Satisfiable\r\nContent-Range: bytes */\(content.count)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8))
            }
            send(Data("HTTP/1.1 206 Partial Content\r\nContent-Range: bytes \(start)-\(content.count - 1)/\(content.count)\r\nContent-Length: \(content.count - start)\r\nConnection: close\r\n\r\n".utf8))
            send(content.subdata(in: start..<content.count))
        }
    }

    static func head(_ status: Int, length: Int) -> Data {
        Data("HTTP/1.1 \(status) X\r\nContent-Length: \(length)\r\nConnection: close\r\n\r\n".utf8)
    }

    private let listener: Int32
    let port: UInt16
    private final class Received: Sendable {
        let list = Mutex<[Request]>([])
    }

    private let received = Received()
    var requests: [Request] { received.list.withLock { $0 } }

    init(handler: @escaping @Sendable (Int, Request, Connection) -> Void) throws {
        let listener = socket(AF_INET, SOCK_STREAM, 0)
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = 0
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listener, $0, length) == 0 && getsockname(listener, $0, &length) == 0 }
        }
        guard bound, listen(listener, 16) == 0 else {
            close(listener)
            throw POSIXError(.EADDRINUSE)
        }
        self.listener = listener
        port = UInt16(bigEndian: address.sin_port)
        let received = received
        Thread.detachNewThread {
            while true {
                let fd = accept(listener, nil, nil)
                if fd < 0 { return }
                var noSigpipe: Int32 = 1
                setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigpipe, socklen_t(MemoryLayout<Int32>.size))
                let request = Self.readRequest(fd)
                let index = received.list.withLock { list in
                    list.append(request)
                    return list.count - 1
                }
                Thread.detachNewThread {
                    handler(index, request, Connection(fd: fd))
                    close(fd)
                }
            }
        }
    }

    deinit { close(listener) }

    func url(_ path: String) -> URL { URL(string: "http://127.0.0.1:\(port)\(path)")! }

    private static func readRequest(_ fd: Int32) -> Request {
        var bytes = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while !bytes.contains("\r\n\r\n".data(using: .utf8)!) {
            let count = read(fd, &buffer, buffer.count)
            if count <= 0 { break }
            bytes.append(contentsOf: buffer[0..<count])
        }
        let lines = String(decoding: bytes, as: UTF8.self).components(separatedBy: "\r\n")
        let path = lines.first?.split(separator: " ").dropFirst().first.map(String.init) ?? ""
        let range = lines.first { $0.lowercased().hasPrefix("range:") }.map { $0.dropFirst("range:".count).trimmingCharacters(in: .whitespaces) }
        return Request(path: path, range: range)
    }
}
