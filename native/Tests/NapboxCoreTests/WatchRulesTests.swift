import Foundation
import Testing
@testable import NapboxCore
import NapboxProtocol

@Suite struct IgnorePatternsTests {
    @Test func dockerignoreStyle() {
        let p = IgnorePatterns(["# 注释", "", "*.log", "dist/", "/only-root", "**/secret", "docs/*", "!docs/keep.md", "a?c"])
        #expect(p.matches("x.log"))
        #expect(!p.matches("sub/x.log")) // * 不跨目录
        #expect(p.matches("dist"))
        #expect(p.matches("dist/a/b.js")) // 目录下的都算
        #expect(p.matches("only-root"))
        #expect(!p.matches("sub/only-root"))
        #expect(p.matches("secret"))
        #expect(p.matches("a/b/secret"))
        #expect(p.matches("docs/a.md"))
        #expect(!p.matches("docs/keep.md")) // 后面的优先
        #expect(p.matches("abc"))
        #expect(!p.matches("a/c"))
        #expect(!p.matches("src/main.ts"))
    }

    /// compose 会先规整路径，./node_modules/ 就是 node_modules
    @Test func dotSlashIsTheSameAsWithout() {
        let p = IgnorePatterns(["./node_modules/", "!./node_modules/keep", "sub/./x"])
        #expect(p.matches("node_modules/a"))
        #expect(!p.matches("node_modules/keep"))
        #expect(p.matches("sub/x"))
    }

    @Test func whitelistLikeClimbingProject() {
        let p = IgnorePatterns(["*", "!services/api/**", "!pnpm-lock.yaml"])
        #expect(p.matches("apps/x"))
        #expect(!p.matches("services/api/src/a.ts"))
        #expect(!p.matches("pnpm-lock.yaml"))
        #expect(p.hasNegation)
    }

    /// 特殊字符按字面算
    @Test func regexCharactersAreLiteral() {
        let p = IgnorePatterns(["a+b.c(1)"])
        #expect(p.matches("a+b.c(1)"))
        #expect(!p.matches("aab.c(1)"))
        #expect(!p.matches("a+bxc(1)"))
    }
}

@Suite struct WatchMatcherTests {
    private func service(_ rules: [WatchRule], build: Build? = nil, name: String = "api") -> Service {
        var s = Service(
            name: name, image: "x", build: build, command: nil, entrypoint: nil, environment: [:], workingDir: nil,
            initProcess: false, shmSizeBytes: nil, tmpfs: [], pullPolicy: nil, stopGracePeriodSeconds: nil,
            ports: [], expose: [], volumes: [], dependsOn: [], healthcheck: nil, restart: .no,
            memoryLimit: nil, keepAwake: false
        )
        s.watch = rules
        return s
    }

    private func rule(_ action: WatchRule.Action, _ path: String, target: String? = nil, ignore: [String] = [], include: [String] = [],
                      initial: Bool = false, exec: [String]? = nil) -> WatchRule {
        WatchRule(action: action, path: path, target: target, ignore: ignore, include: include, initialSync: initial, exec: exec)
    }

    private func matcher(_ services: [Service], files: [String: String] = [:]) -> WatchMatcher {
        WatchMatcher(project: ComposeProject(services: services, volumes: [], idleMinutes: nil, unsetVariables: []), canonical: { $0 }, readFile: { files[$0] })
    }

    @Test func syncMapsToTarget() {
        let m = matcher([service([rule(.sync, "/r/src", target: "/app/src")])])
        let plan = m.plan(service: "api", paths: ["/r/src/a/b.ts", "/r/other.ts"])
        #expect(plan.syncs == [.init(hostPath: "/r/src/a/b.ts", containerPath: "/app/src/a/b.ts")])
        #expect(!plan.rebuild && !plan.restart)
    }

    @Test func singleFileRuleMapsToTargetItself() {
        let m = matcher([service([rule(.sync, "/r/a.conf", target: "/etc/a.conf")])])
        #expect(m.plan(service: "api", paths: ["/r/a.conf"]).syncs == [.init(hostPath: "/r/a.conf", containerPath: "/etc/a.conf")])
        #expect(m.eventRoots { _ in false } == ["/r"])
        #expect(!m.watches("/r/a.conf.bak"))
    }

    @Test func everyMatchingRuleApplies() {
        let m = matcher([service([
            rule(.sync, "/r/src", target: "/app/src"),
            rule(.rebuild, "/r/src/package.json"),
            rule(.syncRestart, "/r/src/config", target: "/c"),
        ])])
        let plan = m.plan(service: "api", paths: ["/r/src/package.json", "/r/src/config/x"])
        #expect(plan.rebuild && plan.restart)
        #expect(plan.syncs.map(\.containerPath).sorted() == ["/app/src/config/x", "/app/src/package.json", "/c/x"])
    }

    @Test func ignoreIsRelativeToRulePath() {
        let m = matcher([service([rule(.sync, "/r/src", target: "/t", ignore: ["gen/", "*.log"])])])
        #expect(!m.watches("/r/src/gen/a.ts"))
        #expect(!m.watches("/r/src/x.log"))
        #expect(m.watches("/r/src/sub/x.log"))
        #expect(m.watches("/r/src/a.ts"))
    }

    @Test func includeOnly() {
        let m = matcher([service([rule(.rebuild, "/r", include: ["*.go"])])])
        #expect(m.concerns("/r/a.go", service: "api"))
        #expect(!m.concerns("/r/a.ts", service: "api"))
        #expect(m.watches("/r/moved"), "搬进来的目录要看，下面可能有 .go")
    }

    /// 目录不匹配 include 也要往下走：下面的文件可能匹配，漏了会在下次起环境时被当成删了
    @Test func includeDoesNotSkipDirectories() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "watch-\(UUID().uuidString)").resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: dir) }
        for name in ["sub/deep/a.py", "sub/b.ts", "ignored/c.py"] {
            let url = dir.appending(path: name)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("x".utf8).write(to: url)
        }
        let m = matcher([service([rule(.sync, dir.path, target: "/t", ignore: ["ignored"], include: ["**/*.py"])])])
        #expect(Set(m.scan(service: "api").keys).subtracting([dir.path]) == [dir.path + "/sub/deep/a.py"])
    }

    @Test func editorTemporaryFilesAndGitAreNeverWatched() {
        let m = matcher([service([rule(.sync, "/r", target: "/t")])])
        for path in ["/r/.git/index", "/r/sub/.git/x", "/r/a.ts~", "/r/.a.ts.swp", "/r/4913", "/r/.#a", "/r/#a#",
                     "/r/.idea/x", "/r/a___jb_tmp___", "/r/.DS_Store", "/r/.napbox/ports.json", "/r/.napbox-notify-3"] {
            #expect(!m.watches(path), "\(path)")
        }
        #expect(m.watches("/r/a.ts"))
    }

    /// 构建上下文的忽略文件也算：Dockerfile 旁边同名的优先
    @Test func contextIgnoreFile() {
        let build = Build(context: "/r", dockerfile: "svc/Dockerfile", target: nil, args: [:])
        var m = matcher([service([rule(.sync, "/r/src", target: "/t")], build: build)],
                        files: ["/r/.dockerignore": "src/a.ts\n", "/r/svc/Dockerfile.dockerignore": "src/b.ts\n"])
        #expect(m.watches("/r/src/a.ts"))
        #expect(!m.watches("/r/src/b.ts"))
        m = matcher([service([rule(.sync, "/r/src", target: "/t")], build: build)], files: ["/r/.dockerignore": "src/a.ts\n"])
        #expect(!m.watches("/r/src/a.ts"))
    }

    @Test func initialSyncOnlyRulesThatAskForIt() {
        let m = matcher([service([
            rule(.sync, "/r/a", target: "/a", initial: true),
            rule(.sync, "/r/b", target: "/b"),
            rule(.rebuild, "/r/c"),
            rule(.syncExec, "/r/d", target: "/d", initial: true, exec: ["x"]), // compose 的 sync+exec 没有 initial_sync
            rule(.syncRestart, "/r/e", target: "/e", initial: true),
        ])])
        let plan = m.plan(service: "api", paths: ["/r/a/1", "/r/b/2", "/r/c/3", "/r/d/4", "/r/e/5"], onlyInitialSync: true)
        #expect(plan.syncs.map(\.containerPath) == ["/a/1", "/e/5"])
        #expect(!plan.rebuild && plan.execs.isEmpty)
    }

    /// 目录的修改时间变了不算变：可能只是下面多了个被 ignore 的文件，不该为此重建
    @Test func directoryChangesOnlyByMode() {
        let dir = SourceFileStat(inode: 1, modifiedNanoseconds: 1, size: 64, mode: 0o755, isSymlink: false, isDirectory: true)
        var later = dir
        later.modifiedNanoseconds = 2
        later.size = 96
        #expect(later.unchanged(from: dir))
        later.mode = 0o700
        #expect(!later.unchanged(from: dir))
        #expect(!dir.unchanged(from: nil))
        let file = SourceFileStat(inode: 1, modifiedNanoseconds: 1, size: 64, mode: 0o644, isSymlink: false)
        var touched = file
        touched.modifiedNanoseconds = 2
        #expect(!touched.unchanged(from: file))
        #expect(!dir.unchanged(from: file), "文件换成目录")
    }

    @Test func imageTimestamps() {
        #expect(rfc3339Nanoseconds("1970-01-01T00:00:01Z") == 1_000_000_000)
        #expect(rfc3339Nanoseconds("1970-01-01T00:00:01.5Z") == 1_500_000_000)
        #expect(rfc3339Nanoseconds("1970-01-01T00:00:01.123456789Z") == 1_123_456_789)
        #expect(rfc3339Nanoseconds("1970-01-01T08:00:01.25+08:00") == 1_250_000_000)
        #expect(rfc3339Nanoseconds("不是时间") == nil)
    }

    @Test func execOncePerRule() {
        let m = matcher([service([rule(.syncExec, "/r/a", target: "/a", exec: ["reload"])])])
        #expect(m.plan(service: "api", paths: ["/r/a/1", "/r/a/2"]).execs == [["reload"]])
    }

    @Test func rulesBelongToTheirService() {
        let m = matcher([service([rule(.sync, "/r/a", target: "/a")], name: "x"), service([rule(.rebuild, "/r/a")], name: "y")])
        #expect(m.services == ["x", "y"])
        #expect(m.plan(service: "x", paths: ["/r/a/1"]).rebuild == false)
        #expect(m.plan(service: "y", paths: ["/r/a/1"]).syncs.isEmpty)
    }

    @Test func scanFindsFilesAndSkipsIgnored() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "watch-\(UUID().uuidString)").resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: dir) }
        for name in ["src/a.ts", "src/gen/b.ts", "src/.git/c", "src/sub/d.ts"] {
            let url = dir.appending(path: name)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("x".utf8).write(to: url)
        }
        let src = dir.appending(path: "src").path
        let m = matcher([service([rule(.sync, src, target: "/t", ignore: ["gen"])])])
        #expect(Set(m.scan(service: "api").keys) == [src, src + "/a.ts", src + "/sub", src + "/sub/d.ts"])
    }
}

@Suite struct WatchComposeTests {
    @Test func allActions() throws {
        let project = try load(["compose.yaml": """
        services:
          a:
            build: .
            develop:
              watch:
                - {action: sync, path: ./s, target: /s, ignore: [x], initial_sync: true}
                - {action: rebuild, path: ./pkg.json}
                - {action: restart, path: ./r}
                - {action: sync+restart, path: ./c, target: /c}
                - {action: sync+exec, path: ./e, target: /e, exec: {command: "kill -HUP 1"}}
        """])
        let rules = try #require(project.service("a")).watch
        #expect(rules.map(\.action) == [.sync, .rebuild, .restart, .syncRestart, .syncExec])
        #expect(rules[0].path.hasSuffix("/s") && rules[0].path.hasPrefix("/"))
        #expect(rules[0].ignore == ["x"] && rules[0].initialSync)
        #expect(rules[4].exec == ["kill", "-HUP", "1"])
    }

    /// docker compose config 实测：多份 compose 的 watch 是追加，不是替换
    @Test func multipleFilesAppend() throws {
        let project = try load(["compose.yaml": """
        services:
          a:
            build: .
            develop:
              watch:
                - {action: sync, path: ./a, target: /a}
        """, "dev.yaml": """
        services:
          a:
            develop:
              watch:
                - {action: sync, path: ./b, target: /b}
        """], order: ["compose.yaml", "dev.yaml"])
        #expect(try #require(project.service("a")).watch.map(\.target) == ["/a", "/b"])
    }

    @Test func invalidRules() throws {
        let found = try issues(["compose.yaml": """
        services:
          a:
            image: alpine
            develop:
              other: 1
              watch:
                - {action: bogus, path: ./a, target: /a}
                - {action: sync, path: ./a}
                - {action: sync, target: /a}
                - {path: ./a}
                - {action: rebuild, path: ./a}
                - {action: sync, path: ./a, target: relative}
                - {action: sync+exec, path: ./a, target: /a}
                - {action: sync+exec, path: ./a, target: /a, exec: {command: x, user: root}}
                - {action: sync, path: ./a, target: /a, unknown: 1}
        """]).map(\.description)
        for expected in ["develop.other", "只能是 sync", "sync 要写 target", "要写 path", "要写 action", "rebuild 要有 build", "要写容器里的绝对路径",
                         "sync+exec 要写 exec.command", "exec.user：只支持 command", "unknown：不支持"] {
            #expect(found.contains { $0.contains(expected) }, "没有报：\(expected)。实际：\(found)")
        }
    }
}
