// 流式方法 logs、exec、run、subscribe：一个连接一个请求，先发若干条 output（subscribe 是 event），最后一条是 result 或 error
// （Protocol.swift）。
// 收发都在 Daemon 之外做，不占着它；Daemon 只负责找环境、唤醒、占住环境不让它闲置休眠。
import Foundation
import NIOConcurrencyHelpers
import NIOCore
import NapboxCore
import NapboxProtocol
import NapboxRuntime

enum Streams {
    typealias Output = NIOAsyncChannelOutboundWriter<ByteBuffer>

    /// - input：这个连接上之后收到的每一行（exec、run 的标准输入）；结束表示命令行断开了
    static func handle(_ request: Request, daemon: Daemon, input: AsyncStream<Data>, output: Output) async {
        let final = await Requests.respond(to: request) {
            switch request.method {
            case Method.logs:
                return try Wire.value(try await logs(try Requests.params(LogsParams.self, request), request.id, daemon, input, output))
            case Method.exec:
                return try Wire.value(try await exec(try Requests.params(ExecParams.self, request), request.id, daemon, input, output))
            case Method.run:
                return try Wire.value(try await run(try Requests.params(RunParams.self, request), request.id, daemon, input, output))
            case Method.subscribe:
                await subscribe(try Requests.params(SubscribeParams.self, request), request.id, daemon, input, output)
                return .object([:])
            default:
                throw Requests.unknownMethod(request)
            }
        }
        try? await send(final, to: output)
    }

    static func send(_ response: Response, to output: Output) async throws {
        var data = try Wire.encoder.encode(response)
        data.append(0x0A)
        try await output.write(ByteBuffer(bytes: data))
    }

    // MARK: - logs

    /// 先输出最后 tail 行（nil 是全部）；follow 时接着每 0.2 秒看一次有没有新内容，直到命令行断开或环境回收。
    /// follow 期间占住环境，不让它闲置休眠；环境在休眠时不唤醒它，只是等着。
    private static func logs(_ params: LogsParams, _ id: Int, _ daemon: Daemon, _ input: AsyncStream<Data>,
                             _ output: Output) async throws(NapboxError) -> LogsResult {
        let target = try await daemon.logsTarget(params.target, service: params.service)
        var offset = params.tail.map { LogReader.startOffset(of: target.file, lastLines: $0) } ?? 0
        guard await copy(target.file, from: &offset, upTo: LogReader.size(of: target.file), id, output) else { return LogsResult() }
        guard params.follow else { return LogsResult() }

        daemon.hold(target.name)
        defer { daemon.release(target.name) }
        let disconnected = NIOLockedValueBox(false)
        let watcher = Task {
            for await _ in input {}
            disconnected.withLockedValue { $0 = true }
        }
        defer { watcher.cancel() }
        while !disconnected.withLockedValue({ $0 }) {
            try? await Task.sleep(nanoseconds: 200_000_000)
            guard await daemon.isRegistered(target.name) else { return LogsResult(ended: "环境 \(target.name) 回收了") }
            let size = LogReader.size(of: target.file)
            if size < offset { offset = 0 } // 文件被换掉了（重建了环境目录）
            guard await copy(target.file, from: &offset, upTo: size, id, output) else { break }
        }
        return LogsResult() // 命令行断开了，这条结果也送不到
    }

    /// 把文件 offset 到 end 的内容分块发出去，返回是否都发出去了（命令行断开时发不出去）
    private static func copy(_ file: URL, from offset: inout UInt64, upTo end: UInt64, _ id: Int, _ output: Output) async -> Bool {
        while offset < end, let data = LogReader.read(file, from: offset, upTo: end), !data.isEmpty {
            do {
                try await send(Response(id: id, output: StreamOutput(stream: .stdout, data: data)), to: output)
            } catch {
                return false
            }
            offset += UInt64(data.count)
        }
        return true
    }

    // MARK: - exec

    /// 在服务里执行命令，输出原样转回去，标准输入从命令行转过来。命令行断开时结束这条命令。
    private static func exec(_ params: ExecParams, _ id: Int, _ daemon: Daemon, _ input: AsyncStream<Data>,
                             _ output: Output) async throws(NapboxError) -> ExecResult {
        guard !params.command.isEmpty else { throw NapboxError(.badRequest, "exec 要给出命令：napbox exec <服务> -- <命令>") }
        let (name, env) = try await daemon.execTarget(params.target, service: params.service)
        defer { daemon.release(name) }
        if let t = params.timeoutSeconds, t <= 0 { throw NapboxError(.badRequest, "timeoutSeconds 要大于 0") }
        return try await attached(id, input, output) { (stdin, buffer) throws(NapboxError) in
            try await env.exec(params.service, params.command, stdin: stdin, timeout: params.timeoutSeconds.map(Int64.init), output: buffer)
        }
    }

    // MARK: - run

    /// 起一个临时环境，在前台跑其中一个服务：输出原样转回去，标准输入从命令行转过来，跑完（或命令行断开）环境销毁。
    private static func run(_ params: RunParams, _ id: Int, _ daemon: Daemon, _ input: AsyncStream<Data>,
                            _ output: Output) async throws(NapboxError) -> ExecResult {
        guard !params.service.isEmpty else { throw NapboxError(.badRequest, "run 要给出服务名：napbox run <服务>") }
        return try await attached(id, input, output) { (stdin, buffer) throws(NapboxError) in
            ExecResult(exitCode: try await daemon.run(params, stdin: stdin, output: buffer))
        }
    }

    /// exec、run 共用：把命令行接到一条在跑的命令上，等它结束，返回结果。
    /// - body：跑那条命令。拿到的是命令行转过来的标准输入和放输出的缓冲；命令行断开时它所在的任务被取消
    private static func attached(
        _ id: Int, _ input: AsyncStream<Data>, _ output: Output,
        _ body: @escaping @Sendable (AsyncStream<Data>, ExecOutput) async throws(NapboxError) -> ExecResult
    ) async throws(NapboxError) -> ExecResult {
        // 命令的输出排进有上限的缓冲，由一个任务发给命令行。命令行读得慢时发送就慢，缓冲满了命令就等着
        let buffer = ExecOutput()
        let sender = Task {
            for await chunk in buffer.chunks {
                try? await send(Response(id: id, output: chunk), to: output)
                buffer.sent(chunk)
            }
        }
        let (stdin, feed) = AsyncStream.makeStream(of: Data.self)
        let run = Task { () async -> Result<ExecResult, NapboxError> in
            do throws(NapboxError) {
                return .success(try await body(stdin, buffer))
            } catch {
                return .failure(error)
            }
        }
        let relay = Task {
            for await line in input {
                guard let message = try? Wire.decoder.decode(StdinMessage.self, from: line) else { continue }
                if let data = message.data { feed.yield(data) }
                if message.end == true { feed.finish() }
            }
            // 命令行断开了：命令还在跑就结束它
            feed.finish()
            run.cancel()
        }
        defer { relay.cancel() }
        let result = await run.value
        buffer.close()
        await sender.value
        return try result.get()
    }

    // MARK: - subscribe

    /// 按条件一条一条推事件，直到调用方断开。napboxd 退出时连接直接断开。断开期间的事件不补发（EventHub）。
    private static func subscribe(_ params: SubscribeParams, _ id: Int, _ daemon: Daemon, _ input: AsyncStream<Data>, _ output: Output) async {
        let (subscription, events) = daemon.events.subscribe(params)
        let watcher = Task {
            for await _ in input {}
            daemon.events.unsubscribe(subscription)
        }
        defer {
            watcher.cancel()
            daemon.events.unsubscribe(subscription)
        }
        do {
            try await send(Response(id: id, subscribed: true), to: output)
            for await event in events { try await send(Response(id: id, event: event), to: output) }
        } catch {
            return // 发不出去：调用方断开了
        }
    }
}
