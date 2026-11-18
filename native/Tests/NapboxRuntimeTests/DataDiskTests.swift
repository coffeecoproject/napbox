// 数据卷、构建缓存这类可写的盘和 Linux 上 mkfs.ext4 建的一样：特性是 e2fsprogs 1.47 的 ext4 默认那一套
// （有目录索引 dir_index），根目录是空的，新盘几乎不占地方。
// 要用编译好的 mke2fs、debugfs：scripts/test-native.sh 先编译，再用 NAPBOX_TEST_PROGRAMS 告诉测试在哪。
import Foundation
import NapboxCore
@testable import NapboxRuntime
import Testing

struct DataDiskTests {
    /// e2fsprogs 1.47 的 mkfs.ext4 在 Linux 上默认建出来的特性（debugfs stats 和 dumpe2fs -h 的 Filesystem features 那行）
    static let mkfsExt4Features: Set<String> = [
        "has_journal", "ext_attr", "resize_inode", "dir_index", "orphan_file", "filetype", "extent", "64bit", "flex_bg",
        "metadata_csum_seed", "sparse_super", "large_file", "huge_file", "dir_nlink", "extra_isize", "metadata_csum",
    ]

    private func disk() throws -> DataDisk {
        let programs = try #require(ProcessInfo.processInfo.environment["NAPBOX_TEST_PROGRAMS"],
                                    "用 scripts/test-native.sh 跑：要先编译出 mke2fs、debugfs")
        let disk = DataDisk(programs: URL(filePath: programs))
        #expect(disk.missing.isEmpty)
        return disk
    }

    private func debugfs(_ disk: DataDisk, _ request: String, _ path: URL) throws -> String {
        let output = try Subprocess.run(disk.debugfs.path, ["-R", request, path.path])
        return String(decoding: output.stdout, as: UTF8.self)
    }

    @Test func dataDiskIsWhatMkfsExt4Makes() throws {
        let disk = try disk()
        let directory = FileManager.default.temporaryDirectory.appending(path: "nbx-disk-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appending(path: "data.ext4")
        try disk.create(at: path, bytes: EnvironmentLayout.volumeBytes)

        let stats = try debugfs(disk, "stats", path)
        let line = try #require(stats.split(separator: "\n").first { $0.hasPrefix("Filesystem features:") })
        let features = Set(line.dropFirst("Filesystem features:".count).split(separator: " ").map(String.init))
        #expect(features == Self.mkfsExt4Features)
        #expect(stats.contains("Block size:               4096"))

        // 根目录只有 . 和 ..：没有 lost+found
        // ls -p 一行一项：/inode/模式/uid/gid/名字/
        let root = try debugfs(disk, "ls -p /", path).split(separator: "\n").map {
            String($0.split(separator: "/", omittingEmptySubsequences: false)[5])
        }
        #expect(root.sorted() == [".", ".."])

        // 稀疏文件：32G 的盘，新建时实际占的不到 16MB（日志和元数据都没清零）
        let values = try path.resourceValues(forKeys: [.fileSizeKey, .totalFileAllocatedSizeKey])
        #expect(values.fileSize == Int(EnvironmentLayout.volumeBytes))
        #expect(try #require(values.totalFileAllocatedSize) < 16 * 1024 * 1024)
    }

    /// 路径上已经有东西（上次建到一半）：删掉重建
    @Test func createReplacesWhatIsThere() throws {
        let disk = try disk()
        let path = FileManager.default.temporaryDirectory.appending(path: "nbx-disk-\(UUID().uuidString).ext4")
        defer { try? FileManager.default.removeItem(at: path) }
        try Data("half".utf8).write(to: path)
        try disk.create(at: path, bytes: 64 * 1024 * 1024)
        #expect(try debugfs(disk, "stats", path).contains("dir_index"))
    }
}
