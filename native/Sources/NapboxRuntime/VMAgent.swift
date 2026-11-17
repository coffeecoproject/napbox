// 和虚拟机里的 vminitd 来往：napboxd 自己要它做的事（写内核设置、对时、传文件、发信号）都从这里走。
import Containerization
import NapboxProtocol

enum VMAgent {
    /// 连上 vminitd，做完 body，关掉连接。
    ///
    /// 不跟着调用方取消：调用方被取消时（比如 napbox exec 的调用方断开），请求会在 gRPC 的连接还没跑起来时就以取消失败返回，
    /// 这时关连接，连接没跑过就被释放，NIO 的检查直接让 napboxd 退出（"Deinited NIOAsyncWriter without calling finish()"，
    /// 2026-11-16 CrocWork 页面测试时碰到，崩在写内核设置失败后的关连接）。这是 Containerization 的 Vminitd 的问题，
    /// 这里改不了它，所以连上、请求、关掉放在不随调用方取消的任务里做完。这些往来都很短（写内核设置约 6 毫秒），
    /// 传文件长一些，做完比做一半留着好。
    static func session<T: Sendable>(
        _ pod: LinuxPod, _ body: @escaping @Sendable (any VirtualMachineInstance, Vminitd) async throws -> T
    ) async throws -> T {
        try await Task.detached {
            try await pod.withVirtualMachineInstance { vm in
                guard let vminitd = try await vm.dialAgent() as? Vminitd else {
                    throw NapboxError(.internalError, "虚拟机里的代理不是 vminitd")
                }
                let result: T
                do {
                    result = try await body(vm, vminitd)
                } catch {
                    try? await vminitd.close()
                    throw error
                }
                try? await vminitd.close()
                return result
            }
        }.value
    }
}
