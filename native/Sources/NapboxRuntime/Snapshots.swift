// 数据快照（x-napbox.seed）：环境正常停下时，把声明的数据卷用 APFS 克隆（clonefile）留一份，给别的 worktree 复制。
// 克隆只改元数据，几毫秒，刚拍下时不多占空间；之后两边各写各的，只有改过的块才各占一份。
//
// environments/<环境 ID>/ 下：
//   snapshots/<时间>/<卷>.ext4 和 snapshot.json：只留最新的一份。snapshot.json 最后写，有它的才算拍完
//   incoming/<卷>.ext4：从别的环境的快照复制过来、还没换进 volumes/ 的卷（PendingOperation.replaceVolumes）
//
// 都在 napboxd 的 actor 上同步做（clonefile、改名都很快），拍快照和从快照复制不会交错，不用另加锁。
import Foundation
import NapboxCore
import NapboxProtocol

/// snapshots/<时间>/snapshot.json
struct SnapshotInfo: Codable, Sendable {
    var takenAt: Date
    /// 拍了哪些卷，按名字排序
    var volumes: [String]

    static let fileName = "snapshot.json"
}

extension Storage {
    private func snapshotsRoot(_ record: EnvironmentRecord) -> URL { environmentDirectory(record).appending(path: "snapshots") }

    func incomingDirectory(environmentID id: String) -> URL { environmentDirectory(id: id).appending(path: "incoming") }

    /// 环境刚正常停下（虚拟机已经停了）：给 project.seed 里已经建过的卷拍一份快照，换掉旧的。
    /// 声明的卷都还没建过时不拍，旧的留着。返回拍下的；没拍是 nil
    func takeSnapshot(_ record: EnvironmentRecord, project: ComposeProject) throws(NapboxError) -> SnapshotInfo? {
        let fm = FileManager.default
        let directory = environmentDirectory(record)
        let volumes = (project.seed ?? []).filter { fm.fileExists(atPath: directory.appending(path: EnvironmentLayout.volumePath($0)).path) }
        guard !volumes.isEmpty else { return nil }
        // 记到整秒：snapshot.json 的时间是 ISO 8601（到秒），读回来要和拍的时候一样
        let now = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))
        let root = snapshotsRoot(record)
        let target = root.appending(path: Self.directoryName())
        let info = SnapshotInfo(takenAt: now, volumes: volumes)
        do {
            try fm.createDirectory(at: target, withIntermediateDirectories: true)
            for volume in volumes {
                try Self.clone(directory.appending(path: EnvironmentLayout.volumePath(volume)), to: target.appending(path: "\(volume).ext4"))
            }
            try DiskJSON.encoder.encode(info).write(to: target.appending(path: SnapshotInfo.fileName), options: .atomic)
        } catch {
            try? fm.removeItem(at: target)
            throw NapboxError(.internalError, "给环境 \(record.name) 拍快照失败：\(error)")
        }
        // 新的拍完了才删旧的（包括没拍完的）
        for dir in (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [] where dir.lastPathComponent != target.lastPathComponent {
            try? fm.removeItem(at: dir)
        }
        return info
    }

    /// 最新的拍完了的快照。平常只有一份；新的拍完、旧的还没删时按目录名（拍的时间，到毫秒）取新的
    func latestSnapshot(_ record: EnvironmentRecord) -> (directory: URL, info: SnapshotInfo)? {
        let dirs = (try? FileManager.default.contentsOfDirectory(at: snapshotsRoot(record), includingPropertiesForKeys: nil)) ?? []
        return dirs.sorted { $0.lastPathComponent > $1.lastPathComponent }.lazy.compactMap { dir -> (URL, SnapshotInfo)? in
            guard let data = FileManager.default.contents(atPath: dir.appending(path: SnapshotInfo.fileName).path),
                  let info = try? DiskJSON.decoder.decode(SnapshotInfo.self, from: data) else { return nil }
            return (dir, info)
        }.first
    }

    /// 把源环境最新快照里的这些卷克隆到目标环境的 incoming/（先清空它）。目标可以还没登记，按环境 ID 找目录。
    /// 没有快照、快照里缺要的卷时报 snapshot_not_found
    func stageSeed(from source: EnvironmentRecord, to targetID: String, volumes: [String]) throws(NapboxError) -> SeedSource {
        guard let (dir, info) = latestSnapshot(source) else {
            throw NapboxError(.snapshotNotFound, "环境 \(source.name) 还没有快照：它声明了 x-napbox.seed、正常停下（闲置休眠、napbox sleep、napboxd 退出）时才拍。"
                + "要现在拍，在那边 napbox sleep 一次——这会断开它的连接、结束在跑的 exec，先确认它没在跑测试")
        }
        let missing = volumes.filter { !info.volumes.contains($0) }
        guard missing.isEmpty else {
            throw NapboxError(.snapshotNotFound, "环境 \(source.name) 的快照（\(Self.describe(info.takenAt))）里没有 \(missing.joined(separator: "、"))，"
                + "只有 \(info.volumes.joined(separator: "、"))。快照只拍源环境 x-napbox.seed 里声明、已经建过的卷，改了声明要等它下次正常停下")
        }
        let incoming = incomingDirectory(environmentID: targetID)
        let fm = FileManager.default
        do {
            if fm.fileExists(atPath: incoming.path) { try fm.removeItem(at: incoming) }
            try fm.createDirectory(at: incoming, withIntermediateDirectories: true)
            for volume in volumes {
                try Self.clone(dir.appending(path: "\(volume).ext4"), to: incoming.appending(path: "\(volume).ext4"))
            }
        } catch {
            try? fm.removeItem(at: incoming)
            throw NapboxError(.internalError, "从环境 \(source.name) 的快照复制数据卷失败：\(error)")
        }
        return SeedSource(environment: source.name, takenAt: info.takenAt, volumes: volumes.sorted())
    }

    /// 换掉数据卷，环境要先停掉。seed 是 false 时旧卷移到 recycled（下次起来建空的）；是 true 时 incoming/ 里有这个卷才换：
    /// 旧卷移到 recycled，再把复制来的改名放进 volumes/。incoming/ 里没有的是上次已经换进去了（napboxd 中途被杀后接着做）
    func replaceVolumes(_ record: EnvironmentRecord, volumes: [String], seed: Bool, reason: String) throws(NapboxError) {
        let fm = FileManager.default
        let directory = environmentDirectory(record)
        let incoming = incomingDirectory(environmentID: record.id)
        for volume in volumes {
            let staged = incoming.appending(path: "\(volume).ext4")
            if seed, !fm.fileExists(atPath: staged.path) { continue }
            _ = try recycleVolume(record, volume: volume, reason: reason)
            guard seed else { continue }
            do {
                let layout = try EnvironmentLayout(directory: directory)
                layout.forgetPopulated(volume)
                try fm.moveItem(at: staged, to: directory.appending(path: EnvironmentLayout.volumePath(volume)))
            } catch {
                throw NapboxError(.internalError, "把复制来的数据卷 \(volume) 放进环境 \(record.name) 失败：\(error)")
            }
        }
        if seed, (try? fm.contentsOfDirectory(atPath: incoming.path))?.isEmpty == true { try? fm.removeItem(at: incoming) }
    }

    /// napboxd 启动时：没有在换卷的环境留下的 incoming/（复制好了、还没开始换就停下了），和没拍完的快照，都删掉
    func removeLeftoverSeeds(keepingIncoming ids: Set<String>) -> [String] {
        let fm = FileManager.default
        var messages: [String] = []
        for dir in (try? fm.contentsOfDirectory(at: root.appending(path: "environments"), includingPropertiesForKeys: nil)) ?? [] {
            let incoming = dir.appending(path: "incoming")
            if !ids.contains(dir.lastPathComponent), fm.fileExists(atPath: incoming.path) {
                if (try? fm.removeItem(at: incoming)) != nil { messages.append("删掉了没换进去的复制数据：\(incoming.path)") }
            }
            for snapshot in (try? fm.contentsOfDirectory(at: dir.appending(path: "snapshots"), includingPropertiesForKeys: nil)) ?? []
            where !fm.fileExists(atPath: snapshot.appending(path: SnapshotInfo.fileName).path) {
                if (try? fm.removeItem(at: snapshot)) != nil { messages.append("删掉了没拍完的快照：\(snapshot.path)") }
            }
        }
        return messages
    }

    /// 稀疏文件照样克隆，不展开
    private static func clone(_ source: URL, to destination: URL) throws {
        guard clonefile(source.path, destination.path, 0) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    /// 拍的时间（到毫秒，按名字排就是按时间排）加一段随机字符：同一时刻再拍也不会和现有的那份同名、把它删掉
    private static func directoryName() -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: Date()).replacingOccurrences(of: ":", with: "") + "-" + UUID().uuidString.prefix(8).lowercased()
    }

    static func describe(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }
}
