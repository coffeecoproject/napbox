// 镜像：补全镜像名、按 pull_policy 拉取、构建出来的镜像叫什么。
import Containerization
import ContainerizationOCI
import CryptoKit
import Foundation
import NapboxCore
import NapboxProtocol

enum Images {
    /// `postgres:17-alpine` → `docker.io/library/postgres:17-alpine`。Containerization 不会自己补 docker.io。
    static func normalize(_ reference: String) throws(NapboxError) -> String {
        do {
            var parsed = try Reference.parse(reference)
            if parsed.domain == nil { parsed = try Reference.parse("docker.io/\(reference)") }
            parsed.normalize()
            return parsed.description
        } catch {
            throw NapboxError(.composeInvalid, "镜像名写法不对：\(reference)")
        }
    }

    /// 服务的镜像是构建出来的话，是哪一份 build：自己写了 build，或者 image 和同一份 compose 里一个写了 build 的
    /// 服务相同（Docker 里它们用的是同一个构建结果）。
    static func build(of service: Service, in project: ComposeProject) -> Build? {
        if let build = service.build { return build }
        guard let image = service.image else { return nil }
        return project.services.first { $0.image == image && $0.build != nil }?.build
    }

    /// 环境构建出来的镜像都在这个名字下面，回收时一起删
    static func builtPrefix(environment id: String) -> String { "napbox.local/\(id)/" }

    /// 构建结果的镜像名：每个环境、每份 build 定义一个。不用 compose 里的 image：两个 worktree 的代码不一样，
    /// 同名就会用到对方构建的镜像。build 定义一样的服务共用一个，只构建一次。
    static func builtReference(environment id: String, build: Build) throws(NapboxError) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data: Data
        do {
            data = try encoder.encode(build)
        } catch {
            throw NapboxError(.internalError, "build 定义编码失败：\(error)")
        }
        let digest = SHA256.hash(data: data).prefix(6).map { String(format: "%02x", $0) }.joined()
        return try normalize("\(builtPrefix(environment: id))build-\(digest):latest")
    }

    /// 按 pull_policy 准备镜像：只在 up、create 的准备阶段用（Runtime.prepareImages）。不用于构建出来的镜像
    static func resolve(_ service: Service, store: ImageStore) async throws(NapboxError) -> Containerization.Image {
        try await fetch(service, policy: service.pullPolicy, store: store)
    }

    /// 起环境时用的镜像：always 也不重新拉，和 Docker 重启容器一样。不然唤醒、重启时没网就起不来，
    /// 镜像更新了还会换版本、重建根文件系统，容器里写的内容就丢了。同样，构建出来的镜像也只用现成的
    static func forStart(_ service: Service, project: ComposeProject, environment id: String, store: ImageStore) async throws(NapboxError) -> Containerization.Image {
        if let build = build(of: service, in: project) {
            let reference = try builtReference(environment: id, build: build)
            guard let image = try? await store.get(reference: reference) else {
                throw NapboxError(.imageUnavailable, "\(service.name) 构建出来的镜像 \(reference) 没有了，再运行一次 napbox up 会重新构建")
            }
            return image
        }
        return try await fetch(service, policy: service.pullPolicy == .always ? .missing : service.pullPolicy, store: store)
    }

    private static func fetch(_ service: Service, policy: PullPolicy?, store: ImageStore) async throws(NapboxError) -> Containerization.Image {
        guard let reference = service.image else {
            throw NapboxError(.internalError, "\(service.name) 既没有 image 也没有 build")
        }
        return try await fetch(try normalize(reference), policy: policy, store: store, service: service.name)
    }

    /// 实际用的 linux/arm64 manifest 的 digest
    static func platformDigest(_ image: Containerization.Image) async throws(NapboxError) -> String {
        do {
            return try await image.descriptor(for: linuxArm64).digest
        } catch {
            throw NapboxError(.imageUnavailable, "镜像 \(image.reference) 没有 linux/arm64 版本：\(error)")
        }
    }

    /// pull_policy：always 每次拉；never 只用本地的；其余（默认 missing）本地没有才拉。
    static func fetch(_ reference: String, policy: PullPolicy?, store: ImageStore, service: String) async throws(NapboxError) -> Containerization.Image {
        if policy != .always, let local = try? await store.get(reference: reference) { return local }
        if policy == .never {
            throw NapboxError(.imageUnavailable, "\(service) 的镜像 \(reference) 本地没有，pull_policy 是 never")
        }
        do {
            return try await store.pull(reference: reference, platform: linuxArm64)
        } catch {
            throw NapboxError(.imageUnavailable, "\(service) 的镜像 \(reference) 拉不下来：\(error)")
        }
    }
}
