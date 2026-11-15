import Darwin
import Foundation
import Testing
@testable import NapboxCore
import NapboxProtocol

@Suite struct WorktreeTests {
    /// 临时建一个仓库和一个 worktree，用真实的 git 判断。
    @Test func locateMainAndLinkedWorktree() throws {
        try withProject(["Pawcode/README": "x"]) { dir in
            let repo = dir.appending(path: "Pawcode")
            for args in [["init", "-q"], ["-c", "user.email=t@t", "-c", "user.name=t", "add", "."],
                         ["-c", "user.email=t@t", "-c", "user.name=t", "commit", "-qm", "init"],
                         ["worktree", "add", "-q", "../wt/Inventory-Ledger"]] {
                _ = try Git.run(["-C", repo.path] + args)
            }
            try FileManager.default.createDirectory(at: repo.appending(path: "sub"), withIntermediateDirectories: true)
            let main = try WorktreeLocation.locate(from: repo.appending(path: "sub"))
            #expect(main.isMain)
            #expect(main.mainRepository.path == repo.path)

            let linked = try WorktreeLocation.locate(from: dir.appending(path: "wt/Inventory-Ledger"))
            #expect(!linked.isMain)
            #expect(linked.mainRepository.path == repo.path)
            #expect(linked.worktree.lastPathComponent == "Inventory-Ledger")

            let state = NapboxState()
            #expect(state.environmentName(for: main) == "pawcode/main")
            #expect(state.environmentName(for: linked) == "pawcode/inventory-ledger")
        }
    }

    /// worktree 删除检测：正常的、git worktree remove 掉的、目录直接删掉没 prune 的、目录还在但已经不是 worktree 的、
    /// 主仓库没了的，以及 git 查不了的（.git 是空目录）
    @Test func worktreePresence() throws {
        try withProject(["Pawcode/README": "x"]) { dir in
            let repo = dir.appending(path: "Pawcode").resolvingSymlinksInPath()
            for args in [["init", "-q"], ["-c", "user.email=t@t", "-c", "user.name=t", "add", "."],
                         ["-c", "user.email=t@t", "-c", "user.name=t", "commit", "-qm", "init"],
                         ["worktree", "add", "-q", "../wt/a"], ["worktree", "add", "-q", "../wt/b"], ["worktree", "add", "-q", "../wt/c"]] {
                _ = try Git.run(["-C", repo.path] + args)
            }
            let wt = dir.appending(path: "wt").resolvingSymlinksInPath()
            func check(_ path: URL) -> WorktreePresence { WorktreePresence.check(worktree: path.path, mainRepository: repo.path) }
            #expect(check(repo) == .present)
            #expect(check(wt.appending(path: "a")) == .present)

            _ = try Git.run(["-C", repo.path, "worktree", "remove", "../wt/a"])
            guard case .gone = check(wt.appending(path: "a")) else { Issue.record("remove 之后应该是 gone"); return }

            try FileManager.default.removeItem(at: wt.appending(path: "b"))
            guard case .gone = check(wt.appending(path: "b")) else { Issue.record("目录删掉后应该是 gone"); return }

            _ = try Git.run(["-C", repo.path, "worktree", "remove", "../wt/c"])
            try FileManager.default.createDirectory(at: wt.appending(path: "c"), withIntermediateDirectories: true)
            guard case .gone = check(wt.appending(path: "c")) else { Issue.record("目录还在但不是 worktree 应该是 gone"); return }

            // 主仓库的 .git 换成空目录：git 查不了，不能当成删掉了
            let broken = dir.appending(path: "Broken").resolvingSymlinksInPath()
            try FileManager.default.createDirectory(at: broken.appending(path: ".git"), withIntermediateDirectories: true)
            guard case .unknown = WorktreePresence.check(worktree: broken.path, mainRepository: broken.path) else {
                Issue.record("git 查不了时应该是 unknown"); return
            }
            #expect(WorktreePresence.check(worktree: repo.path, mainRepository: dir.appending(path: "Gone").path)
                == .gone("主仓库 \(dir.appending(path: "Gone").path) 不在了"))
        }
    }

    @Test func notInRepository() throws {
        try withProject(["x": ""]) { dir in
            #expect { try WorktreeLocation.locate(from: dir) } throws: { ($0 as? NapboxError)?.code == "not_in_repository" }
        }
    }
}

@Suite struct NamingTests {
    func record(_ name: String, project: String, repo: String, worktree: String) -> EnvironmentRecord {
        EnvironmentRecord(name: name, project: project, mainRepository: repo, worktree: worktree, owner: .worktree)
    }

    @Test func reuseAndCollisions() {
        var state = NapboxState()
        state.environments = [
            record("pawcode/main", project: "pawcode", repo: "/a/Pawcode", worktree: "/a/Pawcode"),
            record("pawcode/x", project: "pawcode", repo: "/a/Pawcode", worktree: "/a/Pawcode/.claude/worktrees/x"),
        ]
        let loc = { (repo: String, wt: String) in WorktreeLocation(mainRepository: URL(fileURLWithPath: repo), worktree: URL(fileURLWithPath: wt)) }
        // 同一个 worktree 一直用同一个名字
        #expect(state.environmentName(for: loc("/a/Pawcode", "/a/Pawcode/.claude/worktrees/x")) == "pawcode/x")
        // 同一个项目里另一个同名目录的 worktree
        #expect(state.environmentName(for: loc("/a/Pawcode", "/elsewhere/x")) == "pawcode/x-2")
        // 别的仓库刚好也叫 pawcode
        #expect(state.environmentName(for: loc("/b/pawcode", "/b/pawcode")) == "pawcode-2/main")
        // 中文目录名照用
        #expect(state.environmentName(for: loc("/a/搭档", "/a/搭档")) == "搭档/main")
    }

    /// 临时环境的名字是开发环境的名字再加一段，不占开发环境的名字
    @Test func temporaryNames() {
        let loc = { (repo: String, wt: String) in WorktreeLocation(mainRepository: URL(fileURLWithPath: repo), worktree: URL(fileURLWithPath: wt)) }
        var state = NapboxState()
        state.environments = [record("pawcode/main", project: "pawcode", repo: "/a/Pawcode", worktree: "/a/Pawcode")]
        #expect(state.environmentName(for: loc("/a/Pawcode", "/a/Pawcode"), temporary: "db-test") == "pawcode/main/db-test")
        #expect(state.environmentName(for: loc("/a/Pawcode", "/a/Pawcode/wt/x"), temporary: "db-test") == "pawcode/x/db-test")

        // 只起过临时环境的 worktree：开发环境的名字从临时环境的名字里取，不重新算
        var temp = EnvironmentRecord(name: "pawcode/x-2/t1", project: "pawcode", mainRepository: "/a/Pawcode", worktree: "/elsewhere/x", owner: .worktree)
        temp.temporary = "t1"
        state.environments.append(temp)
        #expect(state.environmentName(for: loc("/a/Pawcode", "/elsewhere/x")) == "pawcode/x-2")
        #expect(state.environmentName(for: loc("/a/Pawcode", "/elsewhere/x"), temporary: "t2") == "pawcode/x-2/t2")
        // 别的 worktree 算名字时，pawcode/x-2 算被占着
        temp.name = "pawcode/x/t1"
        state.environments[1] = temp
        #expect(state.environmentName(for: loc("/a/Pawcode", "/a/Pawcode/wt/x")) == "pawcode/x-2")
        // 名字归谁：有同名的环境就是它；只有临时环境挂在下面时归那个临时环境；再往下一段不算
        #expect(state.holder(of: "pawcode/main")?.worktree == "/a/Pawcode")
        #expect(state.holder(of: "pawcode/x")?.name == "pawcode/x/t1")
        #expect(state.holder(of: "pawcode/x/t1")?.name == "pawcode/x/t1")
        #expect(state.holder(of: "pawcode/x-2") == nil)
        #expect(state.holder(of: "pawcode/ma") == nil)

        // 按 worktree 找：开发环境和临时环境分开找
        #expect(state.environment(worktree: "/a/Pawcode", temporary: nil)?.name == "pawcode/main")
        #expect(state.environment(worktree: "/a/Pawcode", temporary: "t1") == nil)
        #expect(state.environment(worktree: "/elsewhere/x", temporary: "t1")?.name == "pawcode/x/t1")
        #expect(state.environment(worktree: "/elsewhere/x", temporary: nil) == nil)
    }

    @Test(arguments: ["db-test", "a", "run-1a2b3c4d", "t_1.x", String(repeating: "a", count: 40)])
    func validTemporaryNames(name: String) throws {
        try TemporaryEnvironment.validate(name: name)
    }

    @Test(arguments: ["", "DB", "-x", "a/b", "a b", "测试", String(repeating: "a", count: 41)])
    func invalidTemporaryNames(name: String) {
        #expect(throws: NapboxError.self) { try TemporaryEnvironment.validate(name: name) }
    }

    @Test func generatedTemporaryNamesAreValidAndDiffer() throws {
        let a = TemporaryEnvironment.generatedName(), b = TemporaryEnvironment.generatedName()
        try TemporaryEnvironment.validate(name: a)
        #expect(a != b)
    }

    /// 旧的 state.json 里没有 temporary 这一项，读出来是普通环境
    @Test func recordWithoutTemporaryDecodes() throws {
        let plain = record("pawcode/main", project: "pawcode", repo: "/a/Pawcode", worktree: "/a/Pawcode")
        let json = String(decoding: try JSONEncoder().encode(plain), as: UTF8.self)
        #expect(!json.contains("temporary"))
        #expect(try JSONDecoder().decode(EnvironmentRecord.self, from: Data(json.utf8)) == plain)
    }

    /// 没做完的操作记在 state.json 里，napboxd 重启后读得回来；没有这一项时是 nil
    @Test func pendingOperationRoundTrips() throws {
        var r = record("pawcode/main", project: "pawcode", repo: "/a/Pawcode", worktree: "/a/Pawcode")
        #expect(!String(decoding: try JSONEncoder().encode(r), as: UTF8.self).contains("pending"))
        let seed = SeedSource(environment: "pawcode/other", takenAt: Date(timeIntervalSince1970: 1_800_000_000), volumes: ["db"])
        for pending: EnvironmentRecord.PendingOperation in [.recycle(reason: "napbox down", discardData: true),
                                                            .replaceVolumes(volumes: ["db"], seed: seed),
                                                            .replaceVolumes(volumes: ["db"], seed: nil)] {
            r.pending = pending
            #expect(try JSONDecoder().decode(EnvironmentRecord.self, from: try JSONEncoder().encode(r)) == r)
        }
        // test-native.sh 伪造 state.json 时照这个写法
        let reset = try JSONSerialization.jsonObject(with: try JSONEncoder().encode(r)) as? [String: Any]
        #expect((reset?["pending"] as? [String: [String: [String]]]) == ["replaceVolumes": ["volumes": ["db"]]])
    }

    @Test func storeRoundTripAndCorruption() throws {
        try withProject(["x": ""]) { dir in
            let url = dir.appending(path: "state.json")
            let store = try StateStore(url: url)
            #expect(store.state.environments.isEmpty)
            try store.update { s throws(NapboxError) in
                s.environments.append(EnvironmentRecord(name: "p/main", project: "p", mainRepository: "/p", worktree: "/p", owner: .worktree,
                                                        ports: [PortAssignment(service: "db", containerPort: 5432, hostPort: 40000)]))
            }
            #expect(try StateStore(url: url).state == store.state)
            var info = stat()
            stat(url.path, &info)
            #expect(info.st_mode & 0o777 == 0o600)

            // body 抛错时不写
            #expect(throws: NapboxError.self) {
                try store.update { s throws(NapboxError) in
                    s.environments.removeAll()
                    throw NapboxError(.internalError, "x")
                }
            }
            #expect(try StateStore(url: url).state.environments.count == 1)

            try "{oops".write(to: url, atomically: true, encoding: .utf8)
            #expect { try StateStore(url: url) } throws: { ($0 as? NapboxError)?.code == "state_corrupted" }

            // 格式版本对不上：说清楚是版本的问题，不当成别的错
            try #"{"version": 2, "environments": []}"#.write(to: url, atomically: true, encoding: .utf8)
            #expect { try StateStore(url: url) } throws: { error in
                guard let e = error as? NapboxError else { return false }
                return e.code == "state_corrupted" && e.message.contains("第 2 版") && e.message.contains("只认第 1 版")
            }
        }
    }
}

@Suite struct EgressRulesTests {
    @Test func uncoveredDropsAddressesInBlockedRanges() {
        let host = ["10.1.2.3", "100.100.1.1", "169.254.3.4", "172.20.0.1", "192.168.64.1", "fd00::1", "fe80::1",
                    "198.18.0.1", "203.0.113.7", "2001:db8::1", "172.32.0.1", "not-an-ip"]
        #expect(EgressRules.uncovered(host) == ["198.18.0.1", "203.0.113.7", "2001:db8::1", "172.32.0.1", "not-an-ip"])
    }

    @Test func guardArguments() {
        #expect(EgressRules.guardArguments(.none, hostAddresses: []) == ["none"])
        let open = EgressRules.guardArguments(.open, hostAddresses: ["198.18.0.1"])
        #expect(open == ["open", "192.168.64.1"] + EgressRules.blockedRanges + ["198.18.0.1"])
    }
}

@Suite struct AddressTests {
    /// 构建虚拟机每次换一个地址，转完一圈回到开头，不会用到环境的地址段
    @Test func builderAddressRotates() {
        #expect(AddressAllocator.builderAddress(after: "") == "192.168.64.247")
        #expect(AddressAllocator.builderAddress(after: "192.168.64.247") == "192.168.64.248")
        #expect(AddressAllocator.builderAddress(after: "192.168.64.254") == "192.168.64.247")
        // 文件内容看不懂、或者不在这一段时从头开始
        #expect(AddressAllocator.builderAddress(after: "乱写") == "192.168.64.247")
        #expect(AddressAllocator.builderAddress(after: "192.168.64.128") == "192.168.64.247")
        #expect(AddressAllocator.builderAddress(after: "10.0.0.250") == "192.168.64.247")
        #expect(AddressAllocator.builderHosts.allSatisfy { !AddressAllocator.hosts.contains($0) })
    }

    /// MAC 跟着 IP 固定：同一个 IP 每次一样，napbox 用的地址段里各不相同，都是本地分配的单播地址
    @Test func macFollowsIP() throws {
        #expect(try AddressAllocator.macAddress(for: "192.168.64.128") == [0x02, 0x6e, 0x62, 0x00, 64, 128])
        let macs = try AddressAllocator.hosts.map { try AddressAllocator.macAddress(for: "\(AddressAllocator.prefix)\($0)") }
        #expect(Set(macs).count == AddressAllocator.hosts.count)
        #expect(macs.allSatisfy { $0[0] & 0x02 != 0 && $0[0] & 0x01 == 0 })
        #expect { try AddressAllocator.macAddress(for: "fe80::1") } throws: { ($0 as? NapboxError)?.code == "internal_error" }
    }

    /// 服务的地址只看服务名：按名字排序从 .2 起，和传进来的顺序无关，每次算出来一样；不会给出网关的地址
    @Test func serviceAddresses() throws {
        let addresses = try ServiceNetwork.addresses(["web", "db", "api"])
        #expect(addresses == ["api": "10.88.0.2", "db": "10.88.0.3", "web": "10.88.0.4"])
        #expect(try ServiceNetwork.addresses(["db", "api", "web"]) == addresses)
        #expect(try ServiceNetwork.addresses([]).isEmpty)
        #expect(ServiceNetwork.gateway == "10.88.0.1")

        let most = (0..<253).map { "s\($0)" }
        let all = try ServiceNetwork.addresses(most)
        #expect(Set(all.values).count == 253 && !all.values.contains(ServiceNetwork.gateway) && !all.values.contains("10.88.0.255"))
        #expect { try ServiceNetwork.addresses(most + ["one-more"]) } throws: { ($0 as? NapboxError)?.code == "compose_unsupported" }
    }

    /// 出网规则挡的是私网段，服务的网段在里面：服务连不到别的 10.x 机器；服务之间的连接在规则里先放行（guard/egress.go）
    @Test func serviceNetworkIsPrivate() {
        #expect(EgressRules.blockedRanges.contains("10.0.0.0/8"))
        #expect(ServiceNetwork.gateway.hasPrefix("10."))
    }

    @Test func allocate() throws {
        var state = NapboxState()
        state.environments = [EnvironmentRecord(name: "a/main", project: nil, mainRepository: nil, worktree: "/a", owner: .worktree, ip: "192.168.64.128")]
        // 已有的沿用
        #expect(try AddressAllocator.allocate(environment: "a/main", state: state, inUseOnNetwork: ["192.168.64.128"]) == "192.168.64.128")
        // 跳过登记的和 ARP 表里有的
        #expect(try AddressAllocator.allocate(environment: "b/main", state: state, inUseOnNetwork: ["192.168.64.129"]) == "192.168.64.130")
        let all = Set(AddressAllocator.hosts.map { "192.168.64.\($0)" })
        #expect { try AddressAllocator.allocate(environment: "b/main", state: state, inUseOnNetwork: all) } throws: { ($0 as? NapboxError)?.code == "address_unavailable" }
    }

    @Test func parseArp() {
        let text = """
        ? (192.168.64.1) at 4e:1:2:3:4:64 on bridge100 ifscope permanent [bridge]
        ? (192.168.64.129) at 1a:2b:3c:4d:5e:6f on bridge100 ifscope [bridge]
        ? (192.168.64.130) at (incomplete) on bridge100 ifscope [bridge]
        """
        #expect(NetworkNeighbors.parse(text) == ["192.168.64.1", "192.168.64.129"])
    }
}

@Suite(.serialized) struct PortTests {
    /// 测试用一段不常用的端口，避开 40000–49999 里可能正在用的。
    /// 每个用例用自己的端口，不去绑别的用例（或自己）刚关掉的端口：建子进程时内核把父进程打开的文件
    /// （含 close-on-exec 的）复制给子进程，到子进程 exec 才关，这段时间里刚 close 的监听 socket 还绑着端口，
    /// 再绑报地址被占用（实测最长约 0.7ms）。整组跑时别的用例在同时起子进程，所以会偶尔撞上。
    let range = 38400...38409

    func requests(_ items: [(String, Int)]) -> [PortRequest] { items.map { PortRequest(service: $0.0, containerPort: $0.1) } }

    /// 用 POSIX 直接占一个端口，模拟别的程序（不带 SO_REUSEADDR，和 Docker 一样监听全部地址）。
    /// 排队长度给得和正常程序一样；它从不接受连接，排队太短的话 napbox 的探测可能被挡在外面（PortLocks 说明里的已知误判）
    func occupy(_ port: Int, backlog: Int32 = 128) -> Int32 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(port).bigEndian)
        addr.sin_addr = in_addr(s_addr: INADDR_ANY)
        _ = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        listen(fd, backlog)
        return fd
    }

    /// 登记表：环境名 → 已分配的端口
    func state(_ envs: [String: [PortAssignment]]) -> NapboxState {
        var s = NapboxState()
        s.environments = envs.sorted { $0.key < $1.key }.map {
            EnvironmentRecord(name: $0.key, project: nil, mainRepository: nil, worktree: "/\($0.key)", owner: .worktree, ports: $0.value)
        }
        return s
    }

    @Test func allocateSkipBusyAndStayStable() throws {
        let busy = occupy(range.lowerBound)
        defer { close(busy) }
        let locks = PortLocks()
        // 别的环境登记了 +1（napboxd 重启后没锁上也算它的）
        var registry = state(["other/main": [PortAssignment(service: "db", containerPort: 5432, hostPort: range.lowerBound + 1)]])
        let first = try PortAllocator.assign(requests([("db", 5432), ("api", 3100)]), hostPorts: [], environment: "p/main", state: registry, locks: locks, range: range).ports
        // 第一个被别的程序占着、第二个是别的环境登记的，都跳过
        #expect(first == [
            PortAssignment(service: "api", containerPort: 3100, hostPort: range.lowerBound + 3),
            PortAssignment(service: "db", containerPort: 5432, hostPort: range.lowerBound + 2),
        ])
        #expect(locks.lockedPorts == [range.lowerBound + 2, range.lowerBound + 3])
        // 锁着的端口别人绑不上
        let probe = occupy(range.lowerBound + 2)
        var addr = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let boundElsewhere = withUnsafeMutablePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(probe, $0, &len) } } == 0 && UInt16(bigEndian: addr.sin_port) == UInt16(range.lowerBound + 2)
        close(probe)
        #expect(!boundElsewhere)

        // 写回登记表后，第三个环境不会拿到这两个端口
        registry.environments.append(EnvironmentRecord(name: "p/main", project: nil, mainRepository: nil, worktree: "/p", owner: .worktree, ports: first))
        let third = try PortAllocator.assign(requests([("db", 5432)]), hostPorts: [], environment: "q/main", state: registry, locks: locks, range: range).ports
        #expect(third == [PortAssignment(service: "db", containerPort: 5432, hostPort: range.lowerBound + 4)])
        registry.environments.append(EnvironmentRecord(name: "q/main", project: nil, mainRepository: nil, worktree: "/q", owner: .worktree, ports: third))

        // 再次 up：端口不变；去掉 api、加上 cache：api 的端口释放，cache 拿新端口
        let second = try PortAllocator.assign(requests([("db", 5432), ("cache", 6379)]), hostPorts: [], environment: "p/main", state: registry, locks: locks, range: range).ports
        #expect(second.first { $0.service == "db" }?.hostPort == range.lowerBound + 2)
        #expect(second.first { $0.service == "cache" }?.hostPort == range.lowerBound + 5)
        #expect(!locks.lockedPorts.contains(range.lowerBound + 3))
    }

    /// 换 profile 再 up：没启用的服务的端口也留着，来回切都是同一个；对外只有启用的
    @Test func switchingProfilesKeepsPorts() throws {
        let files = ["compose.yaml": """
        services:
          db: {image: postgres, ports: ["5432"]}
          api: {image: alpine, ports: ["8080"], profiles: [api]}
        """]
        let range = 38430...38431 // 单独一段：allocateSkipBusyAndStayStable 刚关掉开头的端口
        let locks = PortLocks()
        var registry = NapboxState()
        func up(_ profiles: [String]) throws -> EnvironmentRecord {
            let project = try load(files, profiles: profiles)
            let ports = try PortAllocator.assign(project.portRequests, hostPorts: [], environment: "p/main", state: registry, locks: locks, range: range).ports
            let record = EnvironmentRecord(name: "p/main", project: nil, mainRepository: nil, worktree: "/p", owner: .worktree,
                                           ports: ports, definition: project)
            registry.environments = [record]
            return record
        }
        let withoutAPI = try up([])
        #expect(withoutAPI.ports.map(\.service) == ["api", "db"])
        #expect(withoutAPI.activePorts.map(\.service) == ["db"], "没启用的 api 不转发、不列出")
        let withAPI = try up(["api"])
        #expect(withAPI.ports == withoutAPI.ports)
        #expect(withAPI.activePorts == withAPI.ports)
        #expect(try up([]).ports == withoutAPI.ports)
        #expect(locks.lockedPorts == withoutAPI.ports.map(\.hostPort).sorted())
    }

    /// 新端口从上次分到的后面接着分：回收的环境放开的端口不马上分给下一个，过期的地址连上去是没人监听；
    /// 到范围末尾从头再找，跳过还登记着的
    @Test func releasedPortsAreNotReusedRightAway() throws {
        // 单独一段端口；down 只去掉登记、不放开锁（锁放开后马上再绑可能撞上内核的空当，见 range 的说明）。
        // 分配顺序只由登记表和接续位置决定，和锁无关
        let range = 38420...38423
        let locks = PortLocks()
        var registry = NapboxState()
        func up(_ name: String) throws -> PortAllocation {
            let allocation = try PortAllocator.assign(requests([("api", 3100)]), hostPorts: [], environment: name, state: registry, locks: locks, range: range)
            registry.environments.removeAll { $0.name == name }
            registry.environments.append(EnvironmentRecord(name: name, project: nil, mainRepository: nil, worktree: "/\(name)", owner: .worktree, ports: allocation.ports))
            registry.recordAllocation(allocation)
            return allocation
        }
        func down(_ name: String) { registry.environments.removeAll { $0.name == name } }
        #expect(try up("a/main").ports.map(\.hostPort) == [range.lowerBound])
        #expect(try up("b/main").ports.map(\.hostPort) == [range.lowerBound + 1])
        down("b/main")
        #expect(try up("c/main").ports.map(\.hostPort) == [range.lowerBound + 2], "b 放开的端口不马上给 c")
        let again = try up("c/main")
        #expect(again.ports.map(\.hostPort) == [range.lowerBound + 2] && again.lastNew == nil, "再次 up 沿用，不动接续位置")
        #expect(registry.lastAssignedPort == range.lowerBound + 2)
        #expect(try up("d/main").ports.map(\.hostPort) == [range.upperBound])
        #expect(try up("e/main").ports.map(\.hostPort) == [range.lowerBound + 1], "到末尾从头找，跳过 a 还登记着的，拿到 b 放开的")
    }

    /// 本机进程的端口：和服务端口从同一个序列分，不锁；被别的程序占着、别的环境登记着的跳过；
    /// 再次 up 沿用，去掉的放开，新加的接着往后分
    @Test func hostPortsAreAssignedButNotLocked() throws {
        let range = 38460...38467
        // 服务端口拿走开头那个以后，本机进程的端口第一个碰到的就是被占的 +1，再往后 +2 是别的环境登记的
        let busy = occupy(range.lowerBound + 1)
        defer { close(busy) }
        let locks = PortLocks()
        var registry = state(["other/main": []])
        registry.environments[0].hostPorts = [HostPortAssignment(name: "server", hostPort: range.lowerBound + 2)]
        func up(_ name: String, _ services: [(String, Int)], _ hostPorts: [String]) throws -> PortAllocation {
            let allocation = try PortAllocator.assign(requests(services), hostPorts: hostPorts, environment: name, state: registry, locks: locks, range: range)
            registry.environments.removeAll { $0.name == name }
            var record = EnvironmentRecord(name: name, project: nil, mainRepository: nil, worktree: "/\(name)", owner: .worktree, ports: allocation.ports)
            record.hostPorts = allocation.hostPorts
            registry.environments.append(record)
            registry.recordAllocation(allocation)
            return allocation
        }
        let first = try up("p/main", [("db", 5432)], ["server", "web"])
        #expect(first.ports.map(\.hostPort) == [range.lowerBound])
        #expect(first.hostPorts == [HostPortAssignment(name: "server", hostPort: range.lowerBound + 3), HostPortAssignment(name: "web", hostPort: range.lowerBound + 4)])
        #expect(first.lastNew == range.lowerBound + 4)
        #expect(locks.lockedPorts == [range.lowerBound], "只锁服务的端口")

        let second = try up("p/main", [("db", 5432)], ["web", "worker"])
        #expect(second.hostPorts == [HostPortAssignment(name: "web", hostPort: range.lowerBound + 4), HostPortAssignment(name: "worker", hostPort: range.lowerBound + 5)])
        #expect(locks.lockedPorts == [range.lowerBound])

        // 别的环境不会拿到 p 登记着的
        #expect(try up("q/main", [], ["server"]).hostPorts == [HostPortAssignment(name: "server", hostPort: range.lowerBound + 6)])
        #expect(registry.environment("p/main")?.allHostPorts.sorted() == [range.lowerBound, range.lowerBound + 4, range.lowerBound + 5])
    }

    /// 登记过的本机进程端口再次 up 时被占着（多半是项目自己的程序）：照样沿用，不报错、不换
    @Test func registeredHostPortInUseIsKept() throws {
        let port = 38470
        let busy = occupy(port)
        defer { close(busy) }
        var registry = state(["p/main": []])
        registry.environments[0].hostPorts = [HostPortAssignment(name: "server", hostPort: port)]
        let locks = PortLocks()
        let again = try PortAllocator.assign([], hostPorts: ["server"], environment: "p/main", state: registry, locks: locks, range: 38470...38471)
        #expect(again.hostPorts == [HostPortAssignment(name: "server", hostPort: port)])
        #expect(again.lastNew == nil)
        #expect(locks.lockedPorts.isEmpty)
    }

    /// 本机进程的端口用完：报 port_unavailable，这次新锁的服务端口放开
    @Test func hostPortsExhausted() throws {
        let locks = PortLocks()
        #expect {
            try PortAllocator.assign(requests([("a", 1)]), hostPorts: ["server"], environment: "p/main", state: NapboxState(), locks: locks, range: 38475...38475)
        } throws: { ($0 as? NapboxError)?.code == "port_unavailable" }
        #expect(locks.lockedPorts.isEmpty)
    }

    @Test func hostPortVariables() {
        #expect(HostPortVariables.name(of: HostPortAssignment(name: "e2e_web", hostPort: 41230)) == "NAPBOX_HOST_E2E_WEB")
        #expect(PortVariables.all([PortAssignment(service: "host", containerPort: 5432, hostPort: 41229)],
                                  hostPorts: [HostPortAssignment(name: "server", hostPort: 41230)])
            == ["NAPBOX_HOST_5432": "127.0.0.1:41229", "NAPBOX_HOST_SERVER": "41230"])
        for good in ["server", "e2e_web", "worker2", "a"] { #expect(HostPortVariables.isValidName(good), "\(good)") }
        for bad in ["Server", "e2e_1", "1abc", "_x", "web_", "web-api", ""] { #expect(!HostPortVariables.isValidName(bad), "\(bad)") }
        // 服务叫 host 时它的端口变量不算本机进程的
        #expect(HostPortVariables.isVariable("NAPBOX_HOST_WORKER2"))
        #expect(!HostPortVariables.isVariable("NAPBOX_HOST_5432"))
        #expect(PortReferences.isServicePort("NAPBOX_HOST_5432") && !PortReferences.isServicePort("NAPBOX_HOST_WORKER2"))
    }

    @Test func napboxdRestartRelocks() throws {
        let current = [PortAssignment(service: "db", containerPort: 5432, hostPort: range.lowerBound + 6)]
        let locks = PortLocks() // 模拟 napboxd 重启：登记还在，锁没了
        let result = try PortAllocator.assign(requests([("db", 5432)]), hostPorts: [], environment: "p/main", state: state(["p/main": current]), locks: locks, range: range).ports
        #expect(result == current)
        #expect(locks.lockedPorts == [range.lowerBound + 6])
    }

    @Test func registeredPortTakenByOtherProgram() throws {
        let busy = occupy(range.lowerBound + 7)
        defer { close(busy) }
        let locks = PortLocks()
        let current = [PortAssignment(service: "db", containerPort: 5432, hostPort: range.lowerBound + 7)]
        #expect {
            try PortAllocator.assign(requests([("db", 5432), ("api", 3100)]), hostPorts: [], environment: "p/main", state: state(["p/main": current]), locks: locks, range: range)
        } throws: { ($0 as? NapboxError)?.code == "port_unavailable" }
        #expect(locks.lockedPorts.isEmpty) // 失败时这次新锁的都放开
    }

    /// napboxd 重启时：代理这一端先关了连接，端口还在 TIME_WAIT，登记的端口也要能重新锁上
    @Test func relockAfterTimeWait() throws {
        let port = range.lowerBound + 8
        let locks = PortLocks()
        #expect(locks.lock(port))
        let listener = try #require(locks.duplicate(port))
        let client = socket(AF_INET, SOCK_STREAM, 0)
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(port).bigEndian)
        addr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let connected = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(client, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        #expect(connected == 0)
        let accepted = accept(listener, nil, nil)
        close(accepted) // 服务端先关：这一端进入 TIME_WAIT
        usleep(100_000)
        close(client)
        close(listener)
        locks.release(port)
        usleep(100_000)
        #expect(locks.lock(port))
    }

    @Test func exhausted() throws {
        let locks = PortLocks()
        #expect {
            try PortAllocator.assign(requests([("a", 1), ("b", 2)]), hostPorts: [], environment: "p/main", state: NapboxState(), locks: locks, range: 38409...38409)
        } throws: { ($0 as? NapboxError)?.code == "port_unavailable" }
        #expect(locks.lockedPorts.isEmpty)
    }
}

@Suite struct LogReaderTests {
    /// 最后 N 行：末尾有没有换行、不足 N 行、跨过 64KB 的读块边界、0 行、文件不存在
    @Test func lastLines() throws {
        try withProject(["a.log": "one\ntwo\nthree\n", "b.log": "one\ntwo\nthree", "c.log": ""]) { dir in
            func tail(_ name: String, _ n: Int) -> String {
                let url = dir.appending(path: name)
                let start = LogReader.startOffset(of: url, lastLines: n)
                return String(decoding: LogReader.read(url, from: start, upTo: LogReader.size(of: url), limit: 1 << 20) ?? Data(), as: UTF8.self)
            }
            #expect(tail("a.log", 1) == "three\n")
            #expect(tail("a.log", 2) == "two\nthree\n")
            #expect(tail("a.log", 5) == "one\ntwo\nthree\n")
            #expect(tail("b.log", 1) == "three")
            #expect(tail("b.log", 2) == "two\nthree")
            #expect(tail("a.log", 0) == "")
            #expect(tail("c.log", 3) == "")
            #expect(LogReader.startOffset(of: dir.appending(path: "none.log"), lastLines: 3) == 0)

            // 每行 100 字节，3000 行约 300KB：要往前读好几个块
            let big = dir.appending(path: "big.log")
            let lines = (0..<3000).map { String(format: "%05d", $0) + String(repeating: "x", count: 94) }
            try (lines.joined(separator: "\n") + "\n").write(to: big, atomically: true, encoding: .utf8)
            let start = LogReader.startOffset(of: big, lastLines: 1500)
            #expect(start == UInt64(1500 * 100))
            #expect(LogReader.read(big, from: start, upTo: start + 5) == Data("01500".utf8))
        }
    }
}

@Suite struct RestartTrackerTests {
    let t0 = Date(timeIntervalSince1970: 1_000_000)

    @Test func whatCountsAsCompleted() throws {
        let project = try load(["compose.yaml": """
        services:
          oneshot: {image: a}
          failing_retry: {image: a, restart: "on-failure:3"}
          retry_once: {image: a, restart: on-failure}
          always: {image: a, restart: always}
          stopped: {image: a, restart: unless-stopped}
          db: {image: a, ports: ["5432"]}
          exposed: {image: a, expose: ["80"]}
          checked: {image: a, healthcheck: {test: ["CMD", "true"]}}
          migrate: {image: a, ports: ["9"]}
          app:
            image: a
            depends_on:
              migrate: {condition: service_completed_successfully}
              oneshot: {condition: service_started}
        """])
        func completes(_ name: String, _ code: Int32 = 0) throws -> Bool {
            project.completes(try #require(project.service(name)), exitCode: code)
        }
        // 没有端口和 healthcheck 的一次性服务：退出码 0 才算（别的服务只是等它启动，不改变这一点）
        #expect(try completes("oneshot"))
        #expect(try !completes("oneshot", 1))
        // 按 restart 还要再起的不算
        #expect(try !completes("always"))
        #expect(try !completes("stopped"))
        #expect(try completes("retry_once"))
        #expect(try !completes("failing_retry", 1))
        // 有端口或 healthcheck 的是要一直提供服务的，退出码 0 也不算
        #expect(try !completes("db"))
        #expect(try !completes("exposed"))
        #expect(try !completes("checked"))
        // 除非别的服务写明要等它跑完
        #expect(try completes("migrate"))
        #expect(try !completes("migrate", 1))
    }

    @Test func hasSourceMounts() throws {
        #expect(try load(["compose.yaml": "services: {a: {image: a, volumes: [\"v:/v\"]}}\nvolumes: {v: {}}"]).hasSourceMounts == false)
        #expect(try load(["compose.yaml": "services: {a: {image: a}, b: {image: a, volumes: [\"./src:/src\"]}}"]).hasSourceMounts)
    }

    @Test func freshLaunchClearsPendingRestart() {
        var r = RestartTracker()
        r.launched(at: t0, restarting: false)
        #expect(r.serviceExited("a", policy: .always, code: 1, at: t0).delay == 0.1)
        // 等重启的时候有人 up 了：排着的那次对着旧环境，新环境的退出要能排上新的
        r.launched(at: t0, restarting: false)
        #expect(r.serviceExited("a", policy: .always, code: 1, at: t0) == .init(action: .restarting, delay: 0.1))
    }

    @Test func policies() {
        var r = RestartTracker()
        r.launched(at: t0, restarting: false)
        #expect(r.serviceExited("a", policy: .no, code: 1, at: t0).action == .none)
        #expect(r.serviceExited("a", policy: .onFailure(maxRetries: nil), code: 0, at: t0).action == .none)
        #expect(r.serviceExited("a", policy: .always, code: 0, at: t0) == .init(action: .restarting, delay: 0.1))
        // 已经排上重启：同一批退出的别的服务不再排
        #expect(r.serviceExited("b", policy: .unlessStopped, code: 0, at: t0) == .init(action: .restarting, delay: nil))
        #expect(r.restarts("b") == 0)
    }

    @Test func backoffDoublesCapsAndResetsAfterStableRun() {
        var r = RestartTracker()
        r.launched(at: t0, restarting: false)
        var delays: [Double] = []
        for i in 0..<12 {
            let now = t0.addingTimeInterval(Double(i))
            r.launched(at: now, restarting: true)
            delays.append(r.serviceExited("a", policy: .always, code: 1, at: now.addingTimeInterval(1)).delay ?? -1)
            r.restartStarted()
        }
        #expect(delays == [0.1, 0.2, 0.4, 0.8, 1.6, 3.2, 6.4, 12.8, 25.6, 51.2, 60, 60])
        // 稳定跑了 10 秒以上：从 0.1 秒重新算
        r.launched(at: t0, restarting: true)
        #expect(r.serviceExited("a", policy: .always, code: 1, at: t0.addingTimeInterval(10)).delay == 0.1)
    }

    @Test func onFailureLimitAndFreshLaunchResets() {
        var r = RestartTracker()
        r.launched(at: t0, restarting: false)
        var actions: [ServiceExit.Restart] = []
        for _ in 0..<3 {
            actions.append(r.serviceExited("crash", policy: .onFailure(maxRetries: 2), code: 3, at: t0).action)
            r.restartStarted()
            r.launched(at: t0, restarting: true)
        }
        #expect(actions == [.restarting, .restarting, .gaveUp])
        // up、唤醒、reset：次数和退避重新算
        r.launched(at: t0, restarting: false)
        #expect(r.serviceExited("crash", policy: .onFailure(maxRetries: 2), code: 3, at: t0) == .init(action: .restarting, delay: 0.1))
    }
}

@Suite struct CallerEnvironmentTests {
    private func code(_ body: () throws -> Void) -> String? {
        do {
            try body()
            return nil
        } catch {
            return (error as? NapboxError)?.code
        }
    }

    @Test func validNames() throws {
        try CallerEnvironment.validate(name: "codeos/goal-12-work", owner: "codeos")
        try CallerEnvironment.validate(name: "a1/b_c.d", owner: "a.b-c_d")
    }

    @Test(arguments: ["codeos", "codeos/", "/goal", "a/b/c", "Codeos/goal", "codeos/Goal", "codeos/-goal", "code os/goal", "搭档/goal",
                      "codeos/" + String(repeating: "a", count: 100)])
    func invalidNames(name: String) {
        #expect(code { try CallerEnvironment.validate(name: name, owner: "codeos") } == "bad_request")
    }

    @Test(arguments: ["", "Codeos", "code/os", "-codeos", String(repeating: "a", count: 51)])
    func invalidOwners(owner: String) {
        #expect(code { try CallerEnvironment.validate(name: "codeos/goal", owner: owner) } == "bad_request")
    }

    @Test func directory() throws {
        #expect(code { _ = try CallerEnvironment.directory("relative/path") } == "bad_request")
        #expect(code { _ = try CallerEnvironment.directory("/nonexistent/napbox-test") } == "bad_request")
        try withProject(["copy/repo/README": "x"]) { dir in
            let file = dir.appending(path: "copy/repo/README").path
            #expect(code { _ = try CallerEnvironment.directory(file) } == "bad_request")
            let link = dir.appending(path: "link")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: dir.appending(path: "copy/repo"))
            let real = dir.appending(path: "copy/repo").resolvingSymlinksInPath().path
            #expect(try CallerEnvironment.directory(link.path).path == real)
        }
    }

    /// 调用方的环境不占 worktree 的名字规则：worktree 环境算名字时要避开调用方已经用了的名字
    @Test func worktreeNameAvoidsCallerName() {
        var state = NapboxState()
        state.environments = [EnvironmentRecord(name: "repo/main", project: nil, mainRepository: nil, worktree: "/copy/repo", owner: .caller(id: "codeos"))]
        let location = WorktreeLocation(mainRepository: URL(fileURLWithPath: "/w/repo"), worktree: URL(fileURLWithPath: "/w/repo"))
        #expect(state.environmentName(for: location) == "repo/main-2")
    }
}

@Suite struct EnvironmentTargetTests {
    private func decode(_ json: String) throws -> EnvironmentTarget {
        try Wire.decoder.decode(EnvironmentTarget.self, from: Data(json.utf8))
    }

    @Test func decodes() throws {
        #expect(try decode(#"{"cwd":"/w"}"#) == .directory("/w"))
        #expect(try decode(#"{"cwd":"/w","temp":"t1"}"#) == .directory("/w", temporary: "t1"))
        #expect(try decode(#"{"name":"codeos/a","owner":"codeos"}"#) == .named("codeos/a", owner: "codeos"))
    }

    @Test(arguments: [#"{}"#, #"{"name":"a/b"}"#, #"{"owner":"a"}"#, #"{"cwd":"/w","name":"a/b","owner":"a"}"#,
                      #"{"temp":"t1"}"#, #"{"name":"a/b","owner":"a","temp":"t1"}"#])
    func rejectsMixed(json: String) {
        #expect(throws: (any Error).self) { try decode(json) }
    }

    @Test func roundTrips() throws {
        for target in [EnvironmentTarget.directory("/w"), .directory("/w", temporary: "t1"), .named("a/b", owner: "a")] {
            let json = String(decoding: try Wire.encoder.encode(target), as: UTF8.self)
            #expect(try decode(json) == target)
        }
    }
}

@Suite struct DefinitionDigestTests {
    /// 服务一样摘要就一样，变量值变了摘要也变（运行记录靠它说明用的是哪份定义）
    @Test func changesWithDefinition() throws {
        func project(_ value: String) throws -> ComposeProject {
            try withProject(["compose.yaml": "services:\n  a:\n    image: alpine:3.20\n    environment: {X: \(value)}\n"]) { dir in
                try ComposeLoader.load(ComposeInput(files: [dir.appending(path: "compose.yaml")], callerEnvironment: [:]))
            }
        }
        let one = try project("1")
        #expect(one.digest == (try project("1")).digest)
        #expect(one.digest != (try project("2")).digest)
        #expect(one.digest.hasPrefix("sha256:"))
    }
}
