// 读 compose：找文件 → 读 compose 文件和 .env → 每份文件分别替换变量 → 按顺序合并 → 校验，得到 ComposeProject。
// 变量来源和 compose 一致：调用方的环境变量优先，其次是项目目录（第一份 compose 所在目录）里的 .env；
// COMPOSE_PROJECT_NAME 总有值（projectName）。
import Foundation
import NapboxProtocol

public struct ComposeInput: Sendable {
    /// 绝对路径，按合并顺序
    public var files: [URL]
    /// 调用方（命令行所在 shell、CodeOS）的环境变量
    public var callerEnvironment: [String: String]
    /// 额外启用的 profile；COMPOSE_PROFILES 也会算进去
    public var profiles: [String]
    /// napbox run：只要其中一个服务和它依赖的
    public var run: ComposeRun?
    /// 怎么碰宿主机上的文件：create 带 confine 时读的文件、存进定义的宿主机路径都要在代码目录以内，存的是真实路径
    public var access: HostAccess

    public init(files: [URL], callerEnvironment: [String: String], profiles: [String] = [], run: ComposeRun? = nil,
                access: HostAccess = .open) {
        self.files = files
        self.callerEnvironment = callerEnvironment
        self.profiles = profiles
        self.run = run
        self.access = access
    }
}

/// napbox run 要在前台跑的那个服务。规则和 docker compose run 一样：
/// 只起它和它依赖的服务，它的 profile 跟着启用。和 compose run 不同的一点：它写的端口照常分配宿主机端口。
public struct ComposeRun: Sendable {
    public var service: String
    /// 不为空时替换这个服务的 command（entrypoint 不变）
    public var command: [String]
    /// 不起它依赖的服务
    public var noDeps: Bool

    public init(service: String, command: [String] = [], noDeps: Bool = false) {
        self.service = service
        self.command = command
        self.noDeps = noDeps
    }
}

public enum ComposeLoader {
    public static func load(_ input: ComposeInput) throws(ComposeError) -> ComposeProject {
        try loadNamed(input).project
    }

    /// 连同 compose 的项目名一起给（规则见 projectName）。napbox save 给没写 image 的服务起镜像名时用它，
    /// 和 docker compose build 起的名字一样；环境的名字不用它，由 napbox 按仓库目录自己起。
    public static func loadNamed(_ input: ComposeInput) throws(ComposeError) -> (project: ComposeProject, name: String) {
        guard let first = input.files.first else { throw ComposeError([.invalid("没有指定 compose 文件")]) }
        let projectDirectory = first.deletingLastPathComponent()
        let access = input.access

        // 先读 compose 文件（解析用不到 .env）：有读不到、越界的就不往下读它旁边的 .env 了
        var texts: [(url: URL, text: String)] = []
        var unreadable: [ComposeIssue] = []
        for url in input.files {
            do {
                if let text = try access.readText(url.path, written: url.path, "compose 文件") { texts.append((url, text)) }
                else { unreadable.append(.invalid("读不到 \(url.path)")) }
            } catch {
                unreadable.append(error)
            }
        }
        guard unreadable.isEmpty else { throw ComposeError(unreadable) }

        var dotEnv: [String: String] = [:]
        let dotEnvURL = projectDirectory.appending(path: ".env")
        let dotEnvText: String?
        do {
            dotEnvText = try access.readText(dotEnvURL.path, written: dotEnvURL.path, ".env")
        } catch {
            throw ComposeError([error])
        }
        if let text = dotEnvText {
            for (k, v) in try DotEnv.parse(text, file: dotEnvURL.path, lookup: { input.callerEnvironment[$0] }) { dotEnv[k] = v }
        }
        let given: @Sendable (String) -> String? = { [dotEnv] name in input.callerEnvironment[name] ?? dotEnv[name] }

        var issues: [ComposeIssue] = []
        var trees: [(file: String, tree: YAMLTree)] = []
        for (url, text) in texts {
            do {
                trees.append((url.lastPathComponent, try YAMLTree.parse(text, file: url.lastPathComponent)))
            } catch {
                issues.append(contentsOf: error.issues)
            }
        }
        let composeProjectName = projectName(trees.map(\.tree), directory: projectDirectory, given: given)
        let lookup: @Sendable (String) -> String? = { name in
            if PortReferences.isReference(name) { return PortReferences.placeholder(name) }
            return name == "COMPOSE_PROJECT_NAME" ? composeProjectName : given(name)
        }
        let interpolator = Interpolator(lookup: lookup)
        var merged: YAMLTree?
        for (file, tree) in trees {
            var fileIssues: [ComposeIssue] = []
            let resolved = tree.interpolated(interpolator, path: "", issues: &fileIssues)
            issues += fileIssues.map { $0.prefixed("\(file)：") }
            merged = merged.map { ComposeMerge.merge($0, resolved) } ?? resolved
        }
        guard issues.isEmpty, let merged else { throw ComposeError(issues) }

        var profiles = Set(input.profiles)
        for p in (lookup("COMPOSE_PROFILES") ?? "").split(separator: ",") {
            profiles.insert(p.trimmingCharacters(in: .whitespaces))
        }
        var builder = ComposeBuilder(projectDirectory: projectDirectory, lookup: lookup, activeProfiles: profiles, run: input.run,
                                     access: access)
        let project = builder.build(merged)
        guard builder.issues.isEmpty, var project else { throw ComposeError(builder.issues) }
        project.unsetVariables = interpolator.missing
        return (project, composeProjectName)
    }

    /// `${COMPOSE_PROJECT_NAME}` 的值，规则和 compose 一样：调用方环境或 .env 里给的；没给就是 compose 最外层的 name
    /// （后面的文件优先）；再没有就是项目目录名，只留小写字母、数字、`-`、`_`，开头的 `-`、`_` 去掉。
    private static func projectName(_ trees: [YAMLTree], directory: URL, given: @escaping @Sendable (String) -> String?) -> String {
        if let name = given("COMPOSE_PROJECT_NAME"), !name.isEmpty { return name }
        for tree in trees.reversed() {
            if let written = tree["name"]?.string, let name = try? Interpolator(lookup: given).interpolate(written), !name.isEmpty {
                return name
            }
        }
        let kept = directory.lastPathComponent.lowercased().unicodeScalars.filter { c in
            ("a"..."z").contains(c) || ("0"..."9").contains(c) || c == "-" || c == "_"
        }
        return String(String.UnicodeScalarView(kept.drop { $0 == "-" || $0 == "_" }))
    }
}

/// 没指定 compose 文件时去哪找。
public enum ComposeFiles {
    /// 和 compose 一样的文件名和顺序；同一目录里有 override 文件时自动合并在后面。
    static let names = ["compose.yaml", "compose.yml", "docker-compose.yaml", "docker-compose.yml"]
    static let overrideNames = ["compose.override.yaml", "compose.override.yml", "docker-compose.override.yaml", "docker-compose.override.yml"]

    /// - explicit 不为空：用它们（相对 cwd）
    /// - 否则 worktree 根目录的 `.napbox.yaml` 里写的 `compose`（一个路径或列表，相对 worktree 根目录）
    /// - 否则 `COMPOSE_FILE`（environment 里的，或 cwd 的 .env 里的；几个路径用 `:` 隔开，相对 cwd），和 compose 一样
    /// - 否则从 cwd 往上找到 worktree 根目录为止
    /// - environment：调用方的环境变量
    /// - access：create 带 confine 时这里读的 .napbox.yaml 和 cwd 的 .env 都要在代码目录以内；
    ///   找到的 compose 文件读的时候再查（ComposeLoader）
    public static func resolve(explicit: [String], environment: [String: String], cwd: URL, worktree: URL,
                               access: HostAccess = .open) throws(NapboxError) -> [URL] {
        let present = { (url: URL) in access.present(url.path) }
        func listed(_ paths: [String], notFound: String) throws(NapboxError) -> [URL] {
            let urls = paths.map { $0.hasPrefix("/") ? URL(fileURLWithPath: $0) : cwd.appending(path: $0) }.map(\.standardizedFileURL)
            for u in urls where !present(u) {
                throw NapboxError(.composeNotFound, "\(notFound)：\(u.path)")
            }
            return urls
        }
        if !explicit.isEmpty { return try listed(explicit, notFound: "找不到 compose 文件") }
        let config = worktree.appending(path: ".napbox.yaml")
        if let text = try readText(config, access: access) {
            return try fromConfig(text, worktree: worktree, present: present)
        }
        let fromVariable = try composeFileVariable(environment, cwd: cwd, access: access)
        if !fromVariable.isEmpty { return try listed(fromVariable, notFound: "COMPOSE_FILE 里写的 compose 文件不存在") }
        // worktree 是 git 给出的真实路径，当前目录也要解开符号链接（比如 /tmp、/var），否则对不上、找不到头
        var dir = cwd.resolvingSymlinksInPath()
        let root = worktree.resolvingSymlinksInPath()
        var looked: [String] = []
        while true {
            if let name = names.first(where: { present(dir.appending(path: $0)) }) {
                var files = [dir.appending(path: name)]
                if let o = overrideNames.first(where: { present(dir.appending(path: $0)) }) {
                    files.append(dir.appending(path: o))
                }
                return files
            }
            looked.append(dir.path)
            if dir.path == root.path || dir.pathComponents.count <= 1 || !dir.path.hasPrefix(root.path) { break }
            dir = dir.deletingLastPathComponent()
        }
        throw NapboxError(
            .composeNotFound,
            "在 \(looked.joined(separator: "、")) 里没找到 \(names.joined(separator: "、"))。用 -f 指定 compose 文件，或者在 worktree 根目录放一个 .napbox.yaml，写上 compose: <路径>。"
        )
    }

    /// `COMPOSE_FILE` 里列的路径，没设是空的。分隔符是 `:`，`COMPOSE_PATH_SEPARATOR` 可以换。
    /// 两个变量都是调用方环境里的优先，其次是 cwd 的 .env 里的。
    private static func composeFileVariable(_ environment: [String: String], cwd: URL,
                                            access: HostAccess) throws(NapboxError) -> [String] {
        var dotEnv: [String: String] = [:]
        let dotEnvURL = cwd.appending(path: ".env")
        if let text = try readText(dotEnvURL, access: access) {
            do {
                for (k, v) in try DotEnv.parse(text, file: dotEnvURL.path, lookup: { environment[$0] }) { dotEnv[k] = v }
            } catch {
                throw error.napboxError
            }
        }
        func value(_ name: String) -> String? { (environment[name] ?? dotEnv[name]).flatMap { $0.isEmpty ? nil : $0 } }
        guard let files = value("COMPOSE_FILE") else { return [] }
        return files.components(separatedBy: value("COMPOSE_PATH_SEPARATOR") ?? ":").filter { !$0.isEmpty }
    }

    /// 读 .napbox.yaml、cwd 的 .env：不存在是 nil
    private static func readText(_ url: URL, access: HostAccess) throws(NapboxError) -> String? {
        do {
            return try access.readText(url.path, written: url.path, url.lastPathComponent)
        } catch {
            throw ComposeError([error]).napboxError
        }
    }

    private static func fromConfig(_ text: String, worktree: URL, present: (URL) -> Bool) throws(NapboxError) -> [URL] {
        let tree: YAMLTree
        do {
            tree = try YAMLTree.parse(text, file: ".napbox.yaml")
        } catch {
            throw NapboxError(.composeInvalid, error.issues.map(\.description).joined(separator: "\n"))
        }
        guard let entries = tree.entries else { throw NapboxError(.composeInvalid, ".napbox.yaml 要是映射，例如 compose: server/compose.yaml") }
        var paths: [String] = []
        for (k, v) in entries {
            guard k == "compose" else { throw NapboxError(.composeInvalid, ".napbox.yaml：不认识的设置 \(k)（只有 compose）") }
            switch v {
            case .scalar(let s, _): paths = [s]
            case .sequence(let items): paths = items.compactMap(\.string)
            default: break
            }
        }
        guard !paths.isEmpty else { throw NapboxError(.composeInvalid, ".napbox.yaml：compose 要写一个路径或路径列表") }
        let urls = paths.map { worktree.appending(path: $0).standardizedFileURL }
        for u in urls where !present(u) {
            throw NapboxError(.composeNotFound, ".napbox.yaml 里写的 compose 文件不存在：\(u.path)")
        }
        return urls
    }
}
