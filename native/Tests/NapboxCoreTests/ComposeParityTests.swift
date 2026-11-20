// 和 docker compose 对过的几处行为（2026-11-13，docker compose config 5.1.4），以及读 compose 时不该悄悄放过的写法。
import Foundation
import Testing
@testable import NapboxCore
import NapboxProtocol

@Suite struct ComposeParityTests {
    @Test func emptyKeysInOverrideKeepBase() throws {
        let base = """
        services:
          api:
            image: alpine
            command: [sleep, "1"]
            entrypoint: [/bin/sh]
            environment: {A: "1"}
            ports: ["3100"]
            volumes: [data:/data]
        volumes: {data: {}}
        """
        // 下面的条目都注释掉了：只剩键，值是空的
        let override = """
        services:
          api:
            image:
            command:
            environment:
            #  B: "2"
            ports:
            volumes:
        """
        let p = try load(["compose.yaml": base, "over.yaml": override], order: ["compose.yaml", "over.yaml"])
        let api = try #require(p.services.first { $0.name == "api" })
        #expect(api.image == "alpine")
        #expect(api.environment["A"] == "1")
        #expect(api.ports == [3100])
        #expect(api.namedVolumes.map(\.volume) == ["data"])
        #expect(api.command == nil, "command 是整个替换的，空值就是清掉")
        #expect(api.entrypoint == ["/bin/sh"], "没写的照旧")

        let emptyFile = try load(["compose.yaml": base, "over.yaml": "# 全注释掉了\n"], order: ["compose.yaml", "over.yaml"])
        #expect(emptyFile.services.map(\.name) == ["api"])
    }

    @Test func customYamlTagsAreRejected() throws {
        let found = try issues(["compose.yaml": """
        services:
          api:
            image: alpine
            ports: !reset []
            volumes: !override [data:/data]
        """])
        #expect(found.mentions("services.api.ports：不支持 YAML 标签 !reset"))
        #expect(found.mentions("services.api.volumes：不支持 YAML 标签 !override"))
        // 标准的标签照常
        #expect(try load(["compose.yaml": "services:\n  api:\n    image: !!str alpine\n"]).services.first?.image == "alpine")
    }

    @Test func dotEnvFollowsCompose() throws {
        // shell 里的变量优先于 .env 里前面定义的
        let parsed = Dictionary(uniqueKeysWithValues: try DotEnv.parse("A=1\nB=${A}\nC=${ONLY_FILE}\nONLY_FILE=x\n", file: ".env") {
            $0 == "A" ? "2" : nil
        })
        #expect(parsed["B"] == "2")
        #expect(parsed["C"] == "", "用到的时候还没定义")

        // 转义出来的 $ 是字面的
        let escaped = Dictionary(uniqueKeysWithValues: try DotEnv.parse(#"P="pa\$word""#, file: ".env") { _ in "不该用到" })
        #expect(escaped["P"] == "pa$word")

        // 行尾注释前面要有空格；等号后面紧跟的 # 是值
        let comments = Dictionary(uniqueKeysWithValues: try DotEnv.parse("K1= # 是值\nK2=v #注释\nK3=#x\n", file: ".env") { _ in nil })
        #expect(comments == ["K1": "# 是值", "K2": "v", "K3": "#x"])

        #expect { try DotEnv.parse("KEY value\n", file: ".env") { _ in nil } } throws: { error in
            (error as? ComposeError)?.issues.mentions(".env 第 1 行：看不懂这一行") == true
        }
    }

    @Test func projectNameIsAlwaysDefined() throws {
        let compose = "services:\n  api:\n    image: alpine\n    environment: {P: \"${COMPOSE_PROJECT_NAME}\"}\n"
        func value(_ files: [String: String], env: [String: String] = [:]) throws -> String? {
            let p = try load(files, env: env)
            #expect(p.unsetVariables.isEmpty)
            return p.services.first?.environment["P"]
        }
        #expect(try value(["compose.yaml": "name: demo\n" + compose]) == "demo")
        #expect(try value(["compose.yaml": "name: demo\n" + compose, ".env": "COMPOSE_PROJECT_NAME=from-file\n"]) == "from-file")
        #expect(try value(["compose.yaml": "name: demo\n" + compose], env: ["COMPOSE_PROJECT_NAME": "from-shell"]) == "from-shell")
        // 都没给：项目目录名（withProject 建的是 napbox-test-<UUID>），小写
        let fromDirectory = try #require(try value(["compose.yaml": compose]))
        #expect(fromDirectory.hasPrefix("napbox-test-") && fromDirectory == fromDirectory.lowercased())

        // loadNamed 给出的就是这个名字（napbox save 给没写 image 的服务起镜像名用）
        func named(_ files: [String: String], env: [String: String] = [:]) throws -> String {
            try withProject(files) { dir in
                try ComposeLoader.loadNamed(ComposeInput(files: [dir.appending(path: "compose.yaml")], callerEnvironment: env)).name
            }
        }
        #expect(try named(["compose.yaml": "name: demo\n" + compose]) == "demo")
        #expect(try named(["compose.yaml": "name: demo\n" + compose], env: ["COMPOSE_PROJECT_NAME": "from-shell"]) == "from-shell")
        #expect(try named(["compose.yaml": compose]).hasPrefix("napbox-test-"))
    }

    @Test func composeFileVariable() throws {
        try withProject(["compose.yaml": "", "a.yaml": "", "sub/b.yaml": "", ".napbox.yaml": ""]) { root in
            try FileManager.default.removeItem(at: root.appending(path: ".napbox.yaml"))
            func names(_ environment: [String: String], explicit: [String] = []) throws -> [String] {
                try ComposeFiles.resolve(explicit: explicit, environment: environment, cwd: root, worktree: root)
                    .map { $0.path.replacingOccurrences(of: root.path + "/", with: "") }
            }
            #expect(try names([:]) == ["compose.yaml"])
            #expect(try names(["COMPOSE_FILE": "a.yaml:sub/b.yaml"]) == ["a.yaml", "sub/b.yaml"])
            #expect(try names(["COMPOSE_FILE": "a.yaml,sub/b.yaml", "COMPOSE_PATH_SEPARATOR": ","]) == ["a.yaml", "sub/b.yaml"])
            #expect(try names(["COMPOSE_FILE": "a.yaml"], explicit: ["compose.yaml"]) == ["compose.yaml"], "-f 优先")
            #expect { try names(["COMPOSE_FILE": "nope.yaml"]) } throws: { ($0 as? NapboxError)?.code == "compose_not_found" }

            // cwd 的 .env 里写的也算，调用方环境里的优先
            try "COMPOSE_FILE=sub/b.yaml\n".write(to: root.appending(path: ".env"), atomically: true, encoding: .utf8)
            #expect(try names([:]) == ["sub/b.yaml"])
            #expect(try names(["COMPOSE_FILE": "a.yaml"]) == ["a.yaml"])

            // .napbox.yaml 是专门写给 napbox 的，比 COMPOSE_FILE 优先
            try "compose: a.yaml\n".write(to: root.appending(path: ".napbox.yaml"), atomically: true, encoding: .utf8)
            #expect(try names(["COMPOSE_FILE": "sub/b.yaml"]) == ["a.yaml"])
        }
    }

    @Test func runKeepsPortVariables() throws {
        let files = ["compose.yaml": """
        services:
          api:
            image: alpine
            ports: ["3100"]
            environment: {PUBLIC_ORIGIN: "http://${NAPBOX_API_3100}"}
        """]
        let p = try load(files, run: ComposeRun(service: "api", command: ["npm", "test"]))
        let api = try #require(p.services.first)
        #expect(api.ports == [3100])
        #expect(PortReferences.names(in: api.environment["PUBLIC_ORIGIN"] ?? "") == ["NAPBOX_API_3100"])
    }

    @Test func absurdNumbersAreInvalidNotFatal() {
        #expect(ComposeValues.bytes("infg") == nil)
        #expect(ComposeValues.bytes("1e30g") == nil)
        #expect(ComposeValues.bytes("nanm") == nil)
        #expect(ComposeValues.bytes("1.5g") == 1536 * 1024 * 1024)
        #expect(ComposeValues.seconds("inf") == nil)
        #expect(ComposeValues.seconds("nan") == nil)
    }
}

@Suite struct UnmountedVolumeTests {
    @Test func worktreeOnUnmountedVolumeIsUnknown() throws {
        let volumes = FileManager.default.temporaryDirectory.appending(path: "napbox-test-\(UUID().uuidString)").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: volumes, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: volumes) }
        let project = volumes.appending(path: "Ext/proj").path
        func check() -> WorktreePresence { WorktreePresence.check(worktree: project, mainRepository: project, volumesRoot: volumes.path) }

        // 挂载点不在：卷没挂上，判断不了
        #expect(check() == .unknown("\(project) 所在的卷 \(volumes.path)/Ext 没挂载"))
        // 挂载点在、目录不在：确实删了
        try FileManager.default.createDirectory(at: volumes.appending(path: "Ext"), withIntermediateDirectories: true)
        #expect(check() == .gone("目录 \(project) 不在了"))
    }

    @Test func unreadableStateFileIsNotTreatedAsMissing() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "napbox-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: "state.json")
        try Data(#"{"version":1,"environments":[]}"#.utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: url.path)
        #expect { try StateStore(url: url) } throws: { ($0 as? NapboxError)?.code == "state_corrupted" }
    }
}
