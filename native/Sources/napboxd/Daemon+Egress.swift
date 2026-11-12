// 出网模式切换、宿主机地址变了以后重新加规则。
import Foundation
import NIOCore
import NapboxCore
import NapboxProtocol
import NapboxRuntime

extension Daemon {
    // MARK: - 出网模式

    /// 切换出网模式：在运行的马上换规则（一次换完，换失败时规则保持原样、登记不改），休眠的只改登记，下次唤醒生效。
    func egress(_ params: EgressParams) async throws(NapboxError) -> EnvironmentInfo {
        let record = try await record(for: params.target)
        return try await serialized(record.name) { () throws(NapboxError) in
            try await self.setEgress(record.name, params.mode)
        }
    }

    func setEgress(_ name: String, _ mode: EgressMode) async throws(NapboxError) -> EnvironmentInfo {
        if let env = running[name] { try await env.applyEgress(mode) }
        let record = try store.update { (state: inout NapboxState) throws(NapboxError) -> EnvironmentRecord in
            guard let i = state.environments.firstIndex(where: { $0.name == name }) else {
                throw NapboxError(.environmentNotFound, "环境 \(name) 没有登记")
            }
            state.environments[i].egress = mode
            return state.environments[i]
        }
        return info(record)
    }

    /// 宿主机的地址变了：open 模式的环境按新地址重新加规则。加不上就让它休眠（临时环境是销毁），下次唤醒时重新加，
    /// 不让它在漏掉宿主机地址的规则下继续运行。正在 up、唤醒的环境（还不在 running 里）也要排上：
    /// 它们可能在地址变之前就加好了规则。各环境分开排队，一个环境的 up 等很久不耽误别的环境。
    func hostAddressesChanged() {
        for name in Set(queues.keys).union(running.keys) {
            Task { await self.refreshHostAddresses(name) }
        }
    }

    func refreshHostAddresses(_ name: String) async {
        try? await serialized(name) { () throws(NapboxError) in
            guard let env = await self.runningEnvironment(name) else { return } // 在休眠，唤醒时会按当时的地址加
            do throws(NapboxError) {
                try await env.refreshHostAddresses()
            } catch {
                print("环境 \(name) 按宿主机的新地址重新加出网规则失败，先休眠：\(error.message)")
                await self.sleepOrDestroy(name, .hostAddress)
            }
        }
    }

    func runningEnvironment(_ name: String) -> RunningEnvironment? { running[name] }
    func environmentRecord(_ name: String) -> EnvironmentRecord? { store.state.environment(name) }
}
