// 一个环境在磁盘上的东西：每个服务的根文件系统、命名卷、日志。都在 environments/<环境 ID>/ 下。
// 休眠只停虚拟机，这些都保留。
import Containerization
import ContainerizationEXT4
import CryptoKit
import Foundation
import NapboxCore
import NapboxProtocol
import SystemPackage

struct EnvironmentLayout: Sendable {
    let directory: URL

    /// 根文件系统和数据卷都是稀疏文件，写多少占多少
    static let rootfsBytes: UInt64 = 8 * 1024 * 1024 * 1024
    static let volumeBytes: UInt64 = 32 * 1024 * 1024 * 1024
    /// 磁盘都开日志：虚拟机没正常停（napboxd 崩溃、被强杀）时，没日志的磁盘会不一致，环境再也起不来
    static let journal = EXT4.JournalConfig.default

    init(directory: URL) throws(NapboxError) {
        self.directory = directory
        for sub in ["rootfs", "volumes", "logs", "populated"] {
            do {
                try FileManager.default.createDirectory(at: directory.appending(path: sub), withIntermediateDirectories: true)
            } catch {
                throw NapboxError(.internalError, "建不了 \(directory.path)/\(sub)：\(error.localizedDescription)")
            }
        }
    }

    /// 服务的根文件系统。和 Docker 决定要不要重建容器的规则一样：镜像和服务的定义（命令、环境变量、挂载等）
    /// 都没变就沿用上次的，容器里写的东西还在；有一样变了就重建。
    /// 重建时同一个镜像只解包一次：这次起环境已经为别的服务新解包过这个镜像，就用 APFS 克隆它（不占额外空间，
    /// 几乎不花时间），不再解包一遍。
    /// - definition：服务定义的固定写法（键排好序的 JSON），由调用方给出
    /// - fresh：这次起环境新解包出来的根文件系统，按镜像（平台清单的 digest）记。只记新解包的：沿用的根文件系统里
    ///   有容器写过的东西，不能拿来克隆。所有服务的根文件系统都在虚拟机起来之前准备好，这期间新解包的还没人写过
    /// - 返回挂载和根文件系统是怎么来的（运行记录用）
    func rootfs(_ service: String, image: Containerization.Image, platform: ImagePlatform, definition: String,
                fresh: inout [String: URL]) async throws(NapboxError) -> (mount: Containerization.Mount, source: ServiceRun.Rootfs) {
        let path = directory.appending(path: "rootfs/\(service).ext4")
        let stamp = directory.appending(path: "rootfs/\(service).stamp")
        let mount = Containerization.Mount.block(format: "ext4", source: path.path, destination: "/", options: [])
        do {
            let digest = try await image.descriptor(for: platform.oci).digest
            let current = digest + "\n" + definition
            if FileManager.default.fileExists(atPath: path.path), (try? String(contentsOf: stamp, encoding: .utf8)) == current {
                return (mount, .reused)
            }
            // 重建：和 Docker 删掉旧容器再建新的一样，旧的根文件系统不要了（解包工具不会覆盖已有的文件）
            try? FileManager.default.removeItem(at: stamp)
            try? FileManager.default.removeItem(at: watchManifest(service)) // 同步进去的跟着旧的根文件系统没了
            try? FileManager.default.removeItem(at: populatedDirectory(service)) // 新容器，卷要不要带镜像内容重新看
            if FileManager.default.fileExists(atPath: path.path) { try FileManager.default.removeItem(at: path) }
            let source: ServiceRun.Rootfs
            if let original = fresh[digest] {
                guard clonefile(original.path, path.path, 0) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                source = .cloned
            } else {
                _ = try await EXT4Unpacker(capacityInBytes: Self.rootfsBytes, journal: Self.journal).unpack(image, for: platform.oci, at: path)
                fresh[digest] = path
                source = .unpacked
            }
            try Data(current.utf8).write(to: stamp)
            return (mount, source)
        } catch {
            throw NapboxError(.imageUnavailable, "\(service) 的根文件系统准备失败：\(error)")
        }
    }

    /// develop.watch 记着这个服务同步到哪了：放在根文件系统旁边，根文件系统重建时一起删
    func watchManifest(_ service: String) -> URL {
        directory.appending(path: "rootfs/\(service).watch.json")
    }

    /// 网络小容器的根文件系统：只有 napbox-guard 一个程序，加上挂载点和放 hosts、resolv.conf 的 /etc。
    /// 程序没变（按内容的 sha256）就沿用。
    func guardRootfs(binary: URL) throws(NapboxError) -> Containerization.Mount {
        let path = directory.appending(path: "rootfs/\(GuardContainer.name).ext4")
        let stamp = directory.appending(path: "rootfs/\(GuardContainer.name).stamp")
        let mount = Containerization.Mount.block(format: "ext4", source: path.path, destination: "/", options: [])
        do {
            let content = try Data(contentsOf: binary)
            let digest = "sha256:" + SHA256.hash(data: content).map { String(format: "%02x", $0) }.joined()
            if FileManager.default.fileExists(atPath: path.path), (try? String(contentsOf: stamp, encoding: .utf8)) == digest {
                return mount
            }
            try? FileManager.default.removeItem(at: stamp)
            if FileManager.default.fileExists(atPath: path.path) { try FileManager.default.removeItem(at: path) }
            let formatter = try EXT4.Formatter(FilePath(path.path), minDiskSize: 64 * 1024 * 1024, journal: Self.journal)
            for dir in ["/etc", "/proc", "/sys", "/dev", "/run"] {
                try formatter.create(path: FilePath(dir), mode: EXT4.Inode.Mode(.S_IFDIR, 0o755))
            }
            try formatter.create(path: FilePath("/tmp"), mode: EXT4.Inode.Mode(.S_IFDIR, 0o1777))
            let stream = InputStream(data: content)
            stream.open()
            defer { stream.close() }
            try formatter.create(path: FilePath(GuardContainer.program), mode: EXT4.Inode.Mode(.S_IFREG, 0o755), buf: stream)
            try formatter.close()
            try Data(digest.utf8).write(to: stamp)
            return mount
        } catch {
            try? FileManager.default.removeItem(at: path)
            throw NapboxError(.runtimeUnavailable, "网络小容器的根文件系统准备失败：\(error)")
        }
    }

    /// 启动容器用的那块盘（RuntimeContainer）：垫在 runc 前面的那一层（就是 napbox-guard 这个程序）、runc、每个服务的地址。
    /// 三样都没变（按内容的 sha256）就沿用。
    func runtimeDisk(guardBinary: URL, runc: URL, addresses: [String: String]) throws(NapboxError) -> Containerization.Mount {
        let path = directory.appending(path: "rootfs/\(RuntimeContainer.name).ext4")
        let stamp = directory.appending(path: "rootfs/\(RuntimeContainer.name).stamp")
        let mount = Containerization.Mount.block(format: "ext4", source: path.path, destination: "/", options: [])
        do {
            let files: [(path: String, content: Data, mode: UInt16)] = [
                (RuntimeContainer.program, try Data(contentsOf: guardBinary), 0o755),
                (RuntimeContainer.runc, try Data(contentsOf: runc), 0o755),
                (RuntimeContainer.networkFile, try RuntimeContainer.networkConfiguration(addresses), 0o644),
            ]
            let digest = files.map { file in
                "\(file.path) sha256:" + SHA256.hash(data: file.content).map { String(format: "%02x", $0) }.joined()
            }.joined(separator: "\n")
            if FileManager.default.fileExists(atPath: path.path), (try? String(contentsOf: stamp, encoding: .utf8)) == digest {
                return mount
            }
            try? FileManager.default.removeItem(at: stamp)
            if FileManager.default.fileExists(atPath: path.path) { try FileManager.default.removeItem(at: path) }
            let formatter = try EXT4.Formatter(FilePath(path.path), minDiskSize: 64 * 1024 * 1024, journal: Self.journal)
            for file in files {
                let stream = InputStream(data: file.content)
                stream.open()
                defer { stream.close() }
                try formatter.create(path: FilePath(file.path), mode: EXT4.Inode.Mode(.S_IFREG, file.mode), buf: stream)
            }
            try formatter.close()
            try Data(digest.utf8).write(to: stamp)
            return mount
        } catch {
            try? FileManager.default.removeItem(at: path)
            throw NapboxError(.runtimeUnavailable, "启动容器用的那块盘准备失败：\(error)")
        }
    }

    /// 命名卷：第一次用时建一块空盘（DataDisk）
    func volume(_ name: String, disk: DataDisk) throws(NapboxError) -> URL {
        let path = directory.appending(path: Self.volumePath(name))
        if FileManager.default.fileExists(atPath: path.path) { return path }
        // 新的卷（第一次用，或者 napbox reset 之后）：每个服务都要重新看要不要带镜像内容
        forgetPopulated(name)
        do {
            try disk.create(at: path, bytes: Self.volumeBytes)
        } catch {
            throw NapboxError(.internalError, "建不了数据卷 \(name)：\(error)")
        }
        return path
    }

    /// 已经建过的匿名卷的名字
    func anonymousVolumes() -> [String] {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: directory.appending(path: "volumes").path)) ?? []
        return files.filter { $0.hasPrefix(ComposeProject.anonymousVolumePrefix) && $0.hasSuffix(".ext4") }
            .map { String($0.dropLast(".ext4".count)) }.sorted()
    }

    // 命名卷带上镜像内容。Docker 是建容器时看一次：卷是空的、镜像里有这个目录就复制。
    // 这里的“建容器”是解出新的根文件系统，所以按“这个服务现在的根文件系统对这个卷看过没有”记：看过就不再看，
    // 休眠唤醒不会把已经清空的卷又填上（和 docker stop、start 一样）；根文件系统重建、卷重新建了就作废。

    private func populatedDirectory(_ service: String) -> URL { directory.appending(path: "populated/\(service)") }

    func volumePopulated(_ volume: String, service: String) -> Bool {
        FileManager.default.fileExists(atPath: populatedDirectory(service).appending(path: volume).path)
    }

    /// 卷换成了别的（复制来的）：每个服务都要重新看要不要带镜像内容（卷不是空的就不会带）
    func forgetPopulated(_ volume: String) {
        let services = (try? FileManager.default.contentsOfDirectory(at: directory.appending(path: "populated"), includingPropertiesForKeys: nil)) ?? []
        for service in services { try? FileManager.default.removeItem(at: service.appending(path: volume)) }
    }

    func markVolumePopulated(_ volume: String, service: String) throws(NapboxError) {
        do {
            try FileManager.default.createDirectory(at: populatedDirectory(service), withIntermediateDirectories: true)
            try Data().write(to: populatedDirectory(service).appending(path: volume))
        } catch {
            throw NapboxError(.internalError, "记不下数据卷 \(volume) 已经准备好：\(error.localizedDescription)")
        }
    }

    func log(_ service: String) -> URL { Self.logFile(in: directory, service: service) }

    static func logFile(in directory: URL, service: String) -> URL { directory.appending(path: "logs/\(service).log") }

    /// 数据卷在环境目录下的相对路径
    static func volumePath(_ name: String) -> String { "volumes/\(name).ext4" }
}

/// 容器的标准输出和标准错误追加写到一个文件里。
final class LogFile: Writer, @unchecked Sendable {
    private let handle: FileHandle?
    private let lock = NSLock()
    let url: URL

    init(url: URL) {
        self.url = url
        if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
        handle = try? FileHandle(forWritingTo: url)
        _ = try? handle?.seekToEnd()
    }

    func write(_ data: Data) throws {
        lock.lock()
        defer { lock.unlock() }
        try handle?.write(contentsOf: data)
    }

    func close() {
        lock.lock()
        defer { lock.unlock() }
        try? handle?.close()
    }

    /// 最后几行，报错时带上。日志可能很大，只读末尾这一段（LogReader）；不是 UTF-8 的字节照样显示出来
    func tail(_ lines: Int) -> String {
        let end = LogReader.size(of: url)
        var offset = LogReader.startOffset(of: url, lastLines: lines)
        var data = Data()
        while offset < end, let chunk = LogReader.read(url, from: offset, upTo: end), !chunk.isEmpty {
            data.append(chunk)
            offset += UInt64(chunk.count)
        }
        return String(decoding: data, as: UTF8.self)
    }
}
