import Foundation
import Testing
@testable import NapboxCore

/// 用本机真实项目的 compose 核对支持范围。只读，不改项目文件。
/// 只在设置了 NAPBOX_COMPOSE_SAMPLES 时运行，值是一个列表文件，每行：
///   文件1[,文件2...] [| KEY=VALUE ...]
/// 输出每组的解析结果；期望写在列表文件里：行尾 `=> ok` 表示应能解析，`=> 问题片段` 表示应报出包含该片段的问题。
@Suite(.enabled(if: ProcessInfo.processInfo.environment["NAPBOX_COMPOSE_SAMPLES"] != nil))
struct RealComposeReport {
    @Test func samples() throws {
        let list = try String(contentsOfFile: ProcessInfo.processInfo.environment["NAPBOX_COMPOSE_SAMPLES"]!, encoding: .utf8)
        for raw in list.split(separator: "\n") where !raw.hasPrefix("#") && !raw.trimmingCharacters(in: .whitespaces).isEmpty {
            let (spec, expectation) = raw.split(separator: "=>", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }.pair
            let parts = spec.split(separator: "|", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            let files = parts[0].split(separator: ",").map { URL(fileURLWithPath: String($0)) }
            var env = ProcessInfo.processInfo.environment
            if parts.count > 1 {
                for kv in parts[1].split(separator: " ") {
                    let p = kv.split(separator: "=", maxSplits: 1)
                    env[String(p[0])] = p.count > 1 ? String(p[1]) : ""
                }
            }
            let label = files.map { $0.path.replacingOccurrences(of: NSHomeDirectory() + "/Developer/", with: "") }.joined(separator: " + ")
            do {
                let p = try ComposeLoader.load(ComposeInput(files: files, callerEnvironment: env))
                print("[ok] \(label)：\(p.services.map { "\($0.name)\($0.ports.isEmpty ? "" : "\($0.ports)")" }.joined(separator: " "))\(p.unsetVariables.isEmpty ? "" : "；没设置的变量 \(p.unsetVariables)")")
                if let expectation { #expect(expectation == "ok", "\(label) 应报出：\(expectation)") }
            } catch {
                print("[问题] \(label)\n" + error.issues.map { "    \($0)" }.joined(separator: "\n"))
                if let expectation {
                    #expect(expectation != "ok" && error.issues.contains { $0.description.contains(expectation) }, "\(label)：期望 \(expectation)")
                }
            }
        }
    }
}

private extension Array where Element == String {
    var pair: (String, String?) { (self[0], count > 1 ? self[1] : nil) }
}
