import Foundation
import Testing
@testable import NapboxCore
import NapboxProtocol

/// up 时记下读过哪些文件，之后看它们改没改过（ComposeSource）。
@Suite struct ComposeSourceTests {
    /// 和 napboxd 的 readCompose 一样：找文件、读出来，把碰过的文件合成一份
    private func source(in dir: URL, explicit: [String] = [], environment: [String: String] = [:], cwd: String? = nil,
                        access: HostAccess = .open) throws -> ComposeSource {
        let from = cwd.map { dir.appending(path: $0) } ?? dir
        let found = try ComposeFiles.locate(explicit: explicit, environment: environment, cwd: from, worktree: dir, access: access)
        let loaded = try ComposeLoader.loadDetailed(ComposeInput(files: found.files, callerEnvironment: environment, access: access))
        return ComposeSource(loaded.files + found.seen)
    }

    private func write(_ text: String, _ name: String, in dir: URL) throws {
        let url = dir.appending(path: name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private static let compose = "services:\n  app:\n    image: alpine\n"

    @Test func nothingChangedRightAfterReading() throws {
        try withProject(["compose.yaml": Self.compose, ".env": "A=1\n"]) { dir in
            let source = try source(in: dir)
            #expect(source.changes(access: .open).isEmpty)
            #expect(source.changeSummary(access: .open, relativeTo: dir.path) == nil)
            // 内容没变、只是重新写了一遍（时间变了）：不算改过
            try write(Self.compose, "compose.yaml", in: dir)
            #expect(source.changes(access: .open).isEmpty)
        }
    }

    @Test func editedComposeAndDotEnvAreReported() throws {
        try withProject(["compose.yaml": Self.compose, ".env": "A=1\n"]) { dir in
            let source = try source(in: dir)
            try write(Self.compose + "# 只加了注释\n", "compose.yaml", in: dir)
            #expect(source.changeSummary(access: .open, relativeTo: dir.path) == "compose.yaml")
            try write("A=2\n", ".env", in: dir)
            #expect(source.changeSummary(access: .open, relativeTo: dir.path) == "compose.yaml、.env")
            // 改回去就不算了
            try write(Self.compose, "compose.yaml", in: dir)
            try write("A=1\n", ".env", in: dir)
            #expect(source.changes(access: .open).isEmpty)
        }
    }

    @Test func filesThatAppearOrDisappearAreReported() throws {
        try withProject(["compose.yaml": Self.compose]) { dir in
            let source = try source(in: dir)
            // 那次没有的 .env、override、.napbox.yaml，之后冒出来都会改变读到的定义
            try write("A=1\n", ".env", in: dir)
            #expect(source.changeSummary(access: .open, relativeTo: dir.path) == ".env（新加的）")
            try FileManager.default.removeItem(at: dir.appending(path: ".env"))
            try write("services: {}\n", "compose.override.yaml", in: dir)
            #expect(source.changeSummary(access: .open, relativeTo: dir.path) == "compose.override.yaml（新加的）")
            try FileManager.default.removeItem(at: dir.appending(path: "compose.override.yaml"))
            try write("compose: other.yaml\n", ".napbox.yaml", in: dir)
            #expect(source.changeSummary(access: .open, relativeTo: dir.path) == ".napbox.yaml（新加的）")
            try FileManager.default.removeItem(at: dir.appending(path: ".napbox.yaml"))
            #expect(source.changes(access: .open).isEmpty)
            try FileManager.default.removeItem(at: dir.appending(path: "compose.yaml"))
            #expect(source.changeSummary(access: .open, relativeTo: dir.path) == "compose.yaml（没了）")
        }
    }

    @Test func higherPriorityNameAppearing() throws {
        // 读的是 docker-compose.yml；之后多了 compose.yaml，再 up 读的就是它了
        try withProject(["docker-compose.yml": Self.compose]) { dir in
            let source = try source(in: dir)
            #expect(source.files.contains { $0.path == dir.appending(path: "compose.yaml").path && $0.digest == nil })
            try write(Self.compose, "compose.yaml", in: dir)
            #expect(source.changeSummary(access: .open, relativeTo: dir.path) == "compose.yaml（新加的）")
        }
    }

    @Test func composeInParentDirectory() throws {
        // 从子目录往上找到的：子目录里冒出 compose 文件也算
        try withProject(["compose.yaml": Self.compose, "sub/keep": ""]) { dir in
            let source = try source(in: dir, cwd: "sub")
            #expect(source.changes(access: .open).isEmpty)
            try write(Self.compose, "sub/compose.yaml", in: dir)
            #expect(source.changeSummary(access: .open, relativeTo: dir.path) == "sub/compose.yaml（新加的）")
        }
    }

    @Test func envFileIsPartOfTheDefinition() throws {
        // env_file 的内容是 up 时读进定义的，改了同样要重新 up
        let compose = "services:\n  app:\n    image: alpine\n    env_file:\n      - app.env\n      - path: optional.env\n        required: false\n"
        try withProject(["compose.yaml": compose, "app.env": "A=1\n"]) { dir in
            let source = try source(in: dir)
            #expect(source.changes(access: .open).isEmpty)
            try write("A=2\n", "app.env", in: dir)
            #expect(source.changeSummary(access: .open, relativeTo: dir.path) == "app.env")
            try write("A=1\n", "app.env", in: dir)
            try write("B=1\n", "optional.env", in: dir)
            #expect(source.changeSummary(access: .open, relativeTo: dir.path) == "optional.env（新加的）")
        }
    }

    @Test func napboxYamlAndExplicitFiles() throws {
        try withProject([".napbox.yaml": "compose: server/compose.yaml\n", "server/compose.yaml": Self.compose,
                         "other.yaml": Self.compose]) { dir in
            let configured = try source(in: dir)
            try write("compose: other.yaml\n", ".napbox.yaml", in: dir)
            #expect(configured.changeSummary(access: .open, relativeTo: dir.path) == ".napbox.yaml")
            // -f 指定的：只看指定的文件和它旁边的 .env，.napbox.yaml 没读过，改了不算
            let explicit = try source(in: dir, explicit: ["other.yaml"])
            try write("compose: server/compose.yaml\n", ".napbox.yaml", in: dir)
            #expect(explicit.changes(access: .open).isEmpty)
            try write(Self.compose + "\n", "other.yaml", in: dir)
            #expect(explicit.changeSummary(access: .open, relativeTo: dir.path) == "other.yaml")
        }
    }

    @Test func pathsOutsideTheDirectoryStayAbsolute() throws {
        try withProject(["a/compose.yaml": Self.compose]) { dir in
            let source = try source(in: dir.appending(path: "a"))
            try write(Self.compose + "\n", "a/compose.yaml", in: dir)
            let outside = dir.appending(path: "b").path
            #expect(source.changeSummary(access: .open, relativeTo: outside) == dir.appending(path: "a/compose.yaml").path)
        }
    }

    @Test func sameFileUnderTwoSpellingsIsOneEntry() throws {
        // 启动目录是经过符号链接进来的（macOS 的 /var、/tmp 也是这种）：找 COMPOSE_FILE 时按给的写法读它的 .env，
        // 往上找 compose 时用的是解开以后的目录，读的是同一个 .env。只记一条，提示里也只列一次
        try withProject(["compose.yaml": Self.compose, ".env": "A=1\n"]) { dir in
            let link = dir.deletingLastPathComponent().appending(path: "napbox-test-link-\(UUID().uuidString)")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: dir)
            defer { try? FileManager.default.removeItem(at: link) }
            let found = try ComposeFiles.locate(explicit: [], environment: [:], cwd: link, worktree: dir, access: .open)
            let loaded = try ComposeLoader.loadDetailed(ComposeInput(files: found.files, callerEnvironment: [:], access: .open))
            #expect((loaded.files + found.seen).filter { $0.path.hasSuffix("/.env") }.count == 2)
            let source = ComposeSource(loaded.files + found.seen)
            #expect(source.files.filter { $0.path.hasSuffix("/.env") }.count == 1)
            #expect(source.changes(access: .open).isEmpty)
            try write("A=2\n", ".env", in: dir)
            // 代码目录给的是哪种写法都一样
            #expect(source.changeSummary(access: .open, relativeTo: dir.path) == ".env")
            #expect(source.changeSummary(access: .open, relativeTo: link.path) == ".env")
        }
    }

    @Test func unreadableFileIsReported() throws {
        try withProject(["compose.yaml": Self.compose]) { dir in
            let source = try source(in: dir)
            try Data([0xff, 0xfe, 0x00]).write(to: dir.appending(path: "compose.yaml"))
            #expect(source.changeSummary(access: .open, relativeTo: dir.path) == "compose.yaml（读不了）")
        }
    }

    @Test func recordSurvivesTheStateFile() throws {
        // 存进登记再读出来是同一份；看过但不存在的文件（digest 是 nil）也留着
        try withProject(["compose.yaml": Self.compose]) { dir in
            let source = try source(in: dir)
            #expect(source.files.contains { $0.digest == nil })
            let decoded = try JSONDecoder().decode(ComposeSource.self, from: JSONEncoder().encode(source))
            #expect(decoded == source)
            // 旧的登记里没有这两项：读出来是没有，不报错
            var record = EnvironmentRecord(name: "p/main", project: "p", mainRepository: dir.path, worktree: dir.path, owner: .worktree,
                                           hostname: "main--p.localhost")
            var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(record)) as! [String: Any]
            #expect(json["source"] == nil && json["rebuildDeferred"] == nil)
            record.source = source
            record.rebuildDeferred = true
            json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(record)) as! [String: Any]
            #expect(json["source"] != nil && json["rebuildDeferred"] as? Bool == true)
        }
    }
}
