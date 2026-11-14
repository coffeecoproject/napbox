// 调用方要求不保留数据的销毁：删掉了不剩东西；删不掉时数据和 recycled.json 都留在 recycled 里，到期照常删。
import Foundation
import NapboxCore
@testable import NapboxRuntime
import Testing

struct StorageTests {
    /// 临时的 napbox 数据目录，里面有一个调用方持有的环境，数据卷里有一个文件
    private func storageWithEnvironment() throws -> (Storage, EnvironmentRecord, URL) {
        let root = FileManager.default.temporaryDirectory.appending(path: "nbx-storage-\(UUID().uuidString)")
        let storage = Storage(root: root)
        let record = EnvironmentRecord(name: "codeos/goal-1-work", project: nil, mainRepository: nil,
                                       worktree: "/tmp/goal-1/repo", owner: .caller(id: "codeos"))
        let file = storage.environmentDirectory(record).appending(path: "volumes/data/who")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("kept".utf8).write(to: file)
        return (storage, record, file)
    }

    private func recycledEntries(_ storage: Storage) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(at: storage.root.appending(path: "recycled"),
                                                      includingPropertiesForKeys: nil)) ?? []
    }

    @Test func discardDeletesEverything() throws {
        let (storage, record, _) = try storageWithEnvironment()
        defer { try? FileManager.default.removeItem(at: storage.root) }
        #expect(try storage.discardEnvironment(record, reason: "codeos 销毁") == nil)
        #expect(!FileManager.default.fileExists(atPath: storage.environmentDirectory(record).path))
        #expect(recycledEntries(storage).isEmpty)
    }

    @Test func discardWithoutDirectoryKeepsNothing() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "nbx-storage-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = Storage(root: root)
        let record = EnvironmentRecord(name: "codeos/never-started", project: nil, mainRepository: nil,
                                       worktree: "/tmp/never/repo", owner: .caller(id: "codeos"))
        #expect(try storage.discardEnvironment(record, reason: "codeos 销毁") == nil)
        #expect(recycledEntries(storage).isEmpty)
    }

    /// 数据卷里有删不掉的文件（加了不可更改标记）：返回 recycled 里的目录，数据和 recycled.json 都在，
    /// 环境目录已经不在原处（不会被当成还能唤醒的环境）
    @Test func discardThatCannotDeleteKeepsDataInRecycled() throws {
        let (storage, record, file) = try storageWithEnvironment()
        let moved = { (target: URL) in target.appending(path: "data/volumes/data/who") }
        var kept: URL?
        defer {
            if let kept { try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: moved(kept).path) }
            try? FileManager.default.removeItem(at: storage.root)
        }
        try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: file.path)
        kept = try storage.discardEnvironment(record, reason: "codeos 销毁")
        let target = try #require(kept)
        #expect(recycledEntries(storage).map(\.lastPathComponent) == [target.lastPathComponent])
        #expect(FileManager.default.fileExists(atPath: moved(target).path))
        #expect(FileManager.default.fileExists(atPath: target.appending(path: RecycledInfo.fileName).path))
        #expect(!FileManager.default.fileExists(atPath: storage.environmentDirectory(record).path))
        // 到期照常删（先去掉标记，模拟 7 天里文件变得能删了）
        try FileManager.default.setAttributes([.immutable: false], ofItemAtPath: moved(target).path)
        _ = storage.purgeRecycled(now: Date().addingTimeInterval(Storage.recycledKeepSeconds + 1))
        #expect(recycledEntries(storage).isEmpty)
    }
}
