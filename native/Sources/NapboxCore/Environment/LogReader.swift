// 服务日志文件的读取：napbox logs 默认只看最后几行（DESIGN.md 第 9 节），日志文件可能很大，从后往前找。
import Foundation

public enum LogReader {
    /// 最后 lines 行从文件的哪个位置开始。文件以换行结尾时，最后那个换行不算新的一行；
    /// 不足 lines 行就从头开始。读不了（比如还不存在）时是 0。
    public static func startOffset(of url: URL, lastLines lines: Int) -> UInt64 {
        guard lines > 0 else { return size(of: url) }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return 0 }
        defer { try? handle.close() }
        guard let end = try? handle.seekToEnd(), end > 0 else { return 0 }
        let block: UInt64 = 64 * 1024
        var position = end
        var newlines = 0
        var skipTrailing = true // 文件末尾的换行
        while position > 0 {
            let start = position > block ? position - block : 0
            guard (try? handle.seek(toOffset: start)) != nil,
                  let data = try? handle.read(upToCount: Int(position - start)) else { return 0 }
            for i in stride(from: data.count - 1, through: 0, by: -1) where data[data.startIndex + i] == 0x0A {
                if skipTrailing, start + UInt64(i) == end - 1 { continue }
                newlines += 1
                if newlines == lines { return start + UInt64(i) + 1 }
            }
            skipTrailing = false
            position = start
        }
        return 0
    }

    public static func size(of url: URL) -> UInt64 {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? UInt64) ?? 0
    }

    /// 从 offset 读到 upTo（不含），最多 limit 字节
    public static func read(_ url: URL, from offset: UInt64, upTo end: UInt64, limit: Int = 64 * 1024) -> Data? {
        guard end > offset, let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard (try? handle.seek(toOffset: offset)) != nil else { return nil }
        return try? handle.read(upToCount: min(limit, Int(end - offset)))
    }
}
