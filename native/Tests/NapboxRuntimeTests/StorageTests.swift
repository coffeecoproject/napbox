// 回收时数据怎么移到 recycled：recycled.json 先写好，数据最后一步改名移过去。
// 调用方要求不保留数据的销毁：删掉了不剩东西；删不掉时数据和 recycled.json 都留在 recycled 里，到期照常删。
import Foundation
import NapboxCore
import NapboxProtocol
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

    @Test func recycleMovesDirectoryWithInfo() throws {
        let (storage, record, _) = try storageWithEnvironment()
        defer { try? FileManager.default.removeItem(at: storage.root) }
        let target = try #require(try storage.recycleEnvironment(record, reason: "napbox down"))
        #expect(FileManager.default.fileExists(atPath: target.appending(path: "volumes/data/who").path))
        #expect(FileManager.default.fileExists(atPath: target.appending(path: RecycledInfo.fileName).path))
        #expect(!FileManager.default.fileExists(atPath: storage.environmentDirectory(record).path))
        // 已经移走了（上次做到一半）：没东西可移
        #expect(try storage.recycleEnvironment(record, reason: "napbox down") == nil)
    }

    /// 移不过去（recycled 不让写）：数据原样留在环境目录里，里面也不留 recycled.json
    @Test func recycleThatCannotMoveLeavesDirectoryAsIs() throws {
        let (storage, record, file) = try storageWithEnvironment()
        let recycled = storage.root.appending(path: "recycled")
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: recycled.path)
            try? FileManager.default.removeItem(at: storage.root)
        }
        try FileManager.default.createDirectory(at: recycled, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: recycled.path)
        #expect(throws: NapboxError.self) { try storage.recycleEnvironment(record, reason: "napbox down") }
        #expect(FileManager.default.fileExists(atPath: file.path))
        #expect(!FileManager.default.fileExists(atPath: storage.environmentDirectory(record).appending(path: RecycledInfo.fileName).path))
    }

    /// reset 移走一个卷：recycled 里有卷和 recycled.json；卷已经移走了时没东西可移
    @Test func recycleVolumeMovesWithInfo() throws {
        let (storage, record, _) = try storageWithEnvironment()
        defer { try? FileManager.default.removeItem(at: storage.root) }
        let volume = storage.environmentDirectory(record).appending(path: EnvironmentLayout.volumePath("pg"))
        try FileManager.default.createDirectory(at: volume.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("ext4".utf8).write(to: volume)
        let target = try #require(try storage.recycleVolume(record, volume: "pg", reason: "napbox reset pg"))
        #expect(FileManager.default.fileExists(atPath: target.appending(path: EnvironmentLayout.volumePath("pg")).path))
        #expect(FileManager.default.fileExists(atPath: target.appending(path: RecycledInfo.fileName).path))
        #expect(!FileManager.default.fileExists(atPath: volume.path))
        #expect(try storage.recycleVolume(record, volume: "pg", reason: "napbox reset pg") == nil)
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

    /// discard 删到一半 napboxd 被杀：数据已经在 recycled/<ID>-<时间>/data。重启后接着 discard，原位没有数据，
    /// 把那份删掉；别的环境的、down 回收的（没有 data 这一层）不动
    @Test func discardFinishesInterruptedDiscard() throws {
        let (storage, record, _) = try storageWithEnvironment()
        defer { try? FileManager.default.removeItem(at: storage.root) }
        let fm = FileManager.default
        let recycled = storage.root.appending(path: "recycled")
        func leftover(_ dir: String, name: String, data: Bool) throws {
            let target = recycled.appending(path: dir)
            try fm.createDirectory(at: target.appending(path: data ? "data/volumes" : "volumes"), withIntermediateDirectories: true)
            let info = RecycledInfo(name: name, worktree: "/w", recycledAt: Date(), reason: "codeos 销毁")
            try DiskJSON.encoder.encode(info).write(to: target.appending(path: RecycledInfo.fileName))
        }
        // 模拟上次：环境目录已经移进 recycled/<ID>-half/data、还没删
        let half = recycled.appending(path: "\(record.id)-half")
        try fm.createDirectory(at: half, withIntermediateDirectories: true)
        try fm.moveItem(at: storage.environmentDirectory(record), to: half.appending(path: "data"))
        try DiskJSON.encoder.encode(RecycledInfo(name: record.name, worktree: record.worktree, recycledAt: Date(), reason: "codeos 销毁"))
            .write(to: half.appending(path: RecycledInfo.fileName))
        try leftover("\(record.id)-downed", name: record.name, data: false)
        try leftover("ffff-other", name: "codeos/other", data: true)

        #expect(try storage.discardEnvironment(record, reason: "codeos 销毁") == nil)
        #expect(!fm.fileExists(atPath: half.path))
        #expect(Set(recycledEntries(storage).map(\.lastPathComponent)) == ["\(record.id)-downed", "ffff-other"])
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
