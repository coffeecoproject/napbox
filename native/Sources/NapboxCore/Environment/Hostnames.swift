// 环境给浏览器用的主机名：`feat-x.crocwork.localhost`。
// 浏览器按主机名存 cookie，不看端口：各环境都用 127.0.0.1 时，同一个浏览器里开着几个环境，登录会互相覆盖。
// 每个环境一个主机名就分开了。*.localhost 不用配置，系统和浏览器都解析到本机（::1 和 127.0.0.1，napboxd 两边都监听）。
// 主机名登记在环境里，同一个环境一直不变，down 之后才放开。
import Foundation

public enum Hostnames {
    static let suffix = "localhost"
    /// 一个标签最长 63 个字符
    static let labelLimit = 63

    /// 按环境名拼的主机名，还没去重：各段倒过来，每段转成一个标签。
    /// `crocwork/feat-x` → `feat-x.crocwork.localhost`，临时环境 `crocwork/feat-x/e2e-1` → `e2e-1.feat-x.crocwork.localhost`，
    /// 调用方持有的 `codeos/goal-12` → `goal-12.codeos.localhost`
    static func labels(for name: String) -> [String] {
        name.split(separator: "/").reversed().map(label)
    }

    /// 一段环境名转成一个标签：小写字母和数字留着，别的字符（_ . 空格、中文）换成 -，连着的 - 并成一个，去掉头尾的 -。
    /// 什么都不剩时（整段是中文）用这段名字的短哈希
    static func label(_ segment: Substring) -> String {
        var out = ""
        for c in segment.lowercased() {
            if c.isASCII, c.isLetter || c.isNumber { out.append(c) }
            else if !out.isEmpty, out.last != "-" { out.append("-") }
        }
        out = String(trimmed(out.prefix(labelLimit)))
        return out.isEmpty ? "x" + EnvironmentRecord.id(of: String(segment)).prefix(8) : out
    }

    private static func trimmed(_ s: Substring) -> Substring {
        var s = s
        while s.last == "-" { s = s.dropLast() }
        return s
    }

    static func join(_ labels: [String]) -> String { (labels + [suffix]).joined(separator: ".") }
}

extension NapboxState {
    /// 新环境的主机名，和已登记的都不同：转成标签后可能撞（feat_x 和 feat-x、中文名的哈希），撞了在第一个标签后面加 -2、-3
    public func newHostname(for name: String) -> String {
        let taken = Set(environments.compactMap(\.hostname))
        var labels = Hostnames.labels(for: name)
        let first = labels[0]
        var n = 1
        while taken.contains(Hostnames.join(labels)) {
            n += 1
            let tail = "-\(n)"
            labels[0] = String(first.prefix(Hostnames.labelLimit - tail.count)) + tail
        }
        return Hostnames.join(labels)
    }

    /// 给还没有主机名的环境补上（加主机名之前的状态文件里没有）。有补的返回 true
    mutating func assignMissingHostnames() -> Bool {
        var changed = false
        for i in environments.indices where environments[i].hostname == nil {
            environments[i].hostname = newHostname(for: environments[i].name)
            changed = true
        }
        return changed
    }
}
