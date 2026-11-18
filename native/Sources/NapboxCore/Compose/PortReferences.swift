// compose 里引用这个环境自己的端口变量：`${NAPBOX_API_3100}`，起服务时换成宿主机上连它的地址（127.0.0.1:41217）；
// `${NAPBOX_API_3100_SITE}` 换成给浏览器用的地址（feat-x.crocwork.localhost:41217），`${NAPBOX_HOSTNAME}` 换成主机名。
// 给需要知道自己对外地址的服务用，比如服务端生成给浏览器打开的链接、允许的来源。
// 读 compose 时还没分配端口，先换成占位，起服务时再换成地址；端口对同一个环境固定不变，所以定义不跟着端口变。
// 只能用在 environment 和 env_file 里，引用的要是启用的服务在 ports 里写的端口。
// 本机程序的端口变量（NAPBOX_HOST_<名字>）也先换成占位、不从调用方环境取，校验时报错：环境里访问不到本机。
import Foundation

public enum PortReferences {
    /// 占位两头的标记。compose 和 env_file 的值里不会出现这个控制字符
    static let mark: Character = "\u{1}"

    /// 变量名是不是 napbox 给的变量：NAPBOX_<服务>_<容器端口>、NAPBOX_<服务>_<容器端口>_SITE、NAPBOX_HOSTNAME，
    /// 或本机程序的 NAPBOX_HOST_<名字>。调用方环境里同名的变量（eval "$(napbox env)" 带进来的）不用，不然定义会跟着调用方的环境变
    static func isReference(_ name: String) -> Bool {
        isServicePort(name) || isSite(name) || name == PortVariables.hostname || HostPortVariables.isVariable(name)
    }

    /// NAPBOX_<服务>_<容器端口>_SITE 的样子
    static func isSite(_ name: String) -> Bool {
        name.hasSuffix(PortVariables.siteSuffix) && isServicePort(String(name.dropLast(PortVariables.siteSuffix.count)))
    }

    /// NAPBOX_<服务>_<容器端口> 的样子
    static func isServicePort(_ name: String) -> Bool {
        guard name.hasPrefix("NAPBOX_"), let last = name.split(separator: "_").last else { return false }
        return name.count > "NAPBOX_".count + last.count + 1 && last.allSatisfy(\.isNumber)
    }

    static func placeholder(_ name: String) -> String { "\(mark)\(name)\(mark)" }

    /// 值里引用了哪些端口变量
    static func names(in text: String) -> [String] {
        let parts = text.split(separator: mark, omittingEmptySubsequences: false)
        return stride(from: 1, to: parts.count - 1, by: 2).map { String(parts[$0]) }
    }

    static func contains(_ text: String) -> Bool { text.contains(mark) }

    /// 起服务时把占位换成地址。variables 是 PortVariables.variables 的结果；校验过的定义里引用的都在
    public static func resolve(_ text: String, _ variables: [String: String]) -> String {
        guard contains(text) else { return text }
        let parts = text.split(separator: mark, omittingEmptySubsequences: false)
        return parts.enumerated().map { i, part in i % 2 == 1 ? variables[String(part)] ?? "" : String(part) }.joined()
    }
}
