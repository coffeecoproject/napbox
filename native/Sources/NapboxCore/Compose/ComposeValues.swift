// compose 字段里常见的值：时长（Go 的写法，如 1m30s）、大小（如 512m、1g）、按 shell 规则拆开的命令。
import Foundation

enum ComposeValues {
    /// "1m30s"、"500ms"、"1.5s"；纯数字按秒。
    static func seconds(_ text: String) -> Double? {
        if let n = Double(text) { return n }
        let units: [(String, Double)] = [("ns", 1e-9), ("us", 1e-6), ("µs", 1e-6), ("ms", 1e-3), ("s", 1), ("m", 60), ("h", 3600)]
        var rest = Substring(text)
        var total = 0.0
        guard !rest.isEmpty else { return nil }
        while !rest.isEmpty {
            let number = rest.prefix { $0.isNumber || $0 == "." }
            guard let n = Double(number) else { return nil }
            rest = rest.dropFirst(number.count)
            guard let unit = units.first(where: { rest.hasPrefix($0.0) && !(($0.0 == "m") && rest.hasPrefix("ms")) }) else { return nil }
            rest = rest.dropFirst(unit.0.count)
            total += n * unit.1
        }
        return total
    }

    /// "512m"、"1g"、"1gb"、"64M"、纯数字（字节）。按 1024 进位，和 compose 一致。
    static func bytes(_ text: String) -> UInt64? {
        let lower = text.lowercased().trimmingCharacters(in: .whitespaces)
        if let n = UInt64(lower) { return n }
        var body = Substring(lower)
        if body.hasSuffix("b") { body = body.dropLast() }
        let multipliers: [Character: Double] = ["k": 1024, "m": 1024 * 1024, "g": 1024 * 1024 * 1024, "t": 1024 * 1024 * 1024 * 1024]
        if let unit = body.last, let m = multipliers[unit], let n = Double(body.dropLast()), n >= 0 {
            return UInt64(n * m)
        }
        if let n = UInt64(body) { return n }
        return nil
    }

    /// 字符串写的 command / entrypoint 按 shell 规则拆开（compose 也是这样），不经过 shell 执行。
    static func shellSplit(_ text: String) -> [String]? {
        var words: [String] = []
        var current = ""
        var inWord = false
        var quote: Character?
        var escaped = false
        for c in text {
            if escaped {
                current.append(c); escaped = false; inWord = true; continue
            }
            if let q = quote {
                if c == q { quote = nil }
                else if c == "\\", q == "\"" { escaped = true }
                else { current.append(c) }
                continue
            }
            switch c {
            case "\\": escaped = true
            case "'", "\"": quote = c; inWord = true
            case " ", "\t", "\n":
                if inWord { words.append(current); current = ""; inWord = false }
            default: current.append(c); inWord = true
            }
        }
        if quote != nil || escaped { return nil }
        if inWord { words.append(current) }
        return words
    }
}
