import Foundation
import NapboxRuntime
import Testing

@Suite struct SourceEventStreamTests {
    private final class Record: @unchecked Sendable {
        private let lock = NSLock()
        private var droppedPaths: [String] = []
        private var changedCount = 0

        func changed(_ paths: [String]) { lock.withLock { changedCount += paths.count } }
        func dropped(_ paths: [String]) { lock.withLock { droppedPaths += paths } }
        var snapshot: (dropped: [String], changed: Int) { lock.withLock { (droppedPaths, changedCount) } }
    }

    /// 真的 FSEvents：这边接得慢（每批停 0.3 秒），一下子写 2000 个文件，系统会丢掉后面的事件，
    /// 并在监听的目录上报一条“丢了事件、自己重扫”。这条要交给 onDropped，不能当成普通的一条变化混过去。
    @Test func slowReceiverIsToldEventsWereDropped() async throws {
        let directory = realDirectory(FileManager.default.temporaryDirectory.appendingPathComponent("nbx-fsevents-\(UUID().uuidString)").path)
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: directory) }

        let record = Record()
        let stream = try SourceEventStream(
            directories: [directory],
            onChange: { paths in
                record.changed(paths)
                Thread.sleep(forTimeInterval: 0.3)
            },
            onDropped: { record.dropped($0) }
        )
        defer { stream.stop() }
        try await Task.sleep(for: .milliseconds(500))

        for i in 0..<2000 { try Data("\(i)\n".utf8).write(to: URL(fileURLWithPath: "\(directory)/f\(i).txt")) }

        let deadline = Date().addingTimeInterval(30)
        while record.snapshot.dropped.isEmpty, Date() < deadline { try await Task.sleep(for: .milliseconds(200)) }
        let result = record.snapshot
        #expect(result.dropped == [directory], "收到 \(result.changed) 条变化，没有收到“丢了事件”")
    }
}
