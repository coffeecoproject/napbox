// 可写的空盘（数据卷、构建缓存）：用 napbox 带的 e2fsprogs 建，和 Linux 上 mkfs.ext4 建出来的一样。
// Containerization 的 EXT4.Formatter 只用来把镜像和 napbox 自己的程序写成盘：它的特性是写死的，没有目录索引
// （dir_index）等，长期大量写的盘用它，目录里文件一多，每建、每找一个文件都要把目录从头翻一遍，
// PostgreSQL 这类一个目录里放几千个文件的程序慢几倍。
import Foundation
import NapboxCore

struct DataDisk: Sendable {
    let mke2fs: URL
    let debugfs: URL
    /// e2fsprogs 自带的那份 mke2fs.conf：特性照它来，不看本机 /etc 下有没有别的
    let config: URL

    /// - programs：napboxd 所在的目录，scripts/build-native.sh 把这三样编译好放在那里
    init(programs: URL) {
        mke2fs = programs.appending(path: "mke2fs")
        debugfs = programs.appending(path: "debugfs")
        config = programs.appending(path: "mke2fs.conf")
    }

    /// 缺的那几样
    var missing: [URL] { [mke2fs, debugfs, config].filter { !FileManager.default.fileExists(atPath: $0.path) } }

    /// 在 path 新建一块 bytes 大的空盘。稀疏文件，写多少占多少：新文件读出来全是 0，所以告诉 mke2fs 不用清零
    /// （assume_storage_prezeroed），内核挂上后也不会在后台补着清零。根目录是空的：去掉 lost+found，
    /// 否则 postgres 这类要求目录为空的程序初始化会失败（Docker 的卷是普通目录，本来就没有它）。
    /// 先在旁边的 <名字>.creating 建好，最后一步改名过去：中途失败或 napboxd 被杀，path 上不会留下建到一半的盘
    /// （调用方见到 path 有文件就直接用）。上次留下的 .creating 先删掉；path 已经有东西时换掉。
    func create(at path: URL, bytes: UInt64) throws {
        let creating = Self.creatingPath(path)
        if FileManager.default.fileExists(atPath: creating.path) { try FileManager.default.removeItem(at: creating) }
        do {
            let made = try Subprocess.run(mke2fs.path, [
                "-q", "-F", "-t", "ext4", "-E", "root_owner=0:0,assume_storage_prezeroed=1", creating.path, "\(bytes / 1024)k",
            ], environment: ["MKE2FS_CONFIG": config.path])
            guard made.status == 0 else { throw Failure(message: "mke2fs 退出码 \(made.status)：\(made.stderrText)") }
            // debugfs 出错也是退出码 0，只在标准错误里说：除了开头那行版本号，有别的就是失败
            let removed = try Subprocess.run(debugfs.path, ["-w", "-R", "rmdir lost+found", creating.path])
            let errors = removed.stderrText.split(separator: "\n").dropFirst().filter { !$0.isEmpty }
            guard removed.status == 0, errors.isEmpty else {
                throw Failure(message: "debugfs 删不了 lost+found：\(errors.joined(separator: "；"))")
            }
            guard rename(creating.path, path.path) == 0 else {
                throw Failure(message: "改名到 \(path.path) 失败：\(String(cString: strerror(errno)))")
            }
        } catch {
            try? FileManager.default.removeItem(at: creating)
            throw error
        }
    }

    /// 建盘时先用的临时文件
    static func creatingPath(_ path: URL) -> URL {
        path.deletingLastPathComponent().appending(path: path.lastPathComponent + ".creating")
    }

    struct Failure: Error, CustomStringConvertible {
        var message: String
        var description: String { message }
    }
}
