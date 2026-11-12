// compose 的变量替换：$VAR、${VAR}、${VAR:-默认}、${VAR-默认}、${VAR:?说明}、${VAR?说明}、${VAR:+替代}、${VAR+替代}，
// `$$` 表示字面的 `$`；默认值里可以再嵌套变量。
import Foundation

struct InterpolationError: Error {
    var message: String
}

final class Interpolator {
    private let lookup: (String) -> String?
    /// 用到了但没设置、也没有默认值的变量（compose 会提示并当作空字符串）。
    private(set) var missing: [String] = []

    init(lookup: @escaping (String) -> String?) {
        self.lookup = lookup
    }

    func interpolate(_ text: String) throws(InterpolationError) -> String {
        var scanner = Array(text.unicodeScalars)[...]
        return try expand(&scanner)
    }

    private func expand(_ s: inout ArraySlice<Unicode.Scalar>) throws(InterpolationError) -> String {
        var out = String.UnicodeScalarView()
        while let c = s.first {
            s.removeFirst()
            guard c == "$" else { out.append(c); continue }
            guard let next = s.first else { out.append(c); continue }
            if next == "$" {
                s.removeFirst()
                out.append("$")
            } else if next == "{" {
                s.removeFirst()
                out.append(contentsOf: try braced(&s).unicodeScalars)
            } else if Self.isNameStart(next) {
                let name = Self.takeName(&s)
                out.append(contentsOf: value(name).unicodeScalars)
            } else {
                out.append(c)
            }
        }
        return String(out)
    }

    private func braced(_ s: inout ArraySlice<Unicode.Scalar>) throws(InterpolationError) -> String {
        guard let first = s.first, Self.isNameStart(first) else {
            throw InterpolationError(message: "`${` 后面要跟变量名")
        }
        let name = Self.takeName(&s)
        let raw = lookup(name)
        var op = ""
        if s.first == ":" { op.append(":"); s.removeFirst() }
        if let c = s.first, c == "-" || c == "?" || c == "+" { op.unicodeScalars.append(c); s.removeFirst() }
        if op == ":" { throw InterpolationError(message: "`${\(name):` 后面要跟 `-`、`?` 或 `+`") }
        // 默认值、说明、替代值先只截出原文，用到时才求值：用不到的部分里的变量不算"没设置"，也不报错
        var operandText = try Self.takeOperand(&s, name: name)
        if op.isEmpty, !operandText.isEmpty {
            throw InterpolationError(message: "`${\(name)` 后面只能跟 `}`、`:-`、`-`、`:?`、`?`、`:+`、`+`")
        }
        func operand() throws(InterpolationError) -> String { try expand(&operandText) }
        let isSet = raw != nil
        let isNonEmpty = !(raw ?? "").isEmpty
        switch op {
        case "": return value(name)
        case ":-": return isNonEmpty ? raw! : try operand()
        case "-": return isSet ? raw! : try operand()
        case ":?", "?":
            if op == ":?" ? isNonEmpty : isSet { return raw! }
            let note = try operand()
            throw InterpolationError(message: "变量 \(name) 必须设置\(note.isEmpty ? "" : "：\(note)")")
        case ":+": return isNonEmpty ? try operand() : ""
        default: return isSet ? try operand() : "" // "+"
        }
    }

    /// 截到和 `${` 配对的 `}` 为止（嵌套的 `${...}` 和 `$$` 原样保留），并吃掉这个 `}`。
    private static func takeOperand(_ s: inout ArraySlice<Unicode.Scalar>, name: String) throws(InterpolationError) -> ArraySlice<Unicode.Scalar> {
        var out: [Unicode.Scalar] = []
        var depth = 0
        while let c = s.first {
            s.removeFirst()
            if c == "$", let next = s.first, next == "$" || next == "{" {
                s.removeFirst()
                out += [c, next]
                if next == "{" { depth += 1 }
                continue
            }
            if c == "}" {
                if depth == 0 { return out[...] }
                depth -= 1
            }
            out.append(c)
        }
        throw InterpolationError(message: "`${\(name)` 缺少 `}`")
    }

    private func value(_ name: String) -> String {
        if let v = lookup(name) { return v }
        if !missing.contains(name) { missing.append(name) }
        return ""
    }

    private static func isNameStart(_ c: Unicode.Scalar) -> Bool {
        c == "_" || ("A"..."Z").contains(c) || ("a"..."z").contains(c)
    }

    private static func takeName(_ s: inout ArraySlice<Unicode.Scalar>) -> String {
        var name = String.UnicodeScalarView()
        while let c = s.first, isNameStart(c) || ("0"..."9").contains(c) {
            name.append(c)
            s.removeFirst()
        }
        return String(name)
    }
}
