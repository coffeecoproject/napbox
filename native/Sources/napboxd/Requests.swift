// 请求的公共部分：普通方法（Daemon）和流式方法（Streams）都按这里解析 params、把错误变成回应。
import NapboxProtocol

enum Requests {
    /// 执行 body（在调用方的 actor 上），把结果或错误变成这个请求的回应
    static func respond(to request: Request, isolation: isolated (any Actor)? = #isolation,
                        _ body: () async throws -> JSONValue) async -> Response {
        do {
            return Response(id: request.id, result: try await body())
        } catch let error as NapboxError {
            return Response(id: request.id, error: error)
        } catch {
            return Response(id: request.id, error: NapboxError(.internalError, "\(error)"))
        }
    }

    static func params<T: Decodable>(_ type: T.Type, _ request: Request) throws(NapboxError) -> T {
        guard let params = request.params else { throw NapboxError(.badRequest, "\(request.method) 缺少 params") }
        do { return try Wire.decode(type, from: params) } catch {
            throw NapboxError(.badRequest, "\(request.method) 的 params 不对：\(error)")
        }
    }

    static func unknownMethod(_ request: Request) -> NapboxError {
        NapboxError(.unknownMethod, "不认识的方法：\(request.method)")
    }
}
