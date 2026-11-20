// 根文件系统模板：一个镜像只解一次，之后都克隆；克隆出来的各是各的；镜像不在了模板就删。
// 这里不真的解镜像，“解包”就是往给的路径写一个文件。
import Foundation
import NapboxProtocol
@testable import NapboxRuntime
import Testing

struct RootfsTemplatesTests {
    /// 记下解了几次
    private actor Counter {
        var count = 0
        func add() { count += 1 }
    }

    private struct UnpackFailed: Error {}

    private let root = FileManager.default.temporaryDirectory.appending(path: "nbx-templates-\(UUID().uuidString)")
    private var directory: URL { root.appending(path: NapboxVersion.current) }

    private func files() -> [String] { ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []).sorted() }

    /// 要一份 digest 这个镜像的根文件系统，放到 root 旁边的 name 里
    private func clone(_ templates: RootfsTemplates, _ digest: String, to name: String, counter: Counter,
                       content: String = "image") async throws -> (unpacked: Bool, path: URL) {
        let path = root.appending(path: "../\(root.lastPathComponent)-\(name)").standardizedFileURL
        let unpacked = try await templates.clone(digest, to: path) { template in
            await counter.add()
            try Data(content.utf8).write(to: template)
        }
        return (unpacked, path)
    }

    private func cleanUp(_ paths: URL...) {
        for path in paths + [root] { try? FileManager.default.removeItem(at: path) }
    }

    @Test func imageIsUnpackedOnceThenCloned() async throws {
        let templates = RootfsTemplates(root: root), counter = Counter()
        let first = try await clone(templates, "sha256:aa", to: "first", counter: counter)
        let second = try await clone(templates, "sha256:aa", to: "second", counter: counter)
        defer { cleanUp(first.path, second.path) }
        #expect(first.unpacked)
        #expect(!second.unpacked)
        #expect(await counter.count == 1)
        #expect(try String(contentsOf: second.path, encoding: .utf8) == "image")
        #expect(files() == ["sha256-aa.ext4"])
    }

    /// 服务往自己的根文件系统里写东西，模板和别的服务的那份都不变
    @Test func writingToACloneLeavesTemplateAndOtherClonesAlone() async throws {
        let templates = RootfsTemplates(root: root), counter = Counter()
        let first = try await clone(templates, "sha256:aa", to: "first", counter: counter)
        try Data("written by the container".utf8).write(to: first.path)
        let second = try await clone(templates, "sha256:aa", to: "second", counter: counter)
        defer { cleanUp(first.path, second.path) }
        #expect(try String(contentsOf: second.path, encoding: .utf8) == "image")
    }

    /// 几个环境同时起、要同一个镜像：只解一次，只有一个算新解的
    @Test func concurrentRequestsForTheSameImageUnpackOnce() async throws {
        let templates = RootfsTemplates(root: root), counter = Counter()
        let results = try await withThrowingTaskGroup(of: (unpacked: Bool, path: URL).self) { group in
            for i in 0..<4 {
                group.addTask {
                    let path = root.appending(path: "../\(root.lastPathComponent)-worker\(i)").standardizedFileURL
                    let unpacked = try await templates.clone("sha256:aa", to: path) { template in
                        await counter.add()
                        try await Task.sleep(for: .milliseconds(100))
                        try Data("image".utf8).write(to: template)
                    }
                    return (unpacked, path)
                }
            }
            var all: [(unpacked: Bool, path: URL)] = []
            for try await result in group { all.append(result) }
            return all
        }
        defer { for result in results { cleanUp(result.path) } }
        #expect(await counter.count == 1)
        #expect(results.filter(\.unpacked).count == 1)
        for result in results { #expect(try String(contentsOf: result.path, encoding: .utf8) == "image") }
    }

    /// 解包失败：不留模板，也不留解到一半的文件；下次要的时候重新解
    @Test func failedUnpackLeavesNothingAndIsRetried() async throws {
        let templates = RootfsTemplates(root: root), counter = Counter()
        let path = root.appending(path: "../\(root.lastPathComponent)-failed").standardizedFileURL
        defer { cleanUp(path) }
        await #expect(throws: UnpackFailed.self) {
            _ = try await templates.clone("sha256:aa", to: path) { template in
                try Data("half".utf8).write(to: template)
                throw UnpackFailed()
            }
        }
        #expect(files().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: path.path))
        let retried = try await clone(templates, "sha256:aa", to: "failed", counter: counter)
        #expect(retried.unpacked)
        #expect(try String(contentsOf: retried.path, encoding: .utf8) == "image")
    }

    /// 镜像库里没有这个镜像了：模板删掉，还在的留着；下次要删掉的那个时重新解
    @Test func purgeRemovesTemplatesOfImagesNoLongerInTheStore() async throws {
        let templates = RootfsTemplates(root: root), counter = Counter()
        let kept = try await clone(templates, "sha256:aa", to: "kept", counter: counter)
        let gone = try await clone(templates, "sha256:bb", to: "gone", counter: counter)
        defer { cleanUp(kept.path, gone.path) }
        await templates.purge(keeping: ["sha256:aa"])
        #expect(files() == ["sha256-aa.ext4"])
        // 已经克隆出去的不受影响
        #expect(try String(contentsOf: gone.path, encoding: .utf8) == "image")
        try FileManager.default.removeItem(at: gone.path)
        let again = try await clone(templates, "sha256:bb", to: "gone", counter: counter)
        #expect(again.unpacked)
        #expect(await counter.count == 3)
    }

    /// napboxd 被杀时留下的解到一半的文件、升级前的版本留下的模板：都删掉
    @Test func purgeRemovesLeftoversFromKilledUnpacksAndOtherVersions() async throws {
        let templates = RootfsTemplates(root: root), counter = Counter()
        let kept = try await clone(templates, "sha256:aa", to: "kept", counter: counter)
        defer { cleanUp(kept.path) }
        try Data("half".utf8).write(to: directory.appending(path: "sha256-cc.partial"))
        let old = root.appending(path: "0.0.1")
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
        try Data("old".utf8).write(to: old.appending(path: "sha256-aa.ext4"))
        await templates.purge(keeping: ["sha256:aa"])
        #expect(files() == ["sha256-aa.ext4"])
        #expect(!FileManager.default.fileExists(atPath: old.path))
    }

    /// 正在解的时候清理：解到一半的那份不能被当成没人要的删掉
    @Test func purgeLeavesAnUnpackInProgressAlone() async throws {
        let templates = RootfsTemplates(root: root), counter = Counter()
        let path = root.appending(path: "../\(root.lastPathComponent)-slow").standardizedFileURL
        defer { cleanUp(path) }
        let (started, startedContinuation) = AsyncStream<Void>.makeStream()
        let (resume, resumeContinuation) = AsyncStream<Void>.makeStream()
        let unpacking = Task {
            try await templates.clone("sha256:aa", to: path) { template in
                await counter.add()
                try Data("image".utf8).write(to: template)
                startedContinuation.yield()
                for await _ in resume { break }
            }
        }
        for await _ in started { break }
        await templates.purge(keeping: ["sha256:aa"])
        resumeContinuation.yield()
        #expect(try await unpacking.value)
        #expect(try String(contentsOf: path, encoding: .utf8) == "image")
    }
}
