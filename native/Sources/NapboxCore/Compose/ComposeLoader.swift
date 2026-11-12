// 读 compose：找文件 → 读 .env → 每份文件分别替换变量 → 按顺序合并 → 校验，得到 ComposeProject。
// 变量来源和 compose 一致：调用方的环境变量优先，其次是项目目录（第一份 compose 所在目录）里的 .env。
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

    public init(files: [URL], callerEnvironment: [String: String], profiles: [String] = [], run: ComposeRun? = nil) {
        self.files = files
        self.callerEnvironment = callerEnvironment
        self.profiles = profiles
        self.run = run
    }
}

/// napbox run 要在前台跑的那个服务。规则和 docker compose run 一样：
/// 只起它和它依赖的服务，它的 profile 跟着启用，不给它分配宿主机端口。
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
        guard let first = input.files.first else { throw ComposeError([.invalid("没有指定 compose 文件")]) }
        let projectDirectory = first.deletingLastPathComponent()

        var dotEnv: [String: String] = [:]
        let dotEnvURL = projectDirectory.appending(path: ".env")
        if let text = try? String(contentsOf: dotEnvURL, encoding: .utf8) {
            for (k, v) in try DotEnv.parse(text, file: dotEnvURL.path, lookup: { input.callerEnvironment[$0] }) { dotEnv[k] = v }
        }
        let lookup: @Sendable (String) -> String? = { [dotEnv] in input.callerEnvironment[$0] ?? dotEnv[$0] }

        var issues: [ComposeIssue] = []
        let interpolator = Interpolator(lookup: lookup)
        var merged: YAMLTree?
        for url in input.files {
            let text: String
            do {
                text = try String(contentsOf: url, encoding: .utf8)
            } catch {
                issues.append(.invalid("读不到 \(url.path)"))
                continue
            }
            do {
                let tree = try YAMLTree.parse(text, file: url.lastPathComponent)
                var fileIssues: [ComposeIssue] = []
                let resolved = tree.interpolated(interpolator, path: "", issues: &fileIssues)
                issues += fileIssues.map { $0.prefixed("\(url.lastPathComponent)：") }
                merged = merged.map { ComposeMerge.merge($0, resolved) } ?? resolved
            } catch {
                issues.append(contentsOf: error.issues)
            }
        }
        guard issues.isEmpty, let merged else { throw ComposeError(issues) }

        var profiles = Set(input.profiles)
        for p in (lookup("COMPOSE_PROFILES") ?? "").split(separator: ",") {
            profiles.insert(p.trimmingCharacters(in: .whitespaces))
        }
        var builder = ComposeBuilder(projectDirectory: projectDirectory, lookup: lookup, activeProfiles: profiles, run: input.run)
        let project = builder.build(merged)
        guard builder.issues.isEmpty, var project else { throw ComposeError(builder.issues) }
        project.unsetVariables = interpolator.missing
        return project
    }
}

/// 没指定 compose 文件时去哪找。
public enum ComposeFiles {
    /// 和 compose 一样的文件名和顺序；同一目录里有 override 文件时自动合并在后面。
    static let names = ["compose.yaml", "compose.yml", "docker-compose.yaml", "docker-compose.yml"]
    static let overrideNames = ["compose.override.yaml", "compose.override.yml", "docker-compose.override.yaml", "docker-compose.override.yml"]

    /// - explicit 不为空：用它们（相对 cwd）
    /// - 否则 worktree 根目录的 `.napbox.yaml` 里写的 `compose`（一个路径或列表，相对 worktree 根目录）
    /// - 否则从 cwd 往上找到 worktree 根目录为止
    public static func resolve(explicit: [String], cwd: URL, worktree: URL) throws(NapboxError) -> [URL] {
        let fm = FileManager.default
        if !explicit.isEmpty {
            let urls = explicit.map { $0.hasPrefix("/") ? URL(fileURLWithPath: $0) : cwd.appending(path: $0) }.map(\.standardizedFileURL)
            for u in urls where !fm.fileExists(atPath: u.path) {
                throw NapboxError(.composeNotFound, "找不到 compose 文件：\(u.path)")
            }
            return urls
        }
        let config = worktree.appending(path: ".napbox.yaml")
        if fm.fileExists(atPath: config.path) {
            return try fromConfig(config, worktree: worktree)
        }
        // worktree 是 git 给出的真实路径，当前目录也要解开符号链接（比如 /tmp、/var），否则对不上、找不到头
        var dir = cwd.resolvingSymlinksInPath()
        let root = worktree.resolvingSymlinksInPath()
        var looked: [String] = []
        while true {
            if let name = names.first(where: { fm.fileExists(atPath: dir.appending(path: $0).path) }) {
                var files = [dir.appending(path: name)]
                if let o = overrideNames.first(where: { fm.fileExists(atPath: dir.appending(path: $0).path) }) {
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

    private static func fromConfig(_ config: URL, worktree: URL) throws(NapboxError) -> [URL] {
        let tree: YAMLTree
        do {
            tree = try YAMLTree.parse(String(contentsOf: config, encoding: .utf8), file: ".napbox.yaml")
        } catch let error as ComposeError {
            throw NapboxError(.composeInvalid, error.issues.map(\.description).joined(separator: "\n"))
        } catch {
            throw NapboxError(.composeInvalid, "读不到 \(config.path)：\(error.localizedDescription)")
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
        for u in urls where !FileManager.default.fileExists(atPath: u.path) {
            throw NapboxError(.composeNotFound, ".napbox.yaml 里写的 compose 文件不存在：\(u.path)")
        }
        return urls
    }
}
