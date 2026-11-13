// 把合并好的 compose 树校验并转成 ComposeProject。只支持这里处理的写法，
// 其余写法一律报错并说明原因，不静默忽略。
import Foundation

struct ComposeBuilder {
    /// 相对路径都相对它（多份 compose 时是第一份所在的目录，和 compose 一致）
    var projectDirectory: URL
    /// 取变量：调用方环境优先，其次 .env
    var lookup: (String) -> String?
    var activeProfiles: Set<String>
    /// napbox run：只留要跑的那个服务和它依赖的
    var run: ComposeRun?
    var homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser

    private(set) var issues: [ComposeIssue] = []

    static let defaultMemoryBytes: UInt64 = 1024 * 1024 * 1024

    private static let serviceKeys: Set<String> = [
        "image", "build", "command", "entrypoint", "environment", "env_file", "working_dir", "init", "shm_size",
        "tmpfs", "pull_policy", "stop_grace_period", "container_name", "expose", "ports", "volumes", "depends_on",
        "healthcheck", "restart", "profiles", "networks", "mem_limit", "deploy", "develop", "secrets", "x-napbox",
    ]
    private static let networkKeys: Set<String> = ["cap_add", "privileged", "network_mode"]
    private static let deploymentKeys: Set<String> = ["platform", "logging", "cpus", "pids_limit", "cap_drop", "security_opt", "read_only"]

    mutating func build(_ root: YAMLTree) -> ComposeProject? {
        guard let top = root.entries else {
            issues.append(.invalid("compose 文件的顶层要是映射"))
            return nil
        }
        var volumes: [String] = []
        var networks: Set<String> = ["default"]
        /// 顶层 secrets：名字 → 文件的绝对路径。写法不支持的（已经报过错）记成 nil，服务引用它时不再报“没有声明”
        var secrets: [String: String?] = [:]
        var idleMinutes: Int?
        for (key, value) in top {
            switch key {
            case "services", "name": break // name：napbox 自己给环境命名
            case "version": break // compose 已不再使用这个字段
            case "volumes":
                for (name, v) in value.entries ?? [] {
                    volumes.append(name)
                    for (k, _) in v.entries ?? [] where k != "name" {
                        issues.append(.unsupported("volumes.\(name).\(k)：命名卷只支持 name（由 napbox 按环境管理）"))
                    }
                }
            case "networks":
                for (name, v) in value.entries ?? [] {
                    networks.insert(name)
                    for (k, kv) in v.entries ?? [] {
                        if k == "name" || (k == "driver" && kv.string == "bridge") { continue }
                        // internal 接受但不起作用：所有网络合成了一个，做不到只让其中几个服务断外网。
                        // 要断外网，整个环境用出网模式 none
                        if k == "internal" {
                            _ = bool(kv, "networks.\(name).internal")
                            continue
                        }
                        issues.append(.unsupported("networks.\(name).\(k)：napbox 把所有网络合成一个，只支持 name、driver: bridge 和 internal"))
                    }
                }
            case "x-napbox":
                for (k, v) in value.entries ?? [] {
                    if k == "idle_minutes", let s = v.string, let n = Int(s), n > 0 { idleMinutes = n }
                    else { issues.append(.unsupported("x-napbox.\(k)：不认识的设置或值（顶层只有 idle_minutes，正整数）")) }
                }
            case "secrets":
                for (name, v) in value.entries ?? [] {
                    guard let file = v["file"]?.string, !file.isEmpty else {
                        issues.append(.unsupported("secrets.\(name)：只支持 file（宿主机上的一个文件），environment、external 这些来源不支持"))
                        secrets.updateValue(nil, forKey: name)
                        continue
                    }
                    for (k, _) in v.entries ?? [] where k != "file" {
                        issues.append(.unsupported("secrets.\(name).\(k)：只支持 file"))
                    }
                    secrets[name] = resolve(file).path
                }
            default:
                if key.hasPrefix("x-") { continue }
                issues.append(.unsupported("\(key)：第一版不支持这个顶层字段"))
            }
        }
        guard let serviceEntries = root["services"]?.entries, !serviceEntries.isEmpty else {
            issues.append(.invalid("没有 services"))
            return nil
        }

        var all: [(Service, profiles: [String])] = []
        for (name, value) in serviceEntries {
            if let s = service(name, value, volumes: Set(volumes), networks: networks, secrets: secrets) { all.append(s) }
        }
        if let run {
            guard let i = all.firstIndex(where: { $0.0.name == run.service }) else {
                issues.append(.invalid("没有 \(run.service) 这个服务，有：\(all.map(\.0.name).sorted().joined(separator: "、"))"))
                return nil
            }
            // 和 compose run 一样：点名要跑的服务，它的 profile 跟着启用（它依赖的服务不会因此启用别的 profile）；
            // 命令换成给的（entrypoint 不变）；不给它分配宿主机端口
            activeProfiles.formUnion(all[i].profiles)
            if !run.command.isEmpty { all[i].0.command = run.command }
            if run.noDeps { all[i].0.dependsOn = [] }
            all[i].0.ports = []
        }
        var active = all.filter { s in
            s.profiles.isEmpty || activeProfiles.contains("*") || !activeProfiles.isDisjoint(with: s.profiles)
        }.map(\.0)
        if let run {
            // 只留它和它依赖的（一层层往下找）。别的服务不起，也就不查它们的依赖和端口
            var needed: Set<String> = [], pending = [run.service]
            while let name = pending.popLast() {
                guard needed.insert(name).inserted, let s = active.first(where: { $0.name == name }) else { continue }
                pending += s.dependsOn.map(\.service)
            }
            active = active.filter { needed.contains($0.name) }
            // 前台那个服务跑完环境就销毁：中途不能因为别的服务退出或者源码变了把整个环境重启
            for i in active.indices {
                active[i].restart = .no
                active[i].watch = []
            }
            let used = Set(active.flatMap { $0.namedVolumes.map(\.volume) })
            volumes = volumes.filter(used.contains)
        }
        let activeNames = Set(active.map(\.name))
        let allNames = Set(all.map(\.0.name))
        for s in active {
            for d in s.dependsOn {
                if !allNames.contains(d.service) {
                    issues.append(.invalid("services.\(s.name).depends_on：没有 \(d.service) 这个服务"))
                } else if !activeNames.contains(d.service) {
                    issues.append(.invalid("services.\(s.name).depends_on：\(d.service) 属于没启用的 profile，先启用它"))
                } else if d.condition == .healthy, active.first(where: { $0.name == d.service })?.healthcheck == nil {
                    issues.append(.invalid("services.\(s.name).depends_on.\(d.service)：要求 service_healthy，但 \(d.service) 没有 healthcheck"))
                }
            }
        }
        for s in active where InternalContainers.names.contains(s.name) {
            issues.append(.unsupported("服务名 \(s.name) 是 napbox 自己在用的，请给这个服务改个名字"))
        }
        checkCycles(active)
        checkPortVariables(active)
        checkPortReferences(active)
        // 没启用的 profile 里的服务也留着端口：换 profile 再 up 时端口不变。run 跑完就销毁，不用留
        let reserved = run != nil ? [] : all.map(\.0).filter { !activeNames.contains($0.name) && !$0.ports.isEmpty }
        return ComposeProject(
            services: active.sorted { $0.name < $1.name }, volumes: volumes.sorted(), idleMinutes: idleMinutes, unsetVariables: [],
            reservedPorts: reserved.isEmpty ? nil : Dictionary(uniqueKeysWithValues: reserved.map { ($0.name, $0.ports) })
        )
    }

    // MARK: - 单个服务

    private mutating func service(
        _ name: String, _ tree: YAMLTree, volumes: Set<String>, networks: Set<String>, secrets: [String: String?]
    ) -> (Service, profiles: [String])? {
        guard let entries = tree.entries else {
            issues.append(.invalid("services.\(name)：要是映射"))
            return nil
        }
        let at = "services.\(name)"
        for (key, _) in entries where !Self.serviceKeys.contains(key) && !key.hasPrefix("x-") {
            if Self.networkKeys.contains(key) {
                issues.append(.unsupported("\(at).\(key)：会让服务改动网络规则、绕开出网模式，napbox 不允许"))
            } else if Self.deploymentKeys.contains(key) {
                issues.append(.unsupported("\(at).\(key)：第一版不支持（多用在 staging 或线上部署）"))
            } else {
                issues.append(.unsupported("\(at).\(key)：第一版不支持"))
            }
        }

        var s = Service(
            name: name, image: nil, build: nil, command: nil, entrypoint: nil, environment: [:], workingDir: nil,
            initProcess: false, shmSizeBytes: nil, tmpfs: [], pullPolicy: nil, stopGracePeriodSeconds: nil,
            ports: [], expose: [], volumes: [], dependsOn: [], healthcheck: nil, restart: .no,
            memoryBytes: Self.defaultMemoryBytes, keepAwake: false
        )
        var profiles: [String] = []
        var memLimit: UInt64?
        var deployMemory: UInt64?
        var napboxMemory: UInt64?
        var fileEnvironment: [String: String] = [:]
        var secretFiles: [VolumeMount] = []

        for (key, v) in entries {
            let p = "\(at).\(key)"
            switch key {
            case "image": s.image = scalar(v, p)
            case "build": s.build = build(v, p)
            case "command": s.command = command(v, p)
            case "entrypoint": s.entrypoint = command(v, p)
            case "environment": s.environment = environment(v, p)
            case "env_file": fileEnvironment = envFiles(v, p)
            case "working_dir": s.workingDir = scalar(v, p)
            case "init": s.initProcess = bool(v, p) ?? false
            case "shm_size": s.shmSizeBytes = size(v, p)
            case "tmpfs": s.tmpfs = strings(v, p)
            case "pull_policy":
                switch scalar(v, p) {
                case "always": s.pullPolicy = .always
                case "never": s.pullPolicy = .never
                case "missing", "if_not_present": s.pullPolicy = .missing
                case "build": s.pullPolicy = .build
                case let other?: issues.append(.unsupported("\(p)：\(other) 第一版不支持（支持 always、never、missing、build）"))
                case nil: break
                }
            case "stop_grace_period": s.stopGracePeriodSeconds = duration(v, p)
            case "container_name": break // napbox 自己给容器命名，否则同一个项目开两个 worktree 会重名
            case "expose": s.expose = strings(v, p).compactMap { port($0, p) }
            case "ports": s.ports = ports(v, p)
            case "volumes": s.volumes = mounts(v, p, declared: volumes)
            case "secrets": secretFiles = secretMounts(v, p, declared: secrets)
            case "depends_on": s.dependsOn = dependencies(v, p)
            case "healthcheck": s.healthcheck = healthcheck(v, p)
            case "restart": s.restart = restart(v, p)
            case "profiles": profiles = strings(v, p)
            case "networks":
                let names = ComposeMerge.asMapping(v, listStyle: .names).entries ?? []
                for (n, nv) in names {
                    if !networks.contains(n) { issues.append(.invalid("\(p)：没有声明网络 \(n)")) }
                    for (k, _) in nv.entries ?? [] { issues.append(.unsupported("\(p).\(n).\(k)：napbox 把所有网络合成一个，不支持网络级别的设置")) }
                }
            case "mem_limit": memLimit = size(v, p)
            case "deploy": deployMemory = deploy(v, p)
            case "develop":
                for (k, kv) in xv(v, p) {
                    if k == "watch" { s.watch = watchRules(kv, "\(p).watch") }
                    else if !k.hasPrefix("x-") { issues.append(.unsupported("\(p).\(k)：只支持 watch")) }
                }
            case "x-napbox":
                for (k, xval) in xv(v, p) {
                    switch k {
                    case "memory": napboxMemory = size(xval, "\(p).memory")
                    case "keep_awake": s.keepAwake = bool(xval, "\(p).keep_awake") ?? false
                    default: issues.append(.unsupported("\(p).\(k)：不认识的设置（服务里只有 memory、keep_awake）"))
                    }
                }
            default: break
            }
        }
        s.environment = fileEnvironment.merging(s.environment) { _, new in new }
        s.volumes += secretFiles
        s.memoryBytes = memLimit ?? deployMemory ?? napboxMemory ?? Self.defaultMemoryBytes
        if s.image == nil, s.build == nil {
            issues.append(.invalid("\(at)：要写 image 或 build"))
        }
        if s.build != nil, s.pullPolicy == .always {
            issues.append(.unsupported("\(at).pull_policy：always 和 build 一起写时 Docker 会先从仓库拉，napbox 写了 build 就只构建。要每次都构建请写 pull_policy: build"))
        }
        for (i, rule) in s.watch.enumerated() {
            if rule.action == .rebuild, s.build == nil {
                issues.append(.invalid("\(at).develop.watch[\(i)]：rebuild 要有 build"))
            }
        }
        return (s, profiles)
    }

    private mutating func watchRules(_ v: YAMLTree, _ p: String) -> [WatchRule] {
        guard case .sequence(let items) = v else {
            if v != .null { issues.append(.invalid("\(p)：要是列表")) }
            return []
        }
        return items.enumerated().compactMap { i, item in
            let at = "\(p)[\(i)]"
            guard let entries = item.entries else {
                issues.append(.invalid("\(at)：要是映射"))
                return nil
            }
            var action: WatchRule.Action?
            var path: String?
            var rule = WatchRule(action: .sync, path: "", target: nil, ignore: [], include: [], initialSync: false, exec: nil)
            for (k, kv) in entries {
                let kp = "\(at).\(k)"
                switch k {
                case "action":
                    if let parsed = kv.string.flatMap(WatchRule.Action.init(rawValue:)) { action = parsed }
                    else { issues.append(.invalid("\(kp)：只能是 sync、rebuild、restart、sync+restart、sync+exec")) }
                case "path": path = scalar(kv, kp)
                case "target":
                    let target = scalar(kv, kp)
                    if let target, !target.hasPrefix("/") { issues.append(.unsupported("\(kp)：\(target) 要写容器里的绝对路径")) }
                    rule.target = target
                case "ignore": rule.ignore = strings(kv, kp)
                case "include": rule.include = strings(kv, kp)
                case "initial_sync": rule.initialSync = bool(kv, kp) ?? false
                case "exec":
                    for (ek, ev) in xv(kv, kp) {
                        if ek == "command" { rule.exec = command(ev, "\(kp).command") }
                        else { issues.append(.unsupported("\(kp).\(ek)：只支持 command")) }
                    }
                default:
                    if !k.hasPrefix("x-") { issues.append(.unsupported("\(kp)：不支持")) }
                }
            }
            guard let action else {
                if !entries.contains(where: { $0.key == "action" }) { issues.append(.invalid("\(at)：要写 action")) }
                return nil
            }
            guard let path else {
                issues.append(.invalid("\(at)：要写 path"))
                return nil
            }
            rule.action = action
            rule.path = resolve(path).path
            if action.syncs, rule.target == nil { issues.append(.invalid("\(at)：\(action.rawValue) 要写 target")) }
            if action == .syncExec, rule.exec == nil { issues.append(.invalid("\(at)：sync+exec 要写 exec.command")) }
            return rule
        }
    }

    // MARK: - 字段

    private mutating func scalar(_ v: YAMLTree, _ p: String) -> String? {
        if let s = v.string { return s }
        if v != .null { issues.append(.invalid("\(p)：要是字符串")) }
        return nil
    }

    private mutating func bool(_ v: YAMLTree, _ p: String) -> Bool? {
        switch v.string {
        case "true", "True", "TRUE": return true
        case "false", "False", "FALSE": return false
        default:
            issues.append(.invalid("\(p)：要是 true 或 false"))
            return nil
        }
    }

    private mutating func strings(_ v: YAMLTree, _ p: String) -> [String] {
        switch v {
        case .scalar(let s, _): return [s]
        case .sequence(let items):
            return items.enumerated().compactMap { i, item in
                if let s = item.string { return s }
                issues.append(.invalid("\(p)[\(i)]：要是字符串"))
                return nil
            }
        case .null: return []
        case .mapping: issues.append(.invalid("\(p)：要是列表")); return []
        }
    }

    private mutating func duration(_ v: YAMLTree, _ p: String) -> Double? {
        guard let s = scalar(v, p) else { return nil }
        guard let d = ComposeValues.seconds(s) else { issues.append(.invalid("\(p)：时长写法不对：\(s)")); return nil }
        return d
    }

    private mutating func size(_ v: YAMLTree, _ p: String) -> UInt64? {
        guard let s = scalar(v, p) else { return nil }
        guard let b = ComposeValues.bytes(s) else { issues.append(.invalid("\(p)：大小写法不对：\(s)")); return nil }
        return b
    }

    private mutating func xv(_ v: YAMLTree, _ p: String) -> [(key: String, value: YAMLTree)] {
        if let e = v.entries { return e }
        if v != .null { issues.append(.invalid("\(p)：要是映射")) }
        return []
    }

    private mutating func command(_ v: YAMLTree, _ p: String) -> [String]? {
        if case .scalar(let s, _) = v {
            guard let words = ComposeValues.shellSplit(s) else { issues.append(.invalid("\(p)：引号没有闭合")); return nil }
            return words
        }
        if v == .null { return nil }
        return strings(v, p)
    }

    private mutating func environment(_ v: YAMLTree, _ p: String) -> [String: String] {
        var env: [String: String] = [:]
        let map = ComposeMerge.asMapping(v, listStyle: .keyValue)
        guard let entries = map.entries else {
            if v != .null { issues.append(.invalid("\(p)：要是映射或 KEY=VALUE 列表")) }
            return env
        }
        for (k, value) in entries {
            switch value {
            case .null: if let fromCaller = lookup(k) { env[k] = fromCaller } // 只写名字：取调用方环境里的值
            case .scalar(let s, _): env[k] = s
            default: issues.append(.invalid("\(p).\(k)：值要是字符串、数字或布尔"))
            }
        }
        return env
    }

    private mutating func envFiles(_ v: YAMLTree, _ p: String) -> [String: String] {
        var env: [String: String] = [:]
        let items: [YAMLTree] = if case .sequence(let s) = v { s } else { [v] }
        for (i, item) in items.enumerated() {
            var path: String?
            var required = true
            if let s = item.string {
                path = s
            } else if let e = item.entries {
                for (k, kv) in e {
                    switch k {
                    case "path": path = kv.string
                    case "required": required = bool(kv, "\(p)[\(i)].required") ?? true
                    default: issues.append(.unsupported("\(p)[\(i)].\(k)：第一版只支持 path 和 required"))
                    }
                }
            }
            guard let path else { issues.append(.invalid("\(p)[\(i)]：要写文件路径")); continue }
            let url = resolve(path)
            guard let text = try? String(contentsOf: url, encoding: .utf8) else {
                if required { issues.append(.invalid("\(p)：读不到 \(url.path)")) }
                continue
            }
            do {
                for (k, value) in try DotEnv.parse(text, file: url.path, lookup: lookup) { env[k] = value }
            } catch {
                issues.append(contentsOf: error.issues)
            }
        }
        return env
    }

    private mutating func build(_ v: YAMLTree, _ p: String) -> Build? {
        guard let entries = ComposeMerge.asBuild(v).entries else { issues.append(.invalid("\(p)：要是路径或映射")); return nil }
        var b = Build(context: projectDirectory.path, dockerfile: nil, target: nil, args: [:])
        for (k, kv) in entries {
            switch k {
            case "context": if let c = scalar(kv, "\(p).context") { b.context = resolve(c).path }
            case "dockerfile": b.dockerfile = scalar(kv, "\(p).dockerfile")
            case "target": b.target = scalar(kv, "\(p).target")
            case "args": b.args = environment(kv, "\(p).args")
            default: issues.append(.unsupported("\(p).\(k)：第一版只支持 context、dockerfile、target、args"))
            }
        }
        return b
    }

    private mutating func ports(_ v: YAMLTree, _ p: String) -> [Int] {
        guard case .sequence(let items) = v else {
            if v != .null { issues.append(.invalid("\(p)：要是列表")) }
            return []
        }
        var result: [Int] = []
        for (i, item) in items.enumerated() {
            let ip = "\(p)[\(i)]"
            if let s = item.string {
                // [宿主机 IP:][宿主机端口:]容器端口[/协议]，只取容器端口
                let containerPart = s.split(separator: ":", omittingEmptySubsequences: false).last.map(String.init) ?? ""
                if let port = port(containerPart, ip) { result.append(port) }
            } else if let e = item.entries {
                var target: Int?
                for (k, kv) in e {
                    switch k {
                    case "target": target = kv.string.flatMap { port($0, "\(ip).target") }
                    case "published", "host_ip", "name", "mode", "app_protocol": break // 宿主机这边由 napbox 决定
                    case "protocol":
                        if kv.string != "tcp" { issues.append(.unsupported("\(ip).protocol：只支持 tcp")) }
                    default: issues.append(.unsupported("\(ip).\(k)：第一版不支持"))
                    }
                }
                if let target { result.append(target) } else { issues.append(.invalid("\(ip)：要写 target")) }
            } else {
                issues.append(.invalid("\(ip)：要是字符串或映射"))
            }
        }
        var seen = Set<Int>()
        return result.filter { seen.insert($0).inserted }
    }

    /// `80`、`80/tcp`；只支持 tcp（端口代理只转发 tcp）。
    private mutating func port(_ text: String, _ p: String) -> Int? {
        var t = Substring(text)
        if let slash = t.lastIndex(of: "/") {
            let proto = t[t.index(after: slash)...]
            guard proto == "tcp" else { issues.append(.unsupported("\(p)：只支持 tcp，不支持 \(proto)")); return nil }
            t = t[..<slash]
        }
        if t.contains("-") { issues.append(.unsupported("\(p)：端口范围 \(text) 第一版不支持，请逐个写")); return nil }
        guard let n = Int(t), (1...65535).contains(n) else { issues.append(.invalid("\(p)：端口写法不对：\(text)")); return nil }
        return n
    }

    private mutating func mounts(_ v: YAMLTree, _ p: String, declared: Set<String>) -> [VolumeMount] {
        guard case .sequence(let items) = v else {
            if v != .null { issues.append(.invalid("\(p)：要是列表")) }
            return []
        }
        var result: [VolumeMount] = []
        for (i, item) in items.enumerated() {
            let ip = "\(p)[\(i)]"
            var source: String?
            var target: String?
            var readOnly = false
            var type: String?
            if let s = item.string {
                let parts = s.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
                guard parts.count == 2 || parts.count == 3 else {
                    issues.append(.unsupported("\(ip)：只写容器路径的匿名卷第一版不支持，请用命名卷"))
                    continue
                }
                source = parts[0]
                target = parts[1]
                if parts.count == 3 {
                    for option in parts[2].split(separator: ",") {
                        switch option {
                        case "ro": readOnly = true
                        case "rw", "cached", "delegated", "consistent", "z", "Z": break
                        default: issues.append(.unsupported("\(ip)：挂载选项 \(option) 第一版不支持"))
                        }
                    }
                }
            } else if let e = item.entries {
                for (k, kv) in e {
                    switch k {
                    case "type": type = kv.string
                    case "source": source = kv.string
                    case "target": target = kv.string
                    case "read_only": readOnly = bool(kv, "\(ip).read_only") ?? false
                    default: issues.append(.unsupported("\(ip).\(k)：第一版只支持 type、source、target、read_only"))
                    }
                }
                if let type, type != "volume", type != "bind" {
                    issues.append(.unsupported("\(ip).type：\(type) 第一版不支持（支持 volume、bind）"))
                    continue
                }
            } else {
                issues.append(.invalid("\(ip)：要是字符串或映射"))
                continue
            }
            guard let source, !source.isEmpty, let target, target.hasPrefix("/") else {
                issues.append(.invalid("\(ip)：要写来源和容器里的绝对路径"))
                continue
            }
            let isPath = source.hasPrefix(".") || source.hasPrefix("/") || source.hasPrefix("~")
            if type == "bind" || (type == nil && isPath) {
                result.append(VolumeMount(source: .bind(resolve(source).path), target: target, readOnly: readOnly))
            } else if declared.contains(source) {
                result.append(VolumeMount(source: .named(source), target: target, readOnly: readOnly))
            } else {
                issues.append(.invalid("\(ip)：命名卷 \(source) 没有在顶层 volumes 里声明"))
            }
        }
        return result
    }

    /// 服务的 secrets：顶层声明的文件只读挂到 /run/secrets/<名字>，和 Docker 一样
    private mutating func secretMounts(_ v: YAMLTree, _ p: String, declared: [String: String?]) -> [VolumeMount] {
        guard case .sequence(let items) = v else {
            if v != .null { issues.append(.invalid("\(p)：要是列表")) }
            return []
        }
        var result: [VolumeMount] = []
        for (i, item) in items.enumerated() {
            guard let name = item.string else {
                issues.append(.unsupported("\(p)[\(i)]：只支持直接写名字，source、target、mode 这种展开的写法不支持"))
                continue
            }
            guard let file = declared[name] else {
                issues.append(.invalid("\(p)：\(name) 没有在顶层 secrets 里声明"))
                continue
            }
            if let file { result.append(VolumeMount(source: .secret(file), target: "/run/secrets/\(name)", readOnly: true)) }
        }
        return result
    }

    private mutating func dependencies(_ v: YAMLTree, _ p: String) -> [Dependency] {
        guard let entries = ComposeMerge.asMapping(v, listStyle: .dependency).entries else {
            issues.append(.invalid("\(p)：要是列表或映射"))
            return []
        }
        return entries.compactMap { name, dv in
            var condition = Dependency.Condition.started
            for (k, kv) in dv.entries ?? [] {
                switch k {
                case "condition":
                    if let c = kv.string.flatMap(Dependency.Condition.init(rawValue:)) { condition = c }
                    else { issues.append(.invalid("\(p).\(name).condition：只能是 service_started、service_healthy、service_completed_successfully")) }
                default: issues.append(.unsupported("\(p).\(name).\(k)：第一版只支持 condition"))
                }
            }
            return Dependency(service: name, condition: condition)
        }
    }

    private mutating func healthcheck(_ v: YAMLTree, _ p: String) -> Healthcheck? {
        guard let entries = v.entries else { issues.append(.invalid("\(p)：要是映射")); return nil }
        var test: Healthcheck.Test?
        var h = Healthcheck(test: .shell(""), intervalSeconds: 30, timeoutSeconds: 30, retries: 3, startPeriodSeconds: 0, startIntervalSeconds: 5)
        var disabled = false
        for (k, kv) in entries {
            let kp = "\(p).\(k)"
            switch k {
            case "test":
                if case .scalar(let s, _) = kv {
                    test = .shell(s)
                } else {
                    let parts = strings(kv, kp)
                    switch parts.first {
                    case "CMD" where parts.count > 1: test = .exec(Array(parts.dropFirst()))
                    case "CMD-SHELL" where parts.count == 2: test = .shell(parts[1])
                    case "NONE": disabled = true
                    default: issues.append(.invalid("\(kp)：要以 CMD、CMD-SHELL 或 NONE 开头"))
                    }
                }
            case "interval": h.intervalSeconds = duration(kv, kp) ?? h.intervalSeconds
            case "timeout": h.timeoutSeconds = duration(kv, kp) ?? h.timeoutSeconds
            case "start_period": h.startPeriodSeconds = duration(kv, kp) ?? h.startPeriodSeconds
            case "start_interval": h.startIntervalSeconds = duration(kv, kp) ?? h.startIntervalSeconds
            case "retries":
                if let s = kv.string, let n = Int(s), n >= 0 { h.retries = n } else { issues.append(.invalid("\(kp)：要是非负整数")) }
            case "disable": disabled = bool(kv, kp) ?? false
            default: issues.append(.unsupported("\(kp)：第一版不支持"))
            }
        }
        if disabled { return nil }
        guard let test else { issues.append(.invalid("\(p)：要写 test")); return nil }
        h.test = test
        return h
    }

    private mutating func restart(_ v: YAMLTree, _ p: String) -> RestartPolicy {
        switch scalar(v, p) {
        case "no", nil: return .no
        case "always": return .always
        case "unless-stopped": return .unlessStopped
        case "on-failure": return .onFailure(maxRetries: nil)
        case let s? where s.hasPrefix("on-failure:"):
            if let n = Int(s.dropFirst("on-failure:".count)), n >= 0 { return .onFailure(maxRetries: n) }
            issues.append(.invalid("\(p)：\(s) 写法不对"))
            return .no
        case let s?:
            issues.append(.invalid("\(p)：\(s) 不是有效的重启策略"))
            return .no
        }
    }

    private mutating func deploy(_ v: YAMLTree, _ p: String) -> UInt64? {
        var memory: UInt64?
        for (k, kv) in xv(v, p) {
            guard k == "resources" else { issues.append(.unsupported("\(p).\(k)：deploy 里第一版只支持 resources.limits.memory")); continue }
            for (rk, rv) in xv(kv, "\(p).resources") {
                guard rk == "limits" else { issues.append(.unsupported("\(p).resources.\(rk)：第一版只支持 limits.memory")); continue }
                for (lk, lv) in xv(rv, "\(p).resources.limits") {
                    if lk == "memory" { memory = size(lv, "\(p).resources.limits.memory") }
                    else { issues.append(.unsupported("\(p).resources.limits.\(lk)：第一版只支持 memory")) }
                }
            }
        }
        return memory
    }

    /// 相对路径相对项目目录；`~` 是用户目录。
    func resolve(_ path: String) -> URL {
        if path == "~" { return homeDirectory }
        if path.hasPrefix("~/") { return homeDirectory.appending(path: String(path.dropFirst(2))).standardizedFileURL }
        if path.hasPrefix("/") { return URL(fileURLWithPath: path).standardizedFileURL }
        return projectDirectory.appending(path: path).standardizedFileURL
    }

    // MARK: - 跨服务的检查

    private mutating func checkCycles(_ services: [Service]) {
        let deps = Dictionary(uniqueKeysWithValues: services.map { ($0.name, $0.dependsOn.map(\.service)) })
        var state: [String: Int] = [:] // 1 = 访问中，2 = 完成
        var reported = false
        func visit(_ name: String, _ path: [String]) {
            if reported { return }
            if state[name] == 1 {
                let cycle = path.drop { $0 != name } + [name]
                issues.append(.invalid("depends_on 有循环：\(cycle.joined(separator: " → "))"))
                reported = true
                return
            }
            if state[name] == 2 { return }
            state[name] = 1
            for d in deps[name] ?? [] where deps[d] != nil { visit(d, path + [name]) }
            state[name] = 2
        }
        for s in services { visit(s.name, []) }
    }

    /// 环境变量名 NAPBOX_<服务>_<端口> 不能撞名（比如 web-api 和 web_api）。
    private mutating func checkPortVariables(_ services: [Service]) {
        var owners: [String: String] = [:]
        for s in services {
            for port in s.ports {
                let name = PortVariables.name(service: s.name, port: port)
                if let other = owners[name], other != s.name {
                    issues.append(.unsupported("服务 \(other) 和 \(s.name) 的端口变量都叫 \(name)，请改其中一个服务名"))
                }
                owners[name] = s.name
            }
        }
    }

    /// 引用的端口变量（PortReferences）只能用在 environment（含 env_file）里，要是启用的服务在 ports 里写的端口：
    /// 地址要到起服务时才填，别的字段（镜像、命令、挂载）读 compose 时就要定下来。
    private mutating func checkPortReferences(_ services: [Service]) {
        let known = Set(services.flatMap { s in s.ports.map { PortVariables.name(service: s.name, port: $0) } })
        for s in services {
            for (k, v) in s.environment.sorted(by: { $0.key < $1.key }) {
                for name in PortReferences.names(in: v) where !known.contains(name) {
                    issues.append(.invalid("services.\(s.name).environment.\(k)：\(name) 不是这个环境的端口变量，要是启用的服务在 ports 里写的端口"))
                }
            }
            var rest = s
            rest.environment = [:]
            let text = (try? JSONEncoder().encode(rest)).map { String(decoding: $0, as: UTF8.self) } ?? ""
            if text.contains("\\u0001") {
                issues.append(.unsupported("services.\(s.name)：NAPBOX_ 开头的端口变量只能用在 environment 和 env_file 里"))
            }
        }
    }
}
