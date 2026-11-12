// develop.watch 的规则判断：一个文件变了，按哪几条规则做什么。行为对着 docker compose 的 watch：
// 每条匹配的规则都生效；排除规则是 rule.ignore、构建上下文的忽略文件，加上固定不看的 .git 和编辑器临时文件。
import Foundation

/// .dockerignore 写法的规则：后面的优先，`!` 放回来；规则匹配到目录时目录下的都算；`**` 跨目录，`*`、`?` 不跨。
public struct IgnorePatterns: Sendable {
    private struct Pattern: @unchecked Sendable { // NSRegularExpression 是线程安全的
        var negated: Bool
        var regex: NSRegularExpression
    }

    private let patterns: [Pattern]

    public init(_ lines: [String]) {
        patterns = lines.compactMap { line in
            var text = line.trimmingCharacters(in: .whitespaces)
            if text.isEmpty || text.hasPrefix("#") { return nil }
            let negated = text.hasPrefix("!")
            if negated { text.removeFirst() }
            // 去掉头尾的 / 和 ./（compose 也先规整路径）
            text = text.split(separator: "/").filter { $0 != "." }.joined(separator: "/")
            if text.isEmpty { return nil }
            guard let regex = try? NSRegularExpression(pattern: Self.regex(text)) else { return nil }
            return Pattern(negated: negated, regex: regex)
        }
    }

    public var isEmpty: Bool { patterns.isEmpty }
    /// 有 `!` 时不能看到目录被排除就不往下看：下面可能有放回来的
    public var hasNegation: Bool { patterns.contains(where: \.negated) }

    public func matches(_ relative: String) -> Bool {
        var candidates: [String] = []
        var current = ""
        for part in relative.split(separator: "/") {
            current += current.isEmpty ? String(part) : "/" + part
            candidates.append(current)
        }
        var matched = false
        for pattern in patterns where pattern.negated == matched {
            if candidates.contains(where: { candidate in
                pattern.regex.firstMatch(in: candidate, range: NSRange(candidate.startIndex..., in: candidate)) != nil
            }) {
                matched = !pattern.negated
            }
        }
        return matched
    }

    private static func regex(_ pattern: String) -> String {
        var result = "^"
        let chars = Array(pattern)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            switch c {
            case "*":
                if i + 1 < chars.count, chars[i + 1] == "*" {
                    i += 1
                    if i + 1 < chars.count, chars[i + 1] == "/" {
                        i += 1
                        result += "(.*/)?"
                    } else {
                        result += ".*"
                    }
                } else {
                    result += "[^/]*"
                }
            case "?": result += "[^/]"
            case "[":
                if let end = chars[i...].firstIndex(of: "]") {
                    result += String(chars[i...end])
                    i = end
                } else {
                    result += "\\["
                }
            case "\\":
                if i + 1 < chars.count {
                    i += 1
                    result += NSRegularExpression.escapedPattern(for: String(chars[i]))
                }
            default: result += NSRegularExpression.escapedPattern(for: String(c))
            }
            i += 1
        }
        return result + "$"
    }
}

/// 要对一个服务做的事
public struct WatchPlan: Equatable, Sendable {
    public struct Sync: Equatable, Sendable {
        public var hostPath: String
        public var containerPath: String
    }

    public var syncs: [Sync] = []
    public var rebuild = false
    public var restart = false
    /// sync+exec 的命令，一条规则一次
    public var execs: [[String]] = []

    public var isEmpty: Bool { syncs.isEmpty && !rebuild && !restart && execs.isEmpty }
}

public struct WatchMatcher: Sendable {
    private struct Entry: Sendable {
        var service: String
        var rule: WatchRule
        /// 规则的路径（解开符号链接的）
        var path: String
        var ignore: IgnorePatterns
        var context: String?
        var contextIgnore: IgnorePatterns?
    }

    /// 固定不看的：版本库、napbox 自己写的、编辑器的临时文件（和 compose 的一样，加上 macOS 的 .DS_Store）
    private static let always = IgnorePatterns([
        "**/.git", "**/.napbox", "**/\(SourceChangePlanner.signalPrefix)*", "**/.DS_Store",
        "**/4913", "**/*~", "**/.*.swp", "**/.*.swx", "**/.*.swo", "**/.*.swn",
        "**/.#*", "**/#*#", "**/*___jb_old___", "**/*___jb_tmp___", "**/.idea", "**/.*.kate-swp", "**/.goutputstream-*",
    ])

    private let entries: [Entry]

    /// - canonical：宿主机路径的真实写法（FSEvents 报的是解开符号链接后的路径）
    /// - readFile：读构建上下文的忽略文件
    public init(project: ComposeProject, canonical: (String) -> String, readFile: (String) -> String?) {
        entries = project.services.flatMap { service -> [Entry] in
            var context: String?
            var contextIgnore: IgnorePatterns?
            if let build = service.build {
                context = canonical(build.context)
                let dockerfile = (build.context as NSString).appendingPathComponent(build.dockerfile ?? "Dockerfile")
                if let text = readFile(dockerfile + ".dockerignore") ?? readFile((build.context as NSString).appendingPathComponent(".dockerignore")) {
                    contextIgnore = IgnorePatterns(text.components(separatedBy: .newlines))
                }
            }
            return service.watch.map { rule in
                Entry(service: service.name, rule: rule, path: canonical(rule.path), ignore: IgnorePatterns(rule.ignore),
                      context: context, contextIgnore: contextIgnore)
            }
        }
    }

    public var isEmpty: Bool { entries.isEmpty }
    public var services: [String] { Array(Set(entries.map(\.service))).sorted() }
    /// 规则里的路径
    public func paths(service: String) -> [String] {
        Array(Set(entries.filter { $0.service == service }.map(\.path))).sorted()
    }

    /// 要听变化的目录。规则指向单个文件时听它所在的目录：保存常常是改名覆盖，文件换了一个
    public func eventRoots(isDirectory: (String) -> Bool) -> [String] {
        Array(Set(entries.map { isDirectory($0.path) ? $0.path : ($0.path as NSString).deletingLastPathComponent })).sorted()
    }

    /// 这个路径的变化要不要看。不看 include：目录自己不匹配，搬进来的目录下面的文件可能匹配
    public func watches(_ path: String) -> Bool {
        entries.contains { Self.inRule(path, $0) != nil && !isExcluded(path, in: $0) }
    }

    public func concerns(_ path: String, service: String) -> Bool {
        entries.contains { $0.service == service && relative(path, in: $0) != nil }
    }

    /// 扫目录时能不能整个跳过：所有规则都排除了，下面也不会有放回来的
    public func canSkipDirectory(_ path: String, service: String) -> Bool {
        entries.filter { $0.service == service }.allSatisfy { entry in
            guard path == entry.path || path.hasPrefix(entry.path + "/") else {
                return !entry.path.hasPrefix(path + "/") // 不在规则的路径上、也不是它的上层
            }
            guard !entry.ignore.hasNegation, !(entry.contextIgnore?.hasNegation ?? false) else { return false }
            // 不看 include：目录自己不匹配，下面的文件可能匹配
            return isExcluded(path, in: entry)
        }
    }

    /// 这个服务这些路径（真的变了的）要做的事
    /// - onlyInitialSync：第一次起环境时：只看写了 initial_sync 的规则，其余的还没开始。和 compose 一样，sync+exec 写了也不算
    public func plan(service: String, paths: [String], onlyInitialSync: Bool = false) -> WatchPlan {
        var plan = WatchPlan()
        var execRules = Set<Int>()
        for (index, entry) in entries.enumerated() where entry.service == service {
            if onlyInitialSync, !entry.rule.initialSync || ![.sync, .syncRestart].contains(entry.rule.action) { continue }
            for path in paths {
                guard let relative = relative(path, in: entry) else { continue }
                switch entry.rule.action {
                case .rebuild: plan.rebuild = true
                case .restart: plan.restart = true
                case .sync, .syncRestart, .syncExec:
                    guard let target = entry.rule.target else { continue }
                    plan.syncs.append(.init(hostPath: path, containerPath: relative.isEmpty ? target : (target as NSString).appendingPathComponent(relative)))
                    if entry.rule.action == .syncRestart { plan.restart = true }
                    if entry.rule.action == .syncExec, let command = entry.rule.exec, execRules.insert(index).inserted {
                        plan.execs.append(command)
                    }
                }
            }
        }
        return plan
    }

    /// path 在这条规则的范围内就返回它相对规则路径的写法（规则指向它自己时是空字符串），排除了的是 nil
    private func relative(_ path: String, in entry: Entry) -> String? {
        guard let relative = Self.inRule(path, entry), !isExcluded(path, in: entry) else { return nil }
        if !relative.isEmpty, !entry.rule.include.isEmpty, !IgnorePatterns(entry.rule.include).matches(relative) { return nil }
        return relative
    }

    private static func inRule(_ path: String, _ entry: Entry) -> String? {
        if path == entry.path { return "" }
        return path.hasPrefix(entry.path + "/") ? String(path.dropFirst(entry.path.count + 1)) : nil
    }

    /// 被 ignore、构建上下文的忽略文件或固定规则排除了
    private func isExcluded(_ path: String, in entry: Entry) -> Bool {
        if let relative = Self.inRule(path, entry), !relative.isEmpty,
           Self.always.matches(relative) || entry.ignore.matches(relative) {
            return true
        }
        if let context = entry.context, let ignore = entry.contextIgnore, path.hasPrefix(context + "/"),
           ignore.matches(String(path.dropFirst(context.count + 1))) {
            return true
        }
        return false
    }
}

extension SourceFileStat {
    /// 不跟随符号链接；不存在是 nil
    public static func of(_ path: String) -> SourceFileStat? {
        var s = Darwin.stat()
        guard lstat(path, &s) == 0 else { return nil }
        return SourceFileStat(
            inode: UInt64(s.st_ino),
            modifiedNanoseconds: Int64(s.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(s.st_mtimespec.tv_nsec),
            size: Int64(s.st_size),
            mode: UInt32(s.st_mode) & 0o7777,
            isSymlink: (s.st_mode & S_IFMT) == S_IFLNK,
            isDirectory: (s.st_mode & S_IFMT) == S_IFDIR,
            isSpecial: ![S_IFREG, S_IFLNK, S_IFDIR].contains(s.st_mode & S_IFMT)
        )
    }
}

/// 镜像配置里的时间（RFC 3339，小数最多 9 位）是从 1970 年起多少纳秒
public func rfc3339Nanoseconds(_ text: String) -> Int64? {
    // ISO8601DateFormatter 不认 9 位小数，小数单独算
    var seconds = text
    var nanoseconds: Int64 = 0
    if let dot = text.firstIndex(of: "."), let end = text[dot...].dropFirst().firstIndex(where: { !$0.isNumber }) {
        let digits = String(text[text.index(after: dot)..<end]) + String(repeating: "0", count: 9)
        nanoseconds = Int64(digits.prefix(9)) ?? 0
        seconds = String(text[..<dot] + text[end...])
    }
    guard let date = ISO8601DateFormatter().date(from: seconds) else { return nil }
    return Int64(date.timeIntervalSince1970) * 1_000_000_000 + nanoseconds
}

extension WatchMatcher {
    /// 这个服务的规则现在能看到的文件、目录和它们的样子
    public func scan(service: String) -> [String: SourceFileStat] {
        var result: [String: SourceFileStat] = [:]
        for root in paths(service: service) {
            walk(root, service: service, into: &result)
        }
        return result
    }

    /// 把变化的路径展开：搬进来的目录 FSEvents 只报目录本身
    public func files(under path: String, service: String) -> [String: SourceFileStat] {
        var result: [String: SourceFileStat] = [:]
        walk(path, service: service, into: &result)
        return result
    }

    private func walk(_ path: String, service: String, into result: inout [String: SourceFileStat]) {
        guard let stat = SourceFileStat.of(path), !stat.isSpecial else { return }
        guard stat.isDirectory else {
            if concerns(path, service: service) { result[path] = stat }
            return
        }
        if canSkipDirectory(path, service: service) { return }
        if concerns(path, service: service) { result[path] = stat }
        for name in (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? [] {
            walk(path + "/" + name, service: service, into: &result)
        }
    }
}
