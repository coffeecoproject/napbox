import Foundation
import Testing
@testable import NapboxCore
import NapboxProtocol

/// 把几份文件写到临时目录里再读，和真实用法一样经过 .env、合并、校验。
@discardableResult
func withProject<T>(_ files: [String: String], _ body: (URL) throws -> T) throws -> T {
    let dir = FileManager.default.temporaryDirectory.appending(path: "napbox-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    for (name, text) in files {
        let url = dir.appending(path: name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }
    return try body(dir.resolvingSymlinksInPath())
}

func load(_ files: [String: String], order: [String] = ["compose.yaml"], env: [String: String] = [:], profiles: [String] = [],
          run: ComposeRun? = nil) throws -> ComposeProject {
    try withProject(files) { dir in
        try ComposeLoader.load(ComposeInput(files: order.map { dir.appending(path: $0) }, callerEnvironment: env, profiles: profiles, run: run))
    }
}

func issues(_ files: [String: String], order: [String] = ["compose.yaml"], env: [String: String] = [:], run: ComposeRun? = nil) throws -> [ComposeIssue] {
    do {
        _ = try load(files, order: order, env: env, run: run)
        return []
    } catch let error as ComposeError {
        return error.issues
    }
}

extension [ComposeIssue] {
    func mentions(_ text: String) -> Bool { contains { $0.description.contains(text) } }
}

@Suite struct ComposeTests {
    @Test func fullService() throws {
        let p = try load([
            ".env": "PG_PORT=55433\nPG_TAG=17\n",
            "app.env": "FROM_FILE=1\nOVERRIDDEN=file\n",
            "compose.yaml": """
            name: demo
            x-napbox:
              idle_minutes: 15
            services:
              db:
                image: postgres:${PG_TAG}
                container_name: demo-db
                ports: ["127.0.0.1:${PG_PORT:-5432}:5432"]
                environment:
                  POSTGRES_PASSWORD: x
                  NUMBER: 5
                volumes: [pgdata:/var/lib/postgresql/data]
                healthcheck:
                  test: ["CMD-SHELL", "pg_isready -U postgres"]
                  interval: 1s
                  retries: 20
                mem_limit: 512m
                tmpfs: [/tmp]
                shm_size: 256m
              api:
                build:
                  context: ./api
                  target: dev
                  args: [NODE_ENV=development]
                command: npm run dev -- --host 0.0.0.0
                env_file: app.env
                environment:
                  - OVERRIDDEN=env
                  - FROM_CALLER
                ports:
                  - "3100:3100"
                  - target: 9229
                    published: "0"
                    host_ip: 127.0.0.1
                volumes:
                  - ./api:/app:cached
                  - ~/.npmrc:/root/.npmrc:ro
                depends_on:
                  db:
                    condition: service_healthy
                restart: on-failure:3
                stop_grace_period: 1m30s
                x-napbox:
                  memory: 2g
                  keep_awake: true
              worker:
                image: alpine
                depends_on: [db]
                deploy:
                  resources:
                    limits:
                      memory: 128m
            volumes:
              pgdata:
            """,
        ], env: ["FROM_CALLER": "c", "PG_TAG": "18"])

        #expect(p.services.map(\.name) == ["api", "db", "worker"])
        #expect(p.idleMinutes == 15)
        #expect(p.volumes == ["pgdata"])
        let db = try #require(p.service("db"))
        #expect(db.image == "postgres:18") // 调用方环境优先于 .env
        #expect(db.ports == [5432])
        #expect(db.environment == ["POSTGRES_PASSWORD": "x", "NUMBER": "5"])
        #expect(db.volumes == [VolumeMount(source: .named("pgdata"), target: "/var/lib/postgresql/data", readOnly: false)])
        #expect(db.healthcheck?.test == .shell("pg_isready -U postgres"))
        #expect(db.healthcheck?.intervalSeconds == 1)
        #expect(db.healthcheck?.retries == 20)
        #expect(db.healthcheck?.timeoutSeconds == 30)
        #expect(db.memoryBytes == 512 * 1024 * 1024)
        #expect(db.tmpfs == ["/tmp"])
        #expect(db.shmSizeBytes == 256 * 1024 * 1024)

        let api = try #require(p.service("api"))
        #expect(api.build?.context.hasSuffix("/api") == true)
        #expect(api.build?.target == "dev")
        #expect(api.build?.args == ["NODE_ENV": "development"])
        #expect(api.command == ["npm", "run", "dev", "--", "--host", "0.0.0.0"])
        #expect(api.environment == ["FROM_FILE": "1", "OVERRIDDEN": "env", "FROM_CALLER": "c"])
        #expect(api.ports == [3100, 9229])
        #expect(api.volumes.count == 2)
        #expect(api.volumes[1] == VolumeMount(
            source: .bind(FileManager.default.homeDirectoryForCurrentUser.appending(path: ".npmrc").standardizedFileURL.path),
            target: "/root/.npmrc", readOnly: true))
        #expect(api.dependsOn == [Dependency(service: "db", condition: .healthy)])
        #expect(api.restart == .onFailure(maxRetries: 3))
        #expect(api.stopGracePeriodSeconds == 90)
        #expect(api.memoryBytes == 2 * 1024 * 1024 * 1024)
        #expect(api.keepAwake)

        let worker = try #require(p.service("worker"))
        #expect(worker.dependsOn == [Dependency(service: "db", condition: .started)])
        #expect(worker.memoryBytes == 128 * 1024 * 1024)
        #expect(worker.listeningPorts.isEmpty)
    }

    @Test func defaultMemory() throws {
        let p = try load(["compose.yaml": "services:\n  a:\n    image: alpine\n"])
        #expect(p.services[0].memoryBytes == 1024 * 1024 * 1024)
    }

    @Test func unsupportedKeysAreErrors() throws {
        let found = try issues(["compose.yaml": """
        services:
          a:
            image: alpine
            cap_add: [NET_ADMIN]
            privileged: true
            network_mode: host
            platform: linux/amd64
            labels: {x: y}
        """])
        #expect(found.mentions("services.a.cap_add：会让服务改动网络规则"))
        #expect(found.mentions("services.a.privileged：会让服务改动网络规则"))
        #expect(found.mentions("services.a.network_mode：会让服务改动网络规则"))
        #expect(found.mentions("services.a.platform：第一版不支持（多用在 staging"))
        #expect(found.mentions("services.a.labels：第一版不支持"))
        #expect(found.count == 5)
        #expect(found.allSatisfy { if case .unsupported = $0 { true } else { false } })
    }

    @Test func topLevelUnsupported() throws {
        let found = try issues(["compose.yaml": """
        services:
          a: {image: alpine}
        configs:
          c: {file: ./c}
        networks:
          isolated:
            internal: true
            attachable: true
        x-other: ignored
        """])
        #expect(found.mentions("configs：第一版不支持这个顶层字段"))
        #expect(found.mentions("networks.isolated.attachable：napbox 把所有网络合成一个"))
        #expect(found.count == 2)
    }

    /// secrets：顶层声明的文件只读挂到 /run/secrets/<名字>，和 Docker 一样（CoffeeCo 的数据库这样拿密码）
    @Test func secretsBecomeReadOnlyFileMounts() throws {
        let p = try load(["compose.yaml": """
        services:
          db:
            image: postgres
            secrets: [admin_password, app_password]
            volumes: [./data:/data]
          other: {image: alpine}
        secrets:
          admin_password: {file: ./.local/admin.password}
          app_password: {file: /abs/app.password}
          unused: {file: ./unused}
        """])
        let db = try #require(p.service("db"))
        #expect(db.volumes.map(\.target) == ["/data", "/run/secrets/admin_password", "/run/secrets/app_password"])
        #expect(db.volumes.map(\.readOnly) == [false, true, true])
        // 记成 secret 而不是普通挂载：文件不存在时要报错，不能像普通挂载那样建成目录
        if case .secret(let file) = db.volumes[1].source { #expect(file.hasSuffix("/.local/admin.password")) } else { Issue.record("应该是 secret") }
        #expect(db.volumes[2].source == .secret("/abs/app.password"))
        #expect(try #require(p.service("other")).volumes.isEmpty)
        // 文件变化通知和“文件被整个换掉后重新挂”都按这份清单来，secrets 的文件也要在里面；没人用的不在
        #expect(p.sourcePaths.count == 3)
        #expect(p.sourcePaths.contains("/abs/app.password"))
        #expect(p.sourcePaths.contains { $0.hasSuffix("/.local/admin.password") })
    }

    @Test func secretsUnsupportedForms() throws {
        let found = try issues(["compose.yaml": """
        services:
          a:
            image: alpine
            secrets:
              - missing
              - source: s
                target: renamed
              - from_env
        secrets:
          s: {file: ./s, name: other}
          from_env: {environment: TOKEN}
        """])
        #expect(found.mentions("services.a.secrets：missing 没有在顶层 secrets 里声明"))
        #expect(found.mentions("services.a.secrets[1]：只支持直接写名字"))
        #expect(found.mentions("secrets.s.name：只支持 file"))
        #expect(found.mentions("secrets.from_env：只支持 file"))
        #expect(found.count == 4)
    }

    /// 多份 compose 里服务的 secrets 追加并去重，和 compose 一样
    @Test func secretsMergeAcrossFiles() throws {
        let p = try load([
            "compose.yaml": "services:\n  a:\n    image: alpine\n    secrets: [one]\nsecrets:\n  one: {file: ./one}\n",
            "compose.dev.yaml": "services:\n  a:\n    secrets: [one, two]\nsecrets:\n  two: {file: ./two}\n",
        ], order: ["compose.yaml", "compose.dev.yaml"])
        #expect(p.services[0].volumes.map(\.target) == ["/run/secrets/one", "/run/secrets/two"])
    }

    /// internal 接受但不单独断网（所有网络是合成一个的）；值不是真假照样报错
    @Test func internalNetworkAccepted() throws {
        #expect(try issues(["compose.yaml": """
        services:
          a: {image: alpine, networks: [data]}
        networks:
          data: {internal: true}
          other: {internal: false}
        """]).isEmpty)
        let found = try issues(["compose.yaml": """
        services:
          a: {image: alpine}
        networks:
          data: {internal: sometimes}
        """])
        #expect(found.count == 1 && found.mentions("networks.data.internal"))
    }

    /// 合并键 `<<`：自己写的键优先；后面是列表时前面的优先；合并进来的内容是整块替换，不往里合
    @Test func mergeKey() throws {
        let p = try load(["compose.yaml": """
        x-base: &base
          image: alpine
          working_dir: /base
          environment:
            FROM_BASE: "1"
        x-env: &env
          A: base
          B: base
        x-more: &more
          B: more
          C: more
        services:
          a:
            <<: *base
            working_dir: /own
          b:
            <<: *base
            environment:
              <<: [*env, *more]
              A: own
        """])
        #expect(p.services[0].image == "alpine")
        #expect(p.services[0].workingDir == "/own")
        #expect(p.services[0].environment == ["FROM_BASE": "1"])
        #expect(p.services[1].environment == ["A": "own", "B": "base", "C": "more"])
    }

    @Test func mergeKeyNeedsMappings() throws {
        let found = try issues(["compose.yaml": """
        services:
          a:
            image: alpine
            <<: nope
          b:
            image: alpine
            <<: [{working_dir: /x}, 3]
        """])
        #expect(found == [
            .invalid("compose.yaml：services.a.<<：合并键 `<<` 后面要是映射，或者映射的列表"),
            .invalid("compose.yaml：services.b.<<：合并键 `<<` 后面要是映射，或者映射的列表"),
        ])
    }

    /// 带引号的 "<<" 是普通的键，不是合并键
    @Test func quotedMergeKeyIsAnOrdinaryKey() throws {
        let p = try load(["compose.yaml": """
        services:
          a:
            image: alpine
            environment:
              "<<": literal
        """])
        #expect(p.services[0].environment == ["<<": "literal"])
    }

    /// 锚点和别名（不带合并键 `<<`）是普通 YAML 写法
    @Test func anchorsAndAliases() throws {
        let p = try load(["compose.yaml": """
        x-env: &env
          A: "1"
        services:
          a:
            image: alpine
            environment: *env
        """])
        #expect(p.services[0].environment == ["A": "1"])
    }

    @Test func onlyTcp() throws {
        let found = try issues(["compose.yaml": "services:\n  a: {image: alpine, expose: [\"53/udp\"], ports: [\"5353:53/udp\", \"80/tcp\"]}\n"])
        #expect(found == [
            .unsupported("services.a.expose：只支持 tcp，不支持 udp"),
            .unsupported("services.a.ports[0]：只支持 tcp，不支持 udp"),
        ])
    }

    @Test func buildWithPullAlwaysIsUnsupported() throws {
        let found = try issues(["compose.yaml": "services:\n  a: {image: x, build: ., pull_policy: always}\n"])
        #expect(found == [.unsupported("services.a.pull_policy：always 和 build 一起写时 Docker 会先从仓库拉，napbox 写了 build 就只构建。要每次都构建请写 pull_policy: build")])
        #expect(try issues(["compose.yaml": "services:\n  a: {build: ., pull_policy: build}\n  b: {build: ., pull_policy: never}\n"]).isEmpty)
    }

    /// 每个服务有自己的网络（DESIGN.md 第 6 节），两个服务监听同一个端口没问题
    @Test func servicesMayListenOnTheSamePort() throws {
        let found = try issues(["compose.yaml": """
        services:
          web-platform: {image: nginx, ports: ["4173:80"]}
          web-merchant: {image: nginx, ports: ["4174:80"]}
          api: {image: node, expose: ["3000"], ports: ["3000:3000"]}
        """])
        #expect(found.isEmpty)
    }

    /// napbox 自己往环境里放了两个容器，服务和它们同名会撞上：读 compose 时就说清楚。没启用的服务不建容器，不管
    @Test func serviceNamesUsedByNapbox() throws {
        let found = try issues(["compose.yaml": """
        services:
          napbox-guard: {image: alpine}
          napbox-runtime: {image: alpine}
          napbox-other: {image: alpine}
        """])
        #expect(found == [
            .unsupported("服务名 napbox-guard 是 napbox 自己在用的，请给这个服务改个名字"),
            .unsupported("服务名 napbox-runtime 是 napbox 自己在用的，请给这个服务改个名字"),
        ])
        #expect(try issues(["compose.yaml": "services:\n  napbox-runtime: {image: alpine, profiles: [off]}\n  a: {image: alpine}\n"]).isEmpty)
    }

    @Test func dependencyProblems() throws {
        let found = try issues(["compose.yaml": """
        services:
          a: {image: alpine, depends_on: {b: {condition: service_healthy}}}
          b: {image: alpine, depends_on: [c]}
          c: {image: alpine, depends_on: [a]}
          d: {image: alpine, depends_on: [nope]}
        """])
        #expect(found.mentions("要求 service_healthy，但 b 没有 healthcheck"))
        #expect(found.mentions("depends_on 有循环：a → b → c → a"))
        #expect(found.mentions("没有 nope 这个服务"))
    }

    @Test func requiredVariable() throws {
        let files = ["compose.yaml": "services:\n  a:\n    image: ${IMAGE:?Explicit image required}\n"]
        #expect(try issues(files) == [.invalid("compose.yaml：services.a.image：变量 IMAGE 必须设置：Explicit image required")])
        #expect(try load(files, env: ["IMAGE": "x"]).services[0].image == "x")
    }

    @Test func unsetVariablesAreReported() throws {
        let p = try load(["compose.yaml": "services:\n  a:\n    image: alpine:${TAG}\n"])
        #expect(p.services[0].image == "alpine:")
        #expect(p.unsetVariables == ["TAG"])
    }

    @Test func profiles() throws {
        let files = ["compose.yaml": """
        services:
          a: {image: alpine}
          tools: {image: alpine, profiles: [tools]}
        """]
        #expect(try load(files).services.map(\.name) == ["a"])
        #expect(try load(files, profiles: ["tools"]).services.map(\.name) == ["a", "tools"])
        #expect(try load(files, env: ["COMPOSE_PROFILES": "tools"]).services.map(\.name) == ["a", "tools"])
        let dependsOnInactive = try issues(["compose.yaml": """
        services:
          a: {image: alpine, depends_on: [tools]}
          tools: {image: alpine, profiles: [tools]}
        """])
        #expect(dependsOnInactive.mentions("tools 属于没启用的 profile"))
    }

    /// 没启用的 profile 里的服务写的 ports 也要分配，换 profile 再 up 时端口不变（DESIGN.md 第 5 节）
    @Test func inactiveProfilesReservePorts() throws {
        let files = ["compose.yaml": """
        services:
          db: {image: postgres, ports: ["5432"]}
          tools: {image: alpine, ports: ["9000", "9001"], profiles: [tools]}
          quiet: {image: alpine, profiles: [quiet]}
        """]
        let inactive = try load(files)
        #expect(inactive.reservedPorts == ["tools": [9000, 9001]], "没写 ports 的 quiet 不用留")
        #expect(inactive.portRequests == [
            PortRequest(service: "db", containerPort: 5432),
            PortRequest(service: "tools", containerPort: 9000),
            PortRequest(service: "tools", containerPort: 9001),
        ])
        #expect(try load(files, profiles: ["tools"]).reservedPorts == nil)
        #expect(try load(files, profiles: ["tools"]).portRequests == inactive.portRequests)
        #expect(try load(files, run: ComposeRun(service: "db")).reservedPorts == nil, "run 跑完就销毁，不用留")
        // 没有 profile 的项目定义和原来一样：升级 napbox 后再 up 不会因为定义变了重启环境
        #expect(try load(["compose.yaml": "services:\n  a: {image: alpine, ports: [\"80\"]}\n"]).reservedPorts == nil)
    }

    /// napbox run：只留点名的服务和它依赖的，规则和 docker compose run 一样
    @Test func runKeepsTargetAndItsDependencies() throws {
        let files = ["compose.yaml": """
        services:
          test:
            image: alpine
            command: [sh, -c, "echo from-compose"]
            entrypoint: [/bin/busybox]
            ports: ["8080:80"]
            restart: always
            depends_on: [db]
            volumes: [out:/out]
            profiles: [test]
            develop:
              watch:
                - {path: ./src, action: restart}
          db: {image: postgres, restart: unless-stopped, depends_on: [init], ports: ["5432"], volumes: [pgdata:/data]}
          init: {image: alpine}
          web: {image: nginx, ports: ["${WEB_PORT}:80"], depends_on: [nope], volumes: [webdata:/data]}
        volumes: {out: {}, pgdata: {}, webdata: {}}
        """]
        // 不 run 时：test 没启用（profile），web 写错的地方都会报
        #expect(try issues(files).mentions("nope"))

        let p = try load(files, run: ComposeRun(service: "test"))
        #expect(p.services.map(\.name).sorted() == ["db", "init", "test"], "它自己的 profile 不用写；没用到的 web 不起，写错了也不管")
        let test = try #require(p.services.first { $0.name == "test" })
        #expect(test.command == ["sh", "-c", "echo from-compose"])
        #expect(test.ports.isEmpty, "前台的服务不分配宿主机端口")
        #expect(p.services.first { $0.name == "db" }?.ports == [5432], "它依赖的服务照常")
        #expect(p.services.allSatisfy { $0.restart == .no && $0.watch.isEmpty }, "跑完就销毁，中途不重启")
        #expect(p.volumes.sorted() == ["out", "pgdata"])

        let replaced = try load(files, run: ComposeRun(service: "test", command: ["ls", "-l"]))
        let replacedTest = try #require(replaced.services.first { $0.name == "test" })
        #expect(replacedTest.command == ["ls", "-l"])
        #expect(replacedTest.entrypoint == ["/bin/busybox"], "entrypoint 不换")

        let alone = try load(files, run: ComposeRun(service: "test", noDeps: true))
        #expect(alone.services.map(\.name) == ["test"])
        #expect(alone.services[0].dependsOn.isEmpty)
        #expect(alone.volumes == ["out"])

        #expect(try issues(files, run: ComposeRun(service: "nope")).mentions("没有 nope 这个服务"))
        // 点名的服务自己的写法有问题照样报
        #expect(try issues(files, run: ComposeRun(service: "web")).mentions("nope"))
    }

    /// 它依赖的服务不会因为被依赖就启用 profile（compose 也是这样）
    @Test func runDoesNotEnableProfilesOfDependencies() throws {
        let files = ["compose.yaml": """
        services:
          test: {image: alpine, depends_on: [tools]}
          tools: {image: alpine, profiles: [tools]}
        """]
        #expect(try issues(files, run: ComposeRun(service: "test")).mentions("tools 属于没启用的 profile"))
        #expect(try load(files, profiles: ["tools"], run: ComposeRun(service: "test")).services.map(\.name).sorted() == ["test", "tools"])
    }

    @Test func namedVolumeMustBeDeclared() throws {
        let found = try issues(["compose.yaml": "services:\n  a:\n    image: alpine\n    volumes: [data:/data, /anon]\n"])
        #expect(found.mentions("命名卷 data 没有在顶层 volumes 里声明"))
        #expect(found.mentions("匿名卷第一版不支持"))
    }

    /// 攀岩的用法：compose.yaml 加 compose.dev.yaml 合并
    @Test func mergeFiles() throws {
        let p = try load([
            "compose.yaml": """
            services:
              api:
                image: api
                command: ["node", "server.js"]
                environment:
                  A: base
                  B: base
                ports: ["3000:3000"]
                volumes: ["./src:/app/src", "data:/data"]
                healthcheck:
                  test: ["CMD", "curl", "-f", "http://127.0.0.1:3000"]
                  interval: 5s
                depends_on: [db]
              db: {image: postgres}
            volumes:
              data:
            """,
            "compose.dev.yaml": """
            services:
              api:
                command: npm run dev
                environment:
                  - B=dev
                  - C=dev
                ports: ["3000:3000", "9229:9229"]
                volumes: ["./dev-src:/app/src"]
                healthcheck:
                  interval: 1s
                depends_on:
                  cache: {condition: service_started}
              cache: {image: redis}
            """,
        ], order: ["compose.yaml", "compose.dev.yaml"])
        let api = try #require(p.service("api"))
        #expect(api.command == ["npm", "run", "dev"])
        #expect(api.environment == ["A": "base", "B": "dev", "C": "dev"])
        #expect(api.ports == [3000, 9229])
        #expect(api.volumes.map(\.target) == ["/app/src", "/data"])
        if case .bind(let src) = api.volumes[0].source { #expect(src.hasSuffix("/dev-src")) } else { Issue.record("应该是源码挂载") }
        #expect(api.healthcheck?.intervalSeconds == 1)
        #expect(api.healthcheck?.test == .exec(["curl", "-f", "http://127.0.0.1:3000"]))
        #expect(Set(api.dependsOn.map(\.service)) == ["db", "cache"])
        #expect(p.services.map(\.name) == ["api", "cache", "db"])
    }

    @Test func errorCodes() throws {
        let unsupported = ComposeError([.unsupported("x")]).napboxError
        #expect(unsupported.code == "compose_unsupported")
        let mixed = ComposeError([.unsupported("x"), .invalid("y")]).napboxError
        #expect(mixed.code == "compose_invalid")
        #expect(mixed.message.contains("- 不支持：x") && mixed.message.contains("- 写法有误：y"))
    }

    @Test func startOrder() throws {
        let p = try load(["compose.yaml": """
        services:
          app: {image: a, depends_on: [init, cache]}
          init: {image: a, depends_on: {db: {condition: service_healthy}}}
          db: {image: a, healthcheck: {test: "true"}}
          cache: {image: a}
          lone: {image: a}
        """])
        #expect(StartOrder.order(p.services).map(\.name) == ["cache", "db", "init", "app", "lone"])
        // 停的时候倒过来一层一层停：app 在 init 之后、init 在 db 之后
        #expect(StartOrder.levels(p.services).map { $0.map(\.name) } == [["cache", "db", "lone"], ["init"], ["app"]])
    }

    @Test func portVariableNames() {
        #expect(PortVariables.name(service: "api", port: 3100) == "NAPBOX_API_3100")
        #expect(PortVariables.name(service: "web-admin.v2", port: 80) == "NAPBOX_WEB_ADMIN_V2_80")
    }
}

@Suite struct ComposeFilesTests {
    @Test func searchUpwardWithOverride() throws {
        try withProject([
            "docker-compose.yml": "services: {}",
            "docker-compose.override.yml": "services: {}",
            "sub/deeper/file.txt": "",
        ]) { root in
            let found = try ComposeFiles.resolve(explicit: [], cwd: root.appending(path: "sub/deeper"), worktree: root)
            #expect(found.map(\.lastPathComponent) == ["docker-compose.yml", "docker-compose.override.yml"])
        }
    }

    /// 当前目录经过符号链接（比如 /tmp、/var）时，往上找也要能找到 worktree 根目录
    @Test func symlinkedCwd() throws {
        try withProject(["real/compose.yaml": "services: {}", "real/sub/x": ""]) { dir in
            let link = dir.appending(path: "link")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: dir.appending(path: "real"))
            let found = try ComposeFiles.resolve(explicit: [], cwd: link.appending(path: "sub"), worktree: dir.appending(path: "real"))
            #expect(found.map(\.lastPathComponent) == ["compose.yaml"])
        }
    }

    @Test func preferComposeYaml() throws {
        try withProject(["compose.yaml": "", "docker-compose.yml": ""]) { root in
            let found = try ComposeFiles.resolve(explicit: [], cwd: root, worktree: root)
            #expect(found.map(\.lastPathComponent) == ["compose.yaml"])
        }
    }

    @Test func napboxConfig() throws {
        try withProject([
            ".napbox.yaml": "compose: [server/compose.yaml, server/compose.dev.yaml]\n",
            "server/compose.yaml": "", "server/compose.dev.yaml": "",
        ]) { root in
            let found = try ComposeFiles.resolve(explicit: [], cwd: root, worktree: root)
            #expect(found.map { $0.path.replacingOccurrences(of: root.path + "/", with: "") } == ["server/compose.yaml", "server/compose.dev.yaml"])
        }
    }

    @Test func explicitAndMissing() throws {
        try withProject(["server/compose.yaml": ""]) { root in
            let found = try ComposeFiles.resolve(explicit: ["server/compose.yaml"], cwd: root, worktree: root)
            #expect(found.count == 1)
            #expect { try ComposeFiles.resolve(explicit: ["nope.yaml"], cwd: root, worktree: root) } throws: { ($0 as? NapboxError)?.code == "compose_not_found" }
            #expect { try ComposeFiles.resolve(explicit: [], cwd: root, worktree: root) } throws: { ($0 as? NapboxError)?.code == "compose_not_found" }
        }
    }
}
