// napbox 在 ~/Library/Application Support/napbox/ 下放环境数据的位置：
// environments/<环境 ID>/ 是各环境的根文件系统、数据卷和日志（里面的结构见 EnvironmentLayout），
// recycled/ 是回收后保留 7 天的数据，builder/ 是构建引擎、构建缓存和构建日志，
// rootfs-templates/ 是按镜像留着的根文件系统模板（RootfsTemplates）。
import Foundation
import NapboxCore
import NapboxProtocol

struct Storage: Sendable {
    let root: URL

    /// 回收后的数据保留多久
    static let recycledKeepSeconds: TimeInterval = 7 * 24 * 3600

    func environmentDirectory(_ record: EnvironmentRecord) -> URL { environmentDirectory(id: record.id) }

    /// 还没登记时也能算（第一次起环境时先复制快照，再登记）
    func environmentDirectory(id: String) -> URL { root.appending(path: "environments/\(id)") }

    private var recycledRoot: URL { root.appending(path: "recycled") }

    /// 构建日志不放环境目录：第一次构建时环境还没登记（构建失败不留下登记），也就不该有环境目录
    func buildLogs(environment id: String) -> URL { root.appending(path: "builder/logs/\(id)") }

    func buildLog(environment id: String, service: String) -> URL { buildLogs(environment: id).appending(path: "\(service).log") }

    /// 每个环境最多留这么多条运行记录
    static let runsKept = 200

    /// 运行记录放在环境目录里，回收时跟着整个目录移到 recycled
    private func runsFile(_ record: EnvironmentRecord) -> URL { environmentDirectory(record).appending(path: "runs.json") }

    func runs(_ record: EnvironmentRecord) throws(NapboxError) -> [RunRecord] {
        let file = runsFile(record)
        guard let data = FileManager.default.contents(atPath: file.path) else { return [] }
        do {
            return try DiskJSON.decoder.decode([RunRecord].self, from: data)
        } catch {
            throw NapboxError(.internalError, "运行记录 \(file.path) 读不了：\(error)")
        }
    }

    /// 加一条，只留最近 runsKept 条。起环境在获取镜像时就失败的话环境目录可能还没有，先建上
    func appendRun(_ record: EnvironmentRecord, _ run: RunRecord) throws(NapboxError) {
        let file = runsFile(record)
        let all = (try runs(record) + [run]).suffix(Self.runsKept)
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try DiskJSON.encoder.encode(Array(all)).write(to: file, options: .atomic)
        } catch {
            throw NapboxError(.internalError, "写不了运行记录 \(file.path)：\(error.localizedDescription)")
        }
    }

    /// 把整个环境目录移到 recycled 下。环境没起过（没有目录）时返回 nil。
    func recycleEnvironment(_ record: EnvironmentRecord, reason: String) throws(NapboxError) -> URL? {
        try moveToRecycled(environmentDirectory(record), keptAt: nil, record: record, label: nil, reason: reason)
    }

    /// 调用方要求不保留数据：环境目录先整个移到 recycled/<环境 ID>-<时间>/data（一步改名，不会删到一半还登记着），
    /// 再删掉。删失败时还在 recycled 里，旁边的 recycled.json 先不动，照常 7 天后删，返回那个目录；删掉了返回 nil。
    /// 这个环境以前 discard 时移进 recycled、没删完的（删到一半 napboxd 被杀、或者当时删不掉）也一起删：
    /// napboxd 重启后接着做 discard 时，数据已经不在原位，只剩这些。
    func discardEnvironment(_ record: EnvironmentRecord, reason: String) throws(NapboxError) -> URL? {
        let moved = try moveToRecycled(environmentDirectory(record), keptAt: "data", record: record, label: nil, reason: reason)
        var kept: URL?
        let earlier = undeletedDiscards(record).filter { $0.lastPathComponent != moved?.lastPathComponent }
        for target in (moved.map { [$0] } ?? []) + earlier {
            do {
                try FileManager.default.removeItem(at: target.appending(path: "data"))
            } catch {
                print("删 \(target.path) 失败，留在 recycled 里 7 天后再删：\(error.localizedDescription)")
                kept = kept ?? target
                continue
            }
            // 只剩 recycled.json，删不掉也只是一个小文件，到期照样删
            try? FileManager.default.removeItem(at: target)
        }
        return kept
    }

    /// recycled 里这个环境 discard 时留下的：recycled/<环境 ID>-<时间>/data，recycled.json 记的是这个环境名。
    /// 只有 discard 是这种结构（down 回收的是环境目录本身，reset 和换成复制来的卷的是 volumes/<卷>.ext4）
    private func undeletedDiscards(_ record: EnvironmentRecord) -> [URL] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: recycledRoot, includingPropertiesForKeys: nil) else { return [] }
        return entries.filter { dir in
            guard dir.lastPathComponent.hasPrefix("\(record.id)-"), fm.fileExists(atPath: dir.appending(path: "data").path),
                  let data = fm.contents(atPath: dir.appending(path: RecycledInfo.fileName).path),
                  let info = try? DiskJSON.decoder.decode(RecycledInfo.self, from: data) else { return false }
            return info.name == record.name
        }.sorted { $0.path < $1.path }
    }

    /// 临时环境销毁：整个环境目录直接删掉，不保留。
    func deleteEnvironment(_ record: EnvironmentRecord) throws(NapboxError) {
        let directory = environmentDirectory(record)
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        do {
            try FileManager.default.removeItem(at: directory)
        } catch {
            throw NapboxError(.internalError, "删 \(directory.path) 失败：\(error.localizedDescription)")
        }
    }

    /// 把一个数据卷移到 recycled 下（在那里还是 volumes/<卷>.ext4）。卷还没建过时返回 nil。
    func recycleVolume(_ record: EnvironmentRecord, volume: String, reason: String) throws(NapboxError) -> URL? {
        let relative = EnvironmentLayout.volumePath(volume)
        return try moveToRecycled(environmentDirectory(record).appending(path: relative), keptAt: relative,
                                  record: record, label: volume, reason: reason)
    }

    /// 移到 recycled/<环境 ID>-<时间>[-<label>]/（keptAt 不是 nil 时放在这个目录下的 keptAt），
    /// 旁边写一份 recycled.json 记下是哪个环境、什么时候、为什么回收的；到期由 purgeRecycled 删掉。
    /// recycled.json 先写好，数据最后一步改名移过去：不会有移过去了却没有 recycled.json、永远清不掉的目录。
    /// 改名之前停下（失败或 napboxd 被杀），数据还在原位；只多一个只有 recycled.json 的目录，到期照常删。
    private func moveToRecycled(_ source: URL, keptAt relative: String?, record: EnvironmentRecord, label: String?,
                                reason: String) throws(NapboxError) -> URL? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: source.path) else { return nil }
        let now = Date()
        let stamp = ISO8601DateFormatter().string(from: now).replacingOccurrences(of: ":", with: "")
        let target = recycledRoot.appending(path: [record.id, stamp, label].compactMap(\.self).joined(separator: "-"))
        let info = RecycledInfo(name: record.name, worktree: record.worktree, recycledAt: now, reason: reason)
        do {
            let data = try DiskJSON.encoder.encode(info)
            if let relative {
                let destination = target.appending(path: relative)
                try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: target.appending(path: RecycledInfo.fileName))
                try fm.moveItem(at: source, to: destination)
            } else {
                // 整个目录移过去就是 target：recycled.json 先放进要移的目录里
                try fm.createDirectory(at: recycledRoot, withIntermediateDirectories: true)
                let file = source.appending(path: RecycledInfo.fileName)
                try data.write(to: file)
                do {
                    try fm.moveItem(at: source, to: target)
                } catch {
                    try? fm.removeItem(at: file) // 还在原位的环境目录里不留它
                    throw error
                }
            }
        } catch {
            throw NapboxError(.internalError, "移走 \(source.path) 失败：\(error.localizedDescription)")
        }
        return target
    }

    /// 删掉 recycled 下保留期满的数据，返回要记进日志的话。没有 recycled.json 或看不懂的不动：
    /// 判断不了是什么时候回收的，不能删。
    func purgeRecycled(now: Date) -> [String] {
        guard let entries = try? FileManager.default.contentsOfDirectory(at: recycledRoot, includingPropertiesForKeys: [.isDirectoryKey]) else { return [] }
        var messages: [String] = []
        // 只看目录（Finder 打开过会留下 .DS_Store 这类文件）
        for dir in entries.sorted(by: { $0.path < $1.path }) where (try? dir.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            let file = dir.appending(path: RecycledInfo.fileName)
            guard let data = try? Data(contentsOf: file), let info = try? DiskJSON.decoder.decode(RecycledInfo.self, from: data) else {
                messages.append("\(dir.path) 没有能看懂的 \(RecycledInfo.fileName)，不知道什么时候回收的，不删")
                continue
            }
            guard now.timeIntervalSince(info.recycledAt) >= Self.recycledKeepSeconds else { continue }
            do {
                try FileManager.default.removeItem(at: dir)
                messages.append("删掉了保留期满的 \(info.name) 的数据（\(dir.path)，回收原因：\(info.reason)）")
            } catch {
                messages.append("删 \(dir.path) 失败：\(error.localizedDescription)")
            }
        }
        return messages
    }
}

/// recycled/<环境 ID>-<时间>/recycled.json
struct RecycledInfo: Codable, Sendable {
    var name: String
    var worktree: String
    var recycledAt: Date
    /// 比如 "napbox down"、"worktree 删掉了：……"
    var reason: String

    static let fileName = "recycled.json"
}
