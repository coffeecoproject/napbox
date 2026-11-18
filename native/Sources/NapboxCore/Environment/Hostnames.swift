// 环境给浏览器用的主机名：`feat-x--crocwork.localhost`。
// 浏览器按主机名存 cookie，不看端口：各环境都用 127.0.0.1 时，同一个浏览器里开着几个环境，登录会互相覆盖。
// 每个环境一个主机名就分开了。*.localhost 不用配置，系统和浏览器都解析到本机（::1 和 127.0.0.1，napboxd 两边都监听）。
// localhost 下面只有一级：环境之间没有父域、子域关系，应用给 cookie 设了 Domain=当前主机名也带不到别的环境。
// 主机名登记在环境里，同一个环境一直不变，down 之后才放开。
import Foundation

public enum Hostnames {
    static let suffix = ".localhost"
    /// 一个标签最长 63 个字符
    static let labelLimit = 63
    /// 标签里各段之间用 --：一段里连着的 - 已经并成一个，-- 只会是分隔
    static let separator = "--"

    /// 新环境的主机名，和 registered（环境名 → 已登记的主机名）里的都不同。
    /// 开发环境、调用方持有的环境：环境名各段倒过来接成一个标签，`crocwork/feat-x` → `feat-x--crocwork`，`codeos/goal-12` → `goal-12--codeos`。
    /// 临时环境（temporary 是它那一段）：接在所属开发环境实际分到的主机名前面，`e2e-1--feat-x--crocwork`，开发环境撞名改过的也跟着它；
    /// 开发环境还没登记时按它的名字现算。
    /// 转成标签后可能撞（feat_x 和 feat-x、中文名的哈希），撞了在末尾加 -2、-3
    static func make(name: String, temporary: String?, registered: [String: String]) -> String {
        let label: String
        if let temporary {
            let parentName = String(name.dropLast(temporary.count + 1))
            let parent = registered[parentName] ?? make(name: parentName, temporary: nil, registered: registered)
            label = Self.label(Substring(temporary)) + separator + parent.dropLast(suffix.count)
        } else {
            label = name.split(separator: "/").reversed().map(Self.label).joined(separator: separator)
        }
        let taken = Set(registered.values)
        let base = fitted(label, reserving: 0)
        var candidate = base
        var n = 1
        while taken.contains(candidate + suffix) {
            n += 1
            let tail = "-\(n)"
            candidate = fitted(label, reserving: tail.count) + tail
        }
        return candidate + suffix
    }

    /// 一段环境名转成标签里的一段：小写字母和数字留着，别的字符（_ . 空格、中文）换成 -，连着的 - 并成一个，去掉头尾的 -。
    /// 什么都不剩时（整段是中文）用这段名字的短哈希
    static func label(_ segment: Substring) -> String {
        var out = ""
        for c in segment.lowercased() {
            if c.isASCII, c.isLetter || c.isNumber { out.append(c) }
            else if !out.isEmpty, out.last != "-" { out.append("-") }
        }
        out = String(trimmed(Substring(out)))
        return out.isEmpty ? "x" + EnvironmentRecord.id(of: String(segment)).prefix(8) : out
    }

    /// 截到留出 reserving 个字符后放得下，去掉尾巴上的 -。xn-- 开头的标签浏览器当国际化域名解码，解不出来就打不开，前面加个 x
    private static func fitted(_ label: String, reserving: Int) -> String {
        let safe = label.hasPrefix("xn--") ? "x" + label : label
        return String(trimmed(safe.prefix(labelLimit - reserving)))
    }

    private static func trimmed(_ s: Substring) -> Substring {
        var s = s
        while s.last == "-" { s = s.dropLast() }
        return s
    }
}

extension NapboxState {
    /// 新环境的主机名（Hostnames.make），和已登记的都不同
    public func newHostname(for name: String, temporary: String?) -> String {
        Hostnames.make(name: name, temporary: temporary, registered: registeredHostnames)
    }

    var registeredHostnames: [String: String] {
        Dictionary(uniqueKeysWithValues: environments.map { ($0.name, $0.hostname) })
    }
}
