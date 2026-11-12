// 虚拟机开机后马上把它的时钟对到宿主机（DESIGN.md 第 2 节「虚拟机时钟」）。
import Containerization
import Foundation
import NapboxProtocol

enum GuestClock {
    /// Containerization 的 TimeSyncer 开机后先等 30 秒才第一次对时，在那之前虚拟机的时钟和宿主机差几毫秒到一百多毫秒
    /// （2026-11-11 实测快 9 毫秒、慢 112 毫秒）；之后每 30 秒对一次，差在 2 毫秒以内。
    /// 拿数据库时间和宿主机时间比的程序（比如 ClimbGo 的数据库测试）在头 30 秒里会碰上，所以开机后由 napbox 先对一次，
    /// 之后仍交给 TimeSyncer。
    static func sync(_ pod: LinuxPod) async throws(NapboxError) {
        do {
            try await pod.withVirtualMachineInstance { vm in
                guard let vminitd = try await vm.dialAgent() as? Vminitd else {
                    throw NapboxError(.internalError, "虚拟机里的代理不是 vminitd")
                }
                do {
                    // 设的是发出那一刻的宿主机时间，路上花多久虚拟机就慢多久。第一次调用还要先建连接（实测慢 3–9 毫秒），
                    // 所以在同一条连接上再设一次
                    for _ in 0..<2 {
                        var now = timeval()
                        guard gettimeofday(&now, nil) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                        try await vminitd.setTime(sec: Int64(now.tv_sec), usec: Int32(now.tv_usec))
                    }
                } catch {
                    try? await vminitd.close()
                    throw error
                }
                try? await vminitd.close()
            }
        } catch {
            throw NapboxError(.runtimeUnavailable, "虚拟机对时失败（环境可能停了）：\(error)")
        }
    }
}
