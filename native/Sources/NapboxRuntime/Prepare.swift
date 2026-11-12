// napbox setup 的一步：准备起环境要的东西，内核、runc、Rosetta 和 vminit 镜像。由 `napboxd prepare` 运行。
// 放在 napboxd 里：系统的 tar 解不了 zstd，这里有 Containerization 带的解压；URLSession 也会走系统代理。
import ContainerizationArchive
import CryptoKit
import Foundation
import NapboxProtocol
import Virtualization

public enum Prepare {
    /// apple/container 用的同一个内核包，里面取非 debug 版
    static let kernelPackage = URL(string: "https://github.com/kata-containers/kata-containers/releases/download/3.32.0/kata-static-3.32.0-arm64.tar.zst")!
    static let kernelPackageSHA256 = "8736c054d9223974735394f822000823baef509e1c33405ec798240fa9b6e4b5"
    static let kernelMember = "opt/kata/share/kata-containers/vmlinux-6.18.35-197"

    /// runc 官方发布的 arm64 程序（静态链接）。虚拟机里用它来启动容器（RuntimeContainer）
    static let runcBinary = URL(string: "https://github.com/opencontainers/runc/releases/download/v\(RuntimeContainer.runcVersion)/runc.arm64")!
    static let runcSHA256 = "ca70e7dbd6616ca782a59b5d3ac86909123fdaa9fa3f89dcf29051c70eee7ce9"

    /// 已经准备好的不重做。失败时不留下半成品，下次重来。
    public static func run(supportDirectory: URL, log: @Sendable (String) -> Void) async throws(NapboxError) {
        try await installKernel(into: supportDirectory.appending(path: "kernel"), log: log)
        try await installRunc(at: RuntimeContainer.runc(in: supportDirectory), log: log)
        try await installRosetta(log: log)
        log("准备 vminit 镜像 \(Runtime.vminitReference)")
        do {
            let store = try Runtime.openImageStore(supportDirectory: supportDirectory)
            _ = try await store.getInitImage(reference: Runtime.vminitReference)
        } catch {
            throw NapboxError(.runtimeUnavailable, "拉取 vminit 镜像失败：\(error)")
        }
    }

    /// 内核放在带版本的文件里，只有校验过才改名到位，所以它在就是好的；vmlinux 指向它。
    /// 开发时 vmlinux 可能指向别的内核（比如 debug 版），这里换掉。
    private static func installKernel(into directory: URL, log: @Sendable (String) -> Void) async throws(NapboxError) {
        let installed = directory.appending(path: URL(filePath: kernelMember).lastPathComponent)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: installed.path) {
                log("下载内核包 \(kernelPackage.absoluteString)（约 700MB）")
                let (package, response) = try await URLSession.shared.download(from: kernelPackage)
                defer { try? FileManager.default.removeItem(at: package) }
                if let status = (response as? HTTPURLResponse)?.statusCode, status != 200 {
                    throw NapboxError(.runtimeUnavailable, "下载内核包失败：HTTP \(status)")
                }
                let digest = try sha256(of: package)
                guard digest == kernelPackageSHA256 else {
                    throw NapboxError(.runtimeUnavailable, "内核包的校验值不对：应该是 \(kernelPackageSHA256)，下载到的是 \(digest)")
                }
                log("解出内核 \(kernelMember)")
                let (_, kernel) = try ArchiveReader(file: package).extractFile(path: kernelMember)
                let temporary = directory.appending(path: ".\(installed.lastPathComponent).\(getpid())")
                defer { try? FileManager.default.removeItem(at: temporary) }
                try kernel.write(to: temporary)
                try FileManager.default.moveItem(at: temporary, to: installed)
            }
            // 先建好再改名盖过去：运行中的 napboxd 不会读到没有 vmlinux 的时刻
            let link = directory.appending(path: "vmlinux")
            let current = try? FileManager.default.destinationOfSymbolicLink(atPath: link.path)
            if current != installed.lastPathComponent {
                let temporary = directory.appending(path: ".vmlinux.\(getpid())")
                defer { try? FileManager.default.removeItem(at: temporary) }
                try FileManager.default.createSymbolicLink(atPath: temporary.path, withDestinationPath: installed.lastPathComponent)
                guard rename(temporary.path, link.path) == 0 else {
                    throw NapboxError(.runtimeUnavailable, "换不了 \(link.path)：\(String(cString: strerror(errno)))")
                }
            }
        } catch let error as NapboxError {
            throw error
        } catch {
            throw NapboxError(.runtimeUnavailable, "准备内核失败：\(error)")
        }
    }

    /// 和内核一样：文件名带版本，校验过才改名到位，所以它在就是好的。
    private static func installRunc(at installed: URL, log: @Sendable (String) -> Void) async throws(NapboxError) {
        guard !FileManager.default.fileExists(atPath: installed.path) else { return }
        let directory = installed.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            log("下载 runc \(runcBinary.absoluteString)（约 10MB）")
            let (downloaded, response) = try await URLSession.shared.download(from: runcBinary)
            defer { try? FileManager.default.removeItem(at: downloaded) }
            if let status = (response as? HTTPURLResponse)?.statusCode, status != 200 {
                throw NapboxError(.runtimeUnavailable, "下载 runc 失败：HTTP \(status)")
            }
            let digest = try sha256(of: downloaded)
            guard digest == runcSHA256 else {
                throw NapboxError(.runtimeUnavailable, "runc 的校验值不对：应该是 \(runcSHA256)，下载到的是 \(digest)")
            }
            // 下载到的在系统的临时目录，可能和这里不在一个盘上：先拷到旁边再改名
            let temporary = directory.appending(path: ".\(installed.lastPathComponent).\(getpid())")
            defer { try? FileManager.default.removeItem(at: temporary) }
            try FileManager.default.copyItem(at: downloaded, to: temporary)
            try FileManager.default.moveItem(at: temporary, to: installed)
        } catch let error as NapboxError {
            throw error
        } catch {
            throw NapboxError(.runtimeUnavailable, "准备 runc 失败：\(error)")
        }
    }

    /// 苹果的 Rosetta：虚拟机靠它运行 x86 的程序（Runtime.prepare 建虚拟机时打开）。它是系统的组件，
    /// 没装就请系统装，系统会弹一次确认。
    private static func installRosetta(log: @Sendable (String) -> Void) async throws(NapboxError) {
        switch VZLinuxRosettaDirectoryShare.availability {
        case .installed:
            return
        case .notInstalled:
            log("安装 Rosetta（系统会弹出确认窗口）")
            do {
                try await VZLinuxRosettaDirectoryShare.installRosetta()
            } catch {
                throw NapboxError(.runtimeUnavailable, "安装 Rosetta 失败：\(error)")
            }
        default:
            throw NapboxError(.runtimeUnavailable, "这台电脑不支持 Rosetta，虚拟机里运行不了 x86 的程序。")
        }
    }

    private static func sha256(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hash = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty { hash.update(data: chunk) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
