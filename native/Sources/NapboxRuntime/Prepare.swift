// napbox setup 的一步：准备起环境要的东西，内核、runc、Rosetta 和 vminit 镜像。由 `napboxd prepare` 运行。
// 放在 napboxd 里：系统的 tar 解不了 zstd，这里有 Containerization 带的解压；URLSession 也会走系统代理。
import Containerization
import ContainerizationArchive
import ContainerizationExtras
import CryptoKit
import Foundation
import NapboxProtocol
import Synchronization
import Virtualization

public enum Prepare {
    /// apple/container 用的同一个内核包，里面取非 debug 版
    static let kernelPackage = URL(string: "https://github.com/kata-containers/kata-containers/releases/download/3.32.0/kata-static-3.32.0-arm64.tar.zst")!
    static let kernelPackageSHA256 = "8736c054d9223974735394f822000823baef509e1c33405ec798240fa9b6e4b5"
    static let kernelMember = "opt/kata/share/kata-containers/vmlinux-6.18.35-197"

    /// runc 官方发布的 arm64 程序（静态链接）。虚拟机里用它来启动容器（RuntimeContainer）
    static let runcBinary = URL(string: "https://github.com/opencontainers/runc/releases/download/v\(RuntimeContainer.runcVersion)/runc.arm64")!
    static let runcSHA256 = "ca70e7dbd6616ca782a59b5d3ac86909123fdaa9fa3f89dcf29051c70eee7ce9"

    /// 自己下好的文件放哪都行，设这两个变量指向它就不下载（校验值照样核对）。GitHub 太慢时用
    static let kernelPackageVariable = "NAPBOX_KERNEL_PACKAGE"
    static let runcVariable = "NAPBOX_RUNC"
    /// vminit 拉不下来时整个重拉（框架接不着下）。每次前等多久
    static let vminitRetryDelays: [Duration] = [.seconds(5), .seconds(15)]
    /// 拉 vminit 时这么久没收到数据就算卡住，停下重拉（框架的下载没有读超时，卡住会一直等）
    static let vminitIdleTimeout: Duration = .seconds(60)

    /// 已经准备好的不重做。内核包和 runc 下到一半的留着，下次接着下；没校验过的不会放到位。
    public static func run(supportDirectory: URL, log: @escaping @Sendable (String) -> Void) async throws(NapboxError) {
        try await installKernel(into: supportDirectory.appending(path: "kernel"), log: log)
        try await installRunc(at: RuntimeContainer.runc(in: supportDirectory), log: log)
        try await installRosetta(log: log)
        try await installVminit(supportDirectory: supportDirectory, log: log)
    }

    /// 内核放在带版本的文件里，只有校验过才改名到位，所以它在就是好的；vmlinux 指向它。
    /// 开发时 vmlinux 可能指向别的内核（比如 debug 版），这里换掉。
    private static func installKernel(into directory: URL, log: @escaping @Sendable (String) -> Void) async throws(NapboxError) {
        let installed = directory.appending(path: URL(filePath: kernelMember).lastPathComponent)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: installed.path) {
                let partial = directory.appending(path: ".\(kernelPackage.lastPathComponent).partial")
                let package = try await obtain(kernelPackage, sha256: kernelPackageSHA256, variable: kernelPackageVariable,
                                               partial: partial, label: "内核包", size: "约 700MB", log: log)
                log("解出内核 \(kernelMember)")
                let (_, kernel) = try ArchiveReader(file: package).extractFile(path: kernelMember)
                let temporary = directory.appending(path: ".\(installed.lastPathComponent).\(getpid())")
                defer { try? FileManager.default.removeItem(at: temporary) }
                try kernel.write(to: temporary)
                try FileManager.default.moveItem(at: temporary, to: installed)
                // 内核解出来了，包就不要了（用户自己给的不动）
                try? FileManager.default.removeItem(at: partial)
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
    private static func installRunc(at installed: URL, log: @escaping @Sendable (String) -> Void) async throws(NapboxError) {
        guard !FileManager.default.fileExists(atPath: installed.path) else { return }
        let directory = installed.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let partial = directory.appending(path: ".\(installed.lastPathComponent).partial")
            let file = try await obtain(runcBinary, sha256: runcSHA256, variable: runcVariable,
                                        partial: partial, label: "runc", size: "约 10MB", log: log)
            if file == partial {
                try FileManager.default.moveItem(at: partial, to: installed)
            } else {
                // 用户给的可能和这里不在一个盘上：先拷到旁边再改名
                let temporary = directory.appending(path: ".\(installed.lastPathComponent).\(getpid())")
                defer { try? FileManager.default.removeItem(at: temporary) }
                try FileManager.default.copyItem(at: file, to: temporary)
                try FileManager.default.moveItem(at: temporary, to: installed)
            }
        } catch let error as NapboxError {
            throw error
        } catch {
            throw NapboxError(.runtimeUnavailable, "准备 runc 失败：\(error)")
        }
    }

    /// 拿到一份校验过的文件：设了 variable 就用它指的文件，否则下载到 partial（接着上次的下）。
    /// 下载的校验不对就删掉，下次从头下。同一目录里别的 .partial（旧版本没下完的）删掉。
    static func obtain(_ url: URL, sha256 expected: String, variable: String, partial: URL, label: String, size: String,
                       environment: [String: String] = ProcessInfo.processInfo.environment,
                       log: @escaping @Sendable (String) -> Void) async throws(NapboxError) -> URL {
        removeOtherPartials(besides: partial)
        if let given = environment[variable], !given.isEmpty {
            let file = URL(filePath: given)
            log("\(label)：用 \(variable) 指的文件 \(file.path)，不下载")
            let digest: String
            do {
                digest = try sha256(of: file)
            } catch {
                throw NapboxError(.runtimeUnavailable, "读不了 \(variable) 指的文件 \(file.path)：\(error.localizedDescription)")
            }
            guard digest == expected else {
                throw NapboxError(.runtimeUnavailable,
                                  "\(variable) 指的文件 \(file.path) 校验值不对：应该是 \(expected)，这个文件是 \(digest)。要的是 \(url.absoluteString)")
            }
            return file
        }
        log("\(label)：下载 \(url.absoluteString)（\(size)）。慢的话可以自己下好，设 \(variable)=<文件路径> 再运行 setup")
        try await Download.resume(url, into: partial, label: label, log: log)
        let digest: String
        do {
            digest = try sha256(of: partial)
        } catch {
            throw NapboxError(.runtimeUnavailable, "读不了下载的文件 \(partial.path)：\(error.localizedDescription)")
        }
        guard digest == expected else {
            try? FileManager.default.removeItem(at: partial)
            throw NapboxError(.runtimeUnavailable, "\(label)：校验值不对，应该是 \(expected)，下载到的是 \(digest)。已删掉，再运行一次 setup 会重新下载")
        }
        return partial
    }

    private static func removeOtherPartials(besides partial: URL) {
        let directory = partial.deletingLastPathComponent()
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        for name in names where name.hasPrefix(".") && name.hasSuffix(".partial") && name != partial.lastPathComponent {
            try? FileManager.default.removeItem(at: directory.appending(path: name))
        }
    }

    /// vminit 由框架从 ghcr.io 拉：接不着下，断了整个重拉。框架只认 HTTPS_PROXY，不看系统代理，这里把系统代理告诉它。
    private static func installVminit(supportDirectory: URL, log: @escaping @Sendable (String) -> Void) async throws(NapboxError) {
        let store: ImageStore
        do {
            store = try Runtime.openImageStore(supportDirectory: supportDirectory)
            if (try? await store.get(reference: Runtime.vminitReference)) != nil { return }
        } catch {
            throw NapboxError(.runtimeUnavailable, "打不开镜像库：\(error)")
        }
        if let proxy = useSystemProxy(for: URL(string: "https://ghcr.io/")!) { log("拉 vminit 走系统代理 \(proxy)") }
        log("拉取 vminit 镜像 \(Runtime.vminitReference)（约 70MB）")
        var attempt = 0
        while true {
            do {
                try await pullWatched(store, reference: Runtime.vminitReference, label: "vminit", log: log)
                return
            } catch {
                guard attempt < vminitRetryDelays.count else {
                    throw NapboxError(.runtimeUnavailable, "拉取 vminit 镜像失败：\(error)")
                }
                let delay = vminitRetryDelays[attempt]
                attempt += 1
                log("拉取 vminit 中断（\(error)），\(delay.components.seconds) 秒后从头重拉")
                try? await Task.sleep(for: delay)
            }
        }
    }

    private struct Stalled: Error, CustomStringConvertible {
        var description: String { "\(vminitIdleTimeout.components.seconds) 秒没收到数据" }
    }

    /// 拉镜像，同时盯着进度：太久没收到数据就停掉它（取消会关掉框架的连接）
    private static func pullWatched(_ store: ImageStore, reference: String, label: String,
                                    log: @escaping @Sendable (String) -> Void) async throws {
        struct State {
            var lastActivity = ContinuousClock.now
            var steps = ProgressSteps()
        }
        let state = Mutex(State())
        let progress: ProgressHandler = { events in
            let line = state.withLock { state -> String? in
                state.lastActivity = .now
                for event in events {
                    switch event {
                    case .addTotalSize(let size): state.steps.total += size
                    case .addSize(let size): state.steps.received += size
                    default: break
                    }
                }
                // 框架先报清单（几百字节）再报层，总量中途才变大：等层的大小算进来了再开始报
                return state.steps.total >= 1_048_576 ? state.steps.next() : nil
            }
            if let line { log("\(label)：\(line)") }
        }
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { _ = try await store.getInitImage(reference: reference, progress: progress) }
            group.addTask {
                while true {
                    try await Task.sleep(for: .seconds(5))
                    if ContinuousClock.now - state.withLock({ $0.lastActivity }) > vminitIdleTimeout { throw Stalled() }
                }
            }
            try await group.next()
            group.cancelAll()
        }
    }

    /// 系统设置里给这个地址配了 HTTPS 代理、又没设 HTTPS_PROXY 时，把它设成 HTTPS_PROXY（只影响 prepare 这个进程）。
    /// 返回用的代理；没设、自动配置（PAC）、SOCKS 的不管。
    private static func useSystemProxy(for url: URL) -> String? {
        let environment = ProcessInfo.processInfo.environment
        guard environment["HTTPS_PROXY"] == nil, environment["https_proxy"] == nil,
              let settings = CFNetworkCopySystemProxySettings()?.takeRetainedValue() else { return nil }
        let proxies = CFNetworkCopyProxiesForURL(url as CFURL, settings).takeRetainedValue() as? [[CFString: Any]] ?? []
        guard let first = proxies.first, (first[kCFProxyTypeKey] as? String) == (kCFProxyTypeHTTPS as String),
              let host = first[kCFProxyHostNameKey] as? String, let port = first[kCFProxyPortNumberKey] as? Int else { return nil }
        let proxy = "http://\(host):\(port)"
        setenv("HTTPS_PROXY", proxy, 1)
        return proxy
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

    static func sha256(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hash = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty { hash.update(data: chunk) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
