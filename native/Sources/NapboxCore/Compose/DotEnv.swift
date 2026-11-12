// .env 和 env_file 的格式：KEY=VALUE，可以带 `export `；`#` 开头是注释；单引号原样，双引号支持 \n 等转义和变量替换，
// 不带引号的值去掉行尾 ` #注释` 后也做变量替换。只写 KEY（没有 `=`）表示取调用方环境里的同名变量。
import Foundation

enum DotEnv {
    /// 返回按文件顺序的键值。lookup 用来替换值里的变量，文件里前面定义的变量也能用。
    static func parse(_ text: String, file: String, lookup: @escaping (String) -> String?) throws(ComposeError) -> [(String, String)] {
        var result: [(String, String)] = []
        var defined: [String: String] = [:]
        let interpolator = Interpolator { defined[$0] ?? lookup($0) }
        var issues: [ComposeIssue] = []
        var chars = Array(text)[...]
        var lineNumber = 1

        func takeLine() -> String {
            var line = ""
            while let c = chars.first {
                chars.removeFirst()
                if c == "\n" || c == "\r\n" { lineNumber += 1; break }
                line.append(c)
            }
            return line
        }

        while !chars.isEmpty {
            let startLine = lineNumber
            var line = takeLine().trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line.hasPrefix("export ") { line = String(line.dropFirst(7)).trimmingCharacters(in: .whitespaces) }
            guard let eq = line.firstIndex(of: "=") else {
                if let v = lookup(line) { result.append((line, v)); defined[line] = v }
                continue
            }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty, key.allSatisfy({ $0 == "_" || $0 == "." || $0 == "-" || $0.isLetter || $0.isNumber }) else {
                issues.append(.invalid("\(file) 第 \(startLine) 行：变量名不对：\(key)"))
                continue
            }
            var rest = String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            var value: String
            if let quote = rest.first, quote == "'" || quote == "\"" {
                // 引号里的值可以跨行
                rest.removeFirst()
                var body = ""
                var closed = false
                while true {
                    var escaped = false
                    var consumed = 0
                    for c in rest {
                        consumed += 1
                        if quote == "\"", escaped {
                            switch c {
                            case "n": body.append("\n")
                            case "t": body.append("\t")
                            case "r": body.append("\r")
                            default: body.append(c)
                            }
                            escaped = false
                        } else if quote == "\"", c == "\\" {
                            escaped = true
                        } else if c == quote {
                            closed = true
                            break
                        } else {
                            body.append(c)
                        }
                    }
                    if closed {
                        let tail = rest.dropFirst(consumed).trimmingCharacters(in: .whitespaces)
                        if !tail.isEmpty, !tail.hasPrefix("#") {
                            issues.append(.invalid("\(file) 第 \(startLine) 行：引号后面还有内容：\(tail)"))
                        }
                        break
                    }
                    if chars.isEmpty { break }
                    body.append("\n")
                    rest = takeLine()
                }
                if !closed {
                    issues.append(.invalid("\(file) 第 \(startLine) 行：引号没有闭合"))
                    continue
                }
                value = body
                if quote == "\"" {
                    do { value = try interpolator.interpolate(body) } catch {
                        issues.append(.invalid("\(file) 第 \(startLine) 行：\(error.message)")); continue
                    }
                }
            } else {
                if let hash = rest.range(of: " #") { rest = String(rest[..<hash.lowerBound]) }
                do { value = try interpolator.interpolate(rest.trimmingCharacters(in: .whitespaces)) } catch {
                    issues.append(.invalid("\(file) 第 \(startLine) 行：\(error.message)")); continue
                }
            }
            result.append((key, value))
            defined[key] = value
        }
        if !issues.isEmpty { throw ComposeError(issues) }
        return result
    }
}
