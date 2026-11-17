import Foundation
import Testing
@testable import NapboxCore
import NapboxProtocol

/// 临时目录里放一份代码副本（copy）和它旁边的目录（outside，代表宿主机上别的地方，比如 ~/.ssh）。
/// files 的键是相对临时目录的路径；links 是 符号链接 → 指向（相对临时目录的写法会换成绝对路径）
private struct Sandbox {
    let base: URL
    var copy: URL { base.appending(path: "copy") }
    var outside: URL { base.appending(path: "outside") }
    var confinement: Confinement { Confinement(directory: copy.path) }
    var access: HostAccess { .confined(confinement) }

    init(_ files: [String: String], links: [String: String] = [:]) throws {
        base = FileManager.default.temporaryDirectory.appending(path: "napbox-confine-\(UUID().uuidString)").resolvingSymlinksInPath()
        let fm = FileManager.default
        for dir in ["copy", "outside"] { try fm.createDirectory(at: base.appending(path: dir), withIntermediateDirectories: true) }
        try "secret".write(to: base.appending(path: "outside/id_rsa"), atomically: true, encoding: .utf8)
        for (name, text) in files {
            let url = base.appending(path: name)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
        for (link, target) in links {
            let url = base.appending(path: link)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.createSymbolicLink(atPath: url.path, withDestinationPath: target.hasPrefix("/") || target.hasPrefix(".") ? target : base.appending(path: target).path)
        }
    }

    func remove() { try? FileManager.default.removeItem(at: base) }

    /// 像 create 一样找 compose、读 compose（带 confine）
    func load(env: [String: String] = [:], files: [String] = []) throws -> ComposeProject {
        let urls = try ComposeFiles.resolve(explicit: files, environment: env, cwd: copy, worktree: copy, access: access)
        return try ComposeLoader.load(ComposeInput(files: urls, callerEnvironment: env, access: access))
    }

    /// 读 compose 失败时的错误码和说明
    func failure(env: [String: String] = [:], files: [String] = []) -> NapboxError? {
        do {
            _ = try load(env: env, files: files)
            return nil
        } catch let error as ComposeError {
            return error.napboxError
        } catch let error as NapboxError {
            return error
        } catch {
            return NapboxError(.internalError, "\(error)")
        }
    }
}

private func compose(_ service: String) -> [String: String] {
    ["copy/compose.yaml": "services:\n  app:\n    image: busybox\n" + service]
}

@Suite struct ConfinementTests {
    /// 每种越界写法都要报 path_outside_directory，说明里有字段和写法
    private func rejects(_ files: [String: String], links: [String: String] = [:], env: [String: String] = [:], explicit: [String] = [],
                         mentioning texts: [String], sourceLocation: SourceLocation = #_sourceLocation) throws {
        let box = try Sandbox(files, links: links)
        defer { box.remove() }
        let error = box.failure(env: env, files: explicit)
        #expect(error?.code == ErrorCode.pathOutsideDirectory.rawValue, "\(error?.message ?? "没有报错")", sourceLocation: sourceLocation)
        if error?.code != ErrorCode.pathOutsideDirectory.rawValue || texts.contains(where: { error?.message.contains($0) != true }) {
            print("说明：\((error?.message ?? "").replacingOccurrences(of: "\n", with: " / "))")
        }
        for text in texts {
            #expect(error?.message.contains(text) == true, "说明里没有 \(text)：\(error?.message ?? "")", sourceLocation: sourceLocation)
        }
        // 不带出解开后的真实路径（不能拿来探宿主机上有什么文件）。写法里的绝对路径是 /var/…（Foundation 去掉了 /private），
        // 解出来的是 /private/var/…：说明里出现后者就是带出了解析结果
        #expect(error?.message.contains(Confinement.realPath(box.outside.path)!) != true, sourceLocation: sourceLocation)
    }

    @Test func volumesOutside() throws {
        try rejects(compose("    volumes: ['../outside:/x']\n"), mentioning: ["services.app.volumes[0]", "../outside"])
        try rejects(compose("    volumes: ['/etc:/x']\n"), mentioning: ["services.app.volumes[0]", "/etc"])
        try rejects(compose("    volumes: ['~/.ssh:/root/.ssh:ro']\n"), mentioning: ["~/.ssh"])
        try rejects(compose("    volumes: [{type: bind, source: ../outside/id_rsa, target: /x}]\n"), mentioning: ["volumes[0]"])
        // 变量替换出来的也一样
        try rejects(compose("    volumes: ['${HOME_SSH}:/x']\n"), env: ["HOME_SSH": "/Users/nobody/.ssh"], mentioning: ["/Users/nobody/.ssh"])
    }

    @Test func symlinksOut() throws {
        try rejects(compose("    volumes: ['./link:/root/.ssh']\n"), links: ["copy/link": "outside"], mentioning: ["./link"])
        // 中间一段是符号链接
        try rejects(compose("    volumes: ['./sub/link/deeper:/x']\n"), links: ["copy/sub/link": "outside"], mentioning: ["./sub/link/deeper"])
        // 相对写法的符号链接指出去
        try rejects(compose("    volumes: ['./rel:/x']\n"), links: ["copy/rel": "../outside"], mentioning: ["./rel"])
        // 指向不存在的位置：判断不了，也拒绝（建目录会建到外面去）
        try rejects(compose("    volumes: ['./dangling:/x']\n"), links: ["copy/dangling": "outside/missing"], mentioning: ["./dangling"])
        // 单个文件
        try rejects(compose("    volumes: ['./key:/root/key']\n"), links: ["copy/key": "outside/id_rsa"], mentioning: ["./key"])
    }

    @Test func filesNapboxReads() throws {
        try rejects(compose("    env_file: ../outside/id_rsa\n"), mentioning: ["services.app.env_file", "../outside/id_rsa"])
        try rejects(compose("    env_file: [{path: ./app.env, required: false}]\n"), links: ["copy/app.env": "outside/id_rsa"],
                    mentioning: ["./app.env"])
        // 不要求存在的也拒绝：在外面就是在外面，不看它在不在
        try rejects(compose("    env_file: [{path: ../outside/nothing.env, required: false}]\n"), mentioning: ["../outside/nothing.env"])
        // 变量替换读的 .env
        try rejects(compose(""), links: ["copy/.env": "outside/id_rsa"], mentioning: [".env"])
        // compose 文件本身
        try rejects([:], links: ["copy/compose.yaml": "outside/id_rsa"], mentioning: ["compose 文件"])
        try rejects(["outside/compose.yaml": "services: {}\n"], explicit: ["../outside/compose.yaml"], mentioning: ["compose 文件"])
        // .napbox.yaml 指的 compose、.napbox.yaml 自己
        try rejects(["copy/.napbox.yaml": "compose: ../outside/compose.yaml\n", "outside/compose.yaml": "services: {}\n"],
                    mentioning: ["compose 文件"])
        try rejects(["outside/napbox.yaml": "compose: compose.yaml\n"], links: ["copy/.napbox.yaml": "outside/napbox.yaml"],
                    mentioning: [".napbox.yaml"])
        // COMPOSE_FILE：调用方给的和 .env 里的
        try rejects(["outside/compose.yaml": "services: {}\n"], env: ["COMPOSE_FILE": "../outside/compose.yaml"], mentioning: ["compose 文件"])
        try rejects(["copy/.env": "COMPOSE_FILE=../outside/compose.yaml\n", "outside/compose.yaml": "services: {}\n"],
                    mentioning: ["compose 文件"])
    }

    @Test func secretsBuildWatch() throws {
        try rejects([
            "copy/compose.yaml": "secrets:\n  key: {file: ../outside/id_rsa}\nservices:\n  app:\n    image: busybox\n    secrets: [key]\n",
        ], mentioning: ["secrets.key.file"])
        try rejects(compose("    build: ../outside\n"), mentioning: ["services.app.build.context"])
        try rejects(compose("    build: {context: ., dockerfile: ../outside/id_rsa}\n"), mentioning: ["services.app.build.dockerfile"])
        // 没写 dockerfile 时是 context 里的 Dockerfile，它是指出去的符号链接
        try rejects(compose("    build: .\n"), links: ["copy/Dockerfile": "outside/id_rsa"], mentioning: ["build.dockerfile"])
        try rejects(compose("    build: .\n    develop:\n      watch: [{action: sync, path: ../outside, target: /x}]\n"),
                    mentioning: ["services.app.develop.watch[0].path"])
    }

    /// 找 compose 文件那一步也不能拿来探宿主机：越界的路径不管存不存在，都报 path_outside_directory，不报 compose_not_found
    @Test func noExistenceProbe() throws {
        for missing in ["../outside/nothing.yaml", "/Users/nobody/.ssh/id_ed25519"] {
            try rejects([:], env: ["COMPOSE_FILE": missing], mentioning: ["compose 文件"])
            try rejects(["copy/.env": "COMPOSE_FILE=\(missing)\n"], mentioning: ["compose 文件"])
            try rejects([:], explicit: [missing], mentioning: ["compose 文件"])
        }
        // .napbox.yaml 里的路径都相对代码目录（写成 / 开头也是），只有 ../ 能指出去
        try rejects(["copy/.napbox.yaml": "compose: ../outside/nothing.yaml\n"], mentioning: ["compose 文件"])
        // 自动找到的 compose.yaml 是指出去的符号链接：指向的存在和不存在一样报
        try rejects([:], links: ["copy/compose.yaml": "outside/id_rsa"], mentioning: ["compose 文件"])
        try rejects([:], links: ["copy/compose.yaml": "outside/nothing.yaml"], mentioning: ["compose 文件"])
    }

    /// 第一版本来就不支持的写法：开着 confine 一样报错，也不去读它们指的文件。
    /// a.yaml 是指出去的符号链接：要是读了它会报越界，报的是不支持就说明没读
    @Test func unsupportedFormsStayRejected() throws {
        let cases: [String: String] = [
            "include": "include: [a.yaml]\nservices:\n  app: {image: busybox}\n",
            "extends": "services:\n  app: {image: busybox, extends: {file: a.yaml, service: app}}\n",
            "configs": "configs:\n  c: {file: a.yaml}\nservices:\n  app: {image: busybox}\n",
            "label_file": "services:\n  app: {image: busybox, label_file: a.yaml}\n",
            "additional_contexts": "services:\n  app: {build: {context: ., additional_contexts: {x: ../outside}}}\n",
            "build.secrets": "services:\n  app: {build: {context: ., secrets: [k]}}\n",
            "driver_opts": "volumes:\n  v: {driver_opts: {type: none, o: bind, device: /Users}}\nservices:\n  app: {image: busybox, volumes: ['v:/x']}\n",
            "volume.subpath": "volumes:\n  v: {}\nservices:\n  app: {image: busybox, volumes: [{type: volume, source: v, target: /x, volume: {subpath: a}}]}\n",
        ]
        for (form, text) in cases {
            let box = try Sandbox(["copy/compose.yaml": text, "copy/Dockerfile": "FROM busybox\n"], links: ["copy/a.yaml": "outside/id_rsa"])
            defer { box.remove() }
            let error = box.failure()
            #expect(error?.code == ErrorCode.composeUnsupported.rawValue, "\(form)：\(error?.message ?? "没有报错")")
            let field = form.split(separator: ".").first.map(String.init) ?? form
            #expect(error?.message.contains(field) == true, "\(form)：\(error?.message ?? "")")
        }
    }

    /// 目录以内的写法都能读，存进定义的是真实路径；Dockerfile 和不受限时一样存相对 context 的写法
    @Test func insideLoads() throws {
        let box = try Sandbox([
            "copy/compose.yaml": """
            secrets:
              key: {file: ./secret.txt}
            services:
              app:
                build: {context: ./api}
                env_file: [app.env, {path: missing.env, required: false}]
                secrets: [key]
                volumes: ['./src:/src', './data/pg:/var/lib/pg', './conf/app.conf:/etc/app.conf:ro', './alias:/alias']
                develop:
                  watch: [{action: sync, path: ./api, target: /app}]
              web:
                build: {context: ./web, dockerfile: ../docker/web.Dockerfile}
            """,
            "copy/.env": "X=1\n", "copy/app.env": "FROM_FILE=${X}\n", "copy/secret.txt": "s", "copy/api/Dockerfile": "FROM busybox\n",
            "copy/src/a.txt": "a", "copy/conf/app.conf": "c", "copy/web/index.html": "", "copy/docker/web.Dockerfile": "FROM busybox\n",
        ], links: ["copy/alias": "./src"])
        defer { box.remove() }
        let p = try box.load()
        let root = box.confinement.root
        #expect(root.hasPrefix("/private/"), "临时目录的真实路径在 /private 下，测的才是真实路径：\(root)")
        let app = try #require(p.service("app"))
        #expect(app.environment["FROM_FILE"] == "1")
        let paths = app.volumes.compactMap(\.source.hostPath)
        #expect(paths == ["\(root)/src", "\(root)/data/pg", "\(root)/conf/app.conf", "\(root)/src", "\(root)/secret.txt"])
        #expect(app.build?.context == "\(root)/api")
        #expect(app.build?.dockerfilePath == "\(root)/api/Dockerfile")
        #expect(app.watch.first?.path == "\(root)/api")
        let web = try #require(p.service("web")?.build)
        #expect(web.context == "\(root)/web")
        #expect(web.dockerfile == "../docker/web.Dockerfile")
        #expect(web.dockerfilePath == "\(root)/docker/web.Dockerfile")
        // 存下来的定义原样再查一遍也通过
        for s in p.services { try box.access.check(s) }
    }

    /// 读完以后把目录里的一段换成指出去的符号链接：之后每次构建、起环境前的检查要拦下来，说明哪个服务、哪个字段、哪个路径
    @Test func storedDefinitionRechecked() throws {
        let box = try Sandbox([
            "copy/compose.yaml": "services:\n  app:\n    build: ./api\n    volumes: ['./src:/src']\n",
            "copy/src/a.txt": "a", "copy/api/Dockerfile": "FROM busybox\n",
        ])
        defer { box.remove() }
        let app = try #require(try box.load().service("app"))
        let root = box.confinement.root
        try FileManager.default.removeItem(atPath: "\(root)/src")
        try FileManager.default.createSymbolicLink(atPath: "\(root)/src", withDestinationPath: box.outside.path)
        try FileManager.default.removeItem(atPath: "\(root)/api/Dockerfile")
        try FileManager.default.createSymbolicLink(atPath: "\(root)/api/Dockerfile", withDestinationPath: box.outside.appending(path: "id_rsa").path)
        #expect {
            try box.access.check(app)
        } throws: { error in
            let e = error as? NapboxError
            return e?.code == ErrorCode.pathOutsideDirectory.rawValue
                && e?.message.contains("services.app.volumes（挂到 /src）：\(root)/src") == true
                && e?.message.contains("services.app.build.dockerfile") == true
        }
    }

    /// 代码目录本身被换成符号链接（rmdir 再 ln -s）：按登记的真实路径查，不跟着链接把别的目录当成代码目录
    @Test func swappedRootRejected() throws {
        let box = try Sandbox([
            "copy/compose.yaml": "services:\n  app:\n    image: busybox\n    volumes: ['./src:/src']\n",
            "copy/src/a.txt": "a",
            "outside/src/a.txt": "outside",
        ])
        defer { box.remove() }
        let access = box.access
        let app = try #require(try box.load().service("app"))
        try access.check(app)
        let root = box.confinement.root
        try FileManager.default.moveItem(atPath: root, toPath: root + ".moved")
        try FileManager.default.createSymbolicLink(atPath: root, withDestinationPath: box.outside.path)
        // 新解析的话 outside 里也有 src，会被当成在目录里
        #expect(Confinement(directory: box.copy.path).root != root)
        #expect {
            try access.check(app)
        } throws: { error in
            (error as? NapboxError)?.message.contains("代码目录 \(root) 本身被换掉了") == true
        }
        #expect(access.place("\(root)/src") == nil)
        #expect(throws: HostReadFailure.outside) { try access.read("\(root)/src/a.txt") }
        #expect(throws: NapboxError.self) { try access.createDirectory("\(root)/new") }
        #expect(!FileManager.default.fileExists(atPath: box.outside.appending(path: "new").path))
        // 读 compose 也一样（create 再来一次时用的是登记里的 root）
        #expect(throws: ComposeError.self) {
            try ComposeLoader.load(ComposeInput(files: [URL(fileURLWithPath: "\(root)/compose.yaml")], callerEnvironment: [:], access: access))
        }
    }

    /// napboxd 自己读文件：查完之后路径里一段被换成符号链接，按查的时候的路径打开也读不到外面
    @Test func readDoesNotFollowSwappedComponent() throws {
        let box = try Sandbox(["copy/conf/id_rsa": "inside"])
        defer { box.remove() }
        let access = box.access, root = box.confinement.root
        let path = "\(root)/conf/id_rsa"
        #expect(try access.read(path) == Data("inside".utf8))
        #expect(try access.read("\(root)/conf/missing") == nil)
        try FileManager.default.removeItem(atPath: "\(root)/conf")
        try FileManager.default.createSymbolicLink(atPath: "\(root)/conf", withDestinationPath: box.outside.path)
        #expect(throws: HostReadFailure.outside) { try access.read(path) }
        #expect(throws: HostReadFailure.outside) { try access.read(box.outside.appending(path: "id_rsa").path) }
    }

    /// 绑定的来源不存在时建目录：正常的一层层建出来；中间一段被换成符号链接就停下，不在外面建
    @Test func createDirectoryStaysInside() throws {
        let box = try Sandbox([:], links: ["copy/link": "outside"])
        defer { box.remove() }
        let access = box.access, root = box.confinement.root
        try access.createDirectory("\(root)/data/pg/16")
        #expect(FileManager.default.fileExists(atPath: "\(root)/data/pg/16"))
        #expect(throws: NapboxError.self) { try access.createDirectory("\(root)/link/made") }
        #expect(!FileManager.default.fileExists(atPath: box.outside.appending(path: "made").path))
        #expect(throws: NapboxError.self) { try access.createDirectory(box.outside.appending(path: "x").path) }
    }

    /// 不带 confine 时照旧：宿主机上哪里都能挂，build 的定义和以前一样（dockerfile 原样，已有环境的定义不变、不会因此重启）
    @Test func unconfinedUnchanged() throws {
        let box = try Sandbox(compose("    build: {context: ., dockerfile: ./sub/../Dockerfile}\n    volumes: ['../outside:/x', '~/.ssh:/y']\n"))
        defer { box.remove() }
        let p = try ComposeLoader.load(ComposeInput(files: [box.copy.appending(path: "compose.yaml")], callerEnvironment: [:]))
        #expect(p.service("app")?.volumes.count == 2)
        #expect(p.service("app")?.build?.dockerfile == "./sub/../Dockerfile")
        #expect(p.service("app")?.build?.context == box.copy.standardizedFileURL.path)
    }
}
