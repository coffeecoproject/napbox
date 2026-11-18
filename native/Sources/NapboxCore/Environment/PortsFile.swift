// worktree 里的 .napbox/ports.json：给不走 MCP 的工具读端口。
// 加进 .git/info/exclude，不改项目的 .gitignore。
import Foundation
import NapboxProtocol

public enum PortsFile {
    /// ports.json 的内容，格式由这里定，不跟着协议类型变
    struct Content: Codable, Equatable {
        struct Port: Codable, Equatable {
            var service: String
            var containerPort: Int
            var hostPort: Int
            var variable: String
        }

        struct HostPort: Codable, Equatable {
            var name: String
            var hostPort: Int
            var variable: String
        }

        var environment: String
        var hostname: String
        var ports: [Port]
        var hostPorts: [HostPort]
        var variables: [String: String]

        init(environment: String, hostname: String, assignments: [PortAssignment], hostAssignments: [HostPortAssignment]) {
            self.environment = environment
            self.hostname = hostname
            ports = assignments.map { Port(service: $0.service, containerPort: $0.containerPort, hostPort: $0.hostPort, variable: PortVariables.name(of: $0)) }
            hostPorts = hostAssignments.map { HostPort(name: $0.name, hostPort: $0.hostPort, variable: HostPortVariables.name(of: $0)) }
            variables = PortVariables.all(assignments, hostname: hostname, hostPorts: hostAssignments)
        }
    }

    public static func write(environment: String, hostname: String, ports: [PortAssignment], hostPorts: [HostPortAssignment], worktree: URL) throws(NapboxError) {
        let dir = worktree.appending(path: ".napbox")
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let data = try DiskJSON.encoder.encode(Content(environment: environment, hostname: hostname, assignments: ports, hostAssignments: hostPorts))
            try data.write(to: dir.appending(path: "ports.json"), options: .atomic)
        } catch {
            throw NapboxError(.internalError, "写不了 \(dir.path)/ports.json：\(error.localizedDescription)")
        }
        try exclude(worktree: worktree)
    }

    /// 在这个 worktree 用的 info/exclude 里加一行 `.napbox/`（已经有就不加）。
    static func exclude(worktree: URL) throws(NapboxError) {
        let path: String
        do {
            path = try Git.run(["-C", worktree.path, "rev-parse", "--path-format=absolute", "--git-path", "info/exclude"])
        } catch {
            throw NapboxError(.internalError, "找不到 \(worktree.path) 的 .git/info/exclude：\(error.message)")
        }
        let url = URL(fileURLWithPath: path)
        let existing = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        let line = ".napbox/"
        if existing.split(separator: "\n").contains(where: { $0.trimmingCharacters(in: .whitespaces) == line }) { return }
        let text = existing + (existing.isEmpty || existing.hasSuffix("\n") ? "" : "\n") + line + "\n"
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            throw NapboxError(.internalError, "写不了 \(url.path)：\(error.localizedDescription)")
        }
    }
}
