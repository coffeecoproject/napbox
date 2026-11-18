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
                                       worktree: "/tmp/goal-1/repo", owner: .caller(id: "codeos"), hostname: "x.localhost")
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
                                       worktree: "/tmp/never/repo", owner: .caller(id: "codeos"), hostname: "x.localhost")
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

/// 数据快照（x-napbox.seed）：拍快照、从快照复制到别的环境、换进卷里，中途停下能接着做
struct SnapshotTests {
    private let fm = FileManager.default

    private func project(seed: [String]) throws -> ComposeProject {
        let dir = fm.temporaryDirectory.appending(path: "nbx-compose-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        let file = dir.appending(path: "compose.yaml")
        try Data("""
        x-napbox: {seed: [\(seed.joined(separator: ", "))]}
        services:
          db: {image: "postgres:17", volumes: ["pg:/data", "s3:/s3"]}
        volumes: {pg: {}, s3: {}}
        """.utf8).write(to: file)
        return try ComposeLoader.load(ComposeInput(files: [file], callerEnvironment: [:], profiles: []))
    }

    private func setUp() throws -> (Storage, main: EnvironmentRecord, branch: EnvironmentRecord) {
        let root = fm.temporaryDirectory.appending(path: "nbx-snapshot-\(UUID().uuidString)")
        let storage = Storage(root: root)
        let main = EnvironmentRecord(name: "p/main", project: "p", mainRepository: "/r/p", worktree: "/r/p", owner: .worktree, hostname: "x.localhost")
        let branch = EnvironmentRecord(name: "p/b", project: "p", mainRepository: "/r/p", worktree: "/r/p/.wt/b", owner: .worktree, hostname: "x.localhost")
        return (storage, main, branch)
    }

    private func write(_ storage: Storage, _ record: EnvironmentRecord, volume: String, _ text: String) throws {
        let url = storage.environmentDirectory(record).appending(path: EnvironmentLayout.volumePath(volume))
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    private func read(_ storage: Storage, _ record: EnvironmentRecord, volume: String) -> String? {
        let url = storage.environmentDirectory(record).appending(path: EnvironmentLayout.volumePath(volume))
        return fm.contents(atPath: url.path).map { String(decoding: $0, as: UTF8.self) }
    }

    /// 源环境最近一次停下没拍成：snapshot_not_found 带上原因，提示先处理再拍；没记原因时照旧
    @Test func skipReasonInNotFound() throws {
        let (storage, main, branch) = try setUp()
        defer { try? fm.removeItem(at: storage.root) }
        var skipped = main
        skipped.snapshotSkipped = .init(at: Date(timeIntervalSince1970: 0), reason: "storage（等了 10 秒）过了 stop_grace_period 还没退出")
        do {
            _ = try storage.stageSeed(from: skipped, to: branch.id, volumes: ["pg"])
            Issue.record("没有快照应该报错")
        } catch {
            #expect(error.code == "snapshot_not_found")
            #expect(error.message.contains("最近一次停下（1970-01-01T00:00:00Z）没拍成快照：storage（等了 10 秒）过了 stop_grace_period 还没退出。"))
            #expect(error.message.contains("按上面的原因处理好，再拍：在那边 napbox sleep 一次"))
        }
        do {
            _ = try storage.stageSeed(from: main, to: branch.id, volumes: ["pg"])
            Issue.record("没有快照应该报错")
        } catch {
            #expect(!error.message.contains("没拍成"))
            #expect(error.message.contains("要现在拍：在那边 napbox sleep 一次"))
        }
        // 有快照但缺卷：也带上原因
        try write(storage, main, volume: "pg", "v1")
        _ = try storage.takeSnapshot(main, project: try project(seed: ["pg"]))
        do {
            _ = try storage.stageSeed(from: skipped, to: branch.id, volumes: ["pg", "s3"])
            Issue.record("缺卷应该报错")
        } catch {
            #expect(error.message.contains("里没有 s3"))
            #expect(error.message.contains("没拍成快照：storage"))
        }
    }

    /// 只拍声明了、建过的卷；新的拍完删旧的；之后源再改不影响快照，复制过去的两边各写各的
    @Test func snapshotThenSeed() throws {
        let (storage, main, branch) = try setUp()
        defer { try? fm.removeItem(at: storage.root) }
        try write(storage, main, volume: "pg", "v1")
        #expect(try storage.takeSnapshot(main, project: try project(seed: ["pg", "s3"]))?.volumes == ["pg"], "s3 还没建过，不拍")
        try write(storage, main, volume: "pg", "v2")
        try write(storage, main, volume: "s3", "files")
        let second = try #require(try storage.takeSnapshot(main, project: try project(seed: ["pg", "s3"])))
        #expect(second.volumes == ["pg", "s3"])
        let dirs = try fm.contentsOfDirectory(atPath: storage.environmentDirectory(main).appending(path: "snapshots").path)
        #expect(dirs.count == 1, "只留最新的一份")
        try write(storage, main, volume: "pg", "v3-after-snapshot")

        try write(storage, branch, volume: "pg", "branch-old")
        let seed = try storage.stageSeed(from: main, to: branch.id, volumes: ["s3", "pg"])
        #expect(seed.environment == "p/main" && seed.volumes == ["pg", "s3"] && seed.takenAt == second.takenAt)
        #expect(read(storage, branch, volume: "pg") == "branch-old", "换卷之前目标不动")
        try storage.replaceVolumes(branch, volumes: ["pg", "s3"], seed: true, reason: "test")
        #expect(read(storage, branch, volume: "pg") == "v2", "拿到的是快照时的数据，不是源后来写的")
        #expect(read(storage, branch, volume: "s3") == "files")
        #expect(!fm.fileExists(atPath: storage.incomingDirectory(environmentID: branch.id).path))
        let recycled = try fm.contentsOfDirectory(atPath: storage.root.appending(path: "recycled").path)
        #expect(recycled.count == 1, "目标原来的 pg 进了 recycled（s3 原来没有）")

        try write(storage, branch, volume: "pg", "branch-new")
        #expect(read(storage, main, volume: "pg") == "v3-after-snapshot")
        #expect(try storage.stageSeed(from: main, to: branch.id, volumes: ["pg"]).takenAt == second.takenAt, "快照也没被分支改动")
    }

    /// 换卷做到一半停下：已经换进去的再做一遍时跳过，不会把复制来的又移走
    @Test func replaceIsResumable() throws {
        let (storage, main, branch) = try setUp()
        defer { try? fm.removeItem(at: storage.root) }
        try write(storage, main, volume: "pg", "main")
        try write(storage, main, volume: "s3", "main-s3")
        _ = try storage.takeSnapshot(main, project: try project(seed: ["pg", "s3"]))
        _ = try storage.stageSeed(from: main, to: branch.id, volumes: ["pg", "s3"])
        try storage.replaceVolumes(branch, volumes: ["pg"], seed: true, reason: "test") // 只换了 pg 就停下
        try storage.replaceVolumes(branch, volumes: ["pg", "s3"], seed: true, reason: "test") // 接着做
        #expect(read(storage, branch, volume: "pg") == "main")
        #expect(read(storage, branch, volume: "s3") == "main-s3")
        // 不带 seed 是换成空的：旧卷移走
        try storage.replaceVolumes(branch, volumes: ["pg"], seed: false, reason: "test")
        #expect(read(storage, branch, volume: "pg") == nil)
    }

    /// 没有快照、快照里缺卷报 snapshot_not_found，目标不动
    @Test func missingSnapshot() throws {
        let (storage, main, branch) = try setUp()
        defer { try? fm.removeItem(at: storage.root) }
        #expect { try storage.stageSeed(from: main, to: branch.id, volumes: ["pg"]) } throws: { ($0 as? NapboxError)?.code == "snapshot_not_found" }
        try write(storage, main, volume: "pg", "main")
        _ = try storage.takeSnapshot(main, project: try project(seed: ["pg"]))
        #expect { try storage.stageSeed(from: main, to: branch.id, volumes: ["pg", "s3"]) } throws: { ($0 as? NapboxError)?.code == "snapshot_not_found" }
        #expect(!fm.fileExists(atPath: storage.incomingDirectory(environmentID: branch.id).path))
    }

    /// napboxd 启动时：没在换卷的环境留下的 incoming/、没拍完的快照删掉；在换卷的留着
    @Test func leftoversRemoved() throws {
        let (storage, main, branch) = try setUp()
        defer { try? fm.removeItem(at: storage.root) }
        try write(storage, main, volume: "pg", "main")
        _ = try storage.takeSnapshot(main, project: try project(seed: ["pg"]))
        let unfinished = storage.environmentDirectory(main).appending(path: "snapshots/unfinished")
        try fm.createDirectory(at: unfinished, withIntermediateDirectories: true)
        _ = try storage.stageSeed(from: main, to: branch.id, volumes: ["pg"])
        let other = EnvironmentRecord(name: "p/c", project: "p", mainRepository: "/r/p", worktree: "/r/p/.wt/c", owner: .worktree, hostname: "x.localhost")
        _ = try storage.stageSeed(from: main, to: other.id, volumes: ["pg"])
        _ = storage.removeLeftoverSeeds(keepingIncoming: [branch.id])
        #expect(!fm.fileExists(atPath: unfinished.path))
        #expect(storage.latestSnapshot(main) != nil)
        #expect(fm.fileExists(atPath: storage.incomingDirectory(environmentID: branch.id).path))
        #expect(!fm.fileExists(atPath: storage.incomingDirectory(environmentID: other.id).path))
    }
}

/// 停下的情况：没正常停下时说清是哪一步
struct StopOutcomeTests {
    @Test func problem() {
        #expect(StopOutcome().clean && StopOutcome().problem == nil)
        let overdue = StopOutcome(overdue: [.init(service: "storage", grace: 10), .init(service: "web", grace: 2.5)])
        #expect(!overdue.clean)
        #expect(overdue.problem == "storage（等了 10 秒）、web（等了 2.5 秒）过了 stop_grace_period 还没退出，被强制结束；"
            + "先看服务日志里停下那段为什么慢，确实要这么久的再在 compose 里设更长的 stop_grace_period")
        #expect(StopOutcome(syncFailed: true, timeLimit: 73).problem == "存盘（sync）失败；停了 73 秒还没停完，直接关掉了虚拟机")
        #expect(StopOutcome(vmGone: true).problem == "停之前虚拟机已经不在了")
    }
}
