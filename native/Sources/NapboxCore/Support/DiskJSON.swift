// napbox 自己写到磁盘上的 JSON（state.json、.napbox/ports.json、recycled.json）：读写用同一套设置，
// 给人看的格式（缩进、键排序、路径里的 / 不转义），日期用 ISO 8601。
import Foundation

public enum DiskJSON {
    public static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return e
    }()

    public static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}
