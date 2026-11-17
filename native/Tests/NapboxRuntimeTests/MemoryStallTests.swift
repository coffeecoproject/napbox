import Foundation
import Testing
@testable import NapboxRuntime

@Suite struct MemoryStallTests {
    /// 网络小容器发来的就是这样一行（guard/memwatch_logic.go 的 memoryReport）
    @Test func decodesGuardReport() throws {
        let line = #"{"service":"browser","scope":"service","limitBytes":2147483648,"pressure":45.5,"targetService":"browser","pid":301,"process":"chrome","processBytes":566231040}"#
        let stall = try JSONDecoder().decode(MemoryStall.self, from: Data(line.utf8))
        #expect(stall == MemoryStall(service: "browser", scope: .service, limitBytes: 2 << 30, pressure: 45.5,
                                     targetService: "browser", pid: 301, process: "chrome", processBytes: 540 << 20))
        #expect(stall.message.contains("browser 的内存到了上限 2.0GB"))
        #expect(stall.message.contains("chrome（进程号 301，占 540MB）"))
        #expect(stall.message.contains("mem_limit"))
    }

    @Test func environmentScopeNamesTheOtherService() {
        let stall = MemoryStall(service: "browser", scope: .environment, limitBytes: 0, pressure: 40,
                                targetService: "postgres", pid: 120, process: "postgres", processBytes: 900 << 20)
        #expect(stall.message.contains("整个环境的内存用完了，browser 卡住了"))
        #expect(stall.message.contains("postgres 里的 postgres（进程号 120，占 900MB）"))
    }
}
