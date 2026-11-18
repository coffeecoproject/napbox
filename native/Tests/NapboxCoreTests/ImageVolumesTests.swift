// 镜像声明了 VOLUME、compose 没在那个路径挂东西的，和 Docker 一样给一块匿名卷；挂了的不加。
import Foundation
@testable import NapboxCore
import Testing

struct ImageVolumesTests {
    private let compose = """
        services:
          db:
            image: postgres:17-alpine
          cache:
            image: redis:7-alpine
            volumes: [cachedata:/data/]
          scratch:
            image: postgres:17-alpine
            tmpfs: ["/var/lib/postgresql/data:size=64m"]
          app:
            image: example/app
            volumes: [appdata:/var/lib]
        volumes:
          cachedata:
          appdata:
        """

    @Test func uncoveredImageVolumeGetsAnonymousVolume() throws {
        let project = try load(["compose.yaml": compose]).withImageVolumes([
            "db": ["/var/lib/postgresql/data"],
            "cache": ["/data"],
            "scratch": ["/var/lib/postgresql/data/"],
            "app": ["/var/lib/app"],
        ])
        let db = ComposeProject.anonymousVolumeName(service: "db", path: "/var/lib/postgresql/data")
        let app = ComposeProject.anonymousVolumeName(service: "app", path: "/var/lib/app")
        // 没挂的：加一块匿名卷，登记成环境的卷
        #expect(project.service("db")?.namedVolumes.map(\.volume) == [db])
        #expect(project.service("db")?.namedVolumes.map(\.target) == ["/var/lib/postgresql/data"])
        // 同一路径挂了命名卷（末尾的 / 不算差别）、tmpfs 的：不加
        #expect(project.service("cache")?.namedVolumes.map(\.volume) == ["cachedata"])
        #expect(project.service("scratch")?.namedVolumes.isEmpty == true)
        // 只挂了上一级目录的：照 Docker 在下面再挂一块
        #expect(project.service("app")?.namedVolumes.map(\.volume) == ["appdata", app])
        #expect(Set(project.volumes) == ["cachedata", "appdata", db, app])
    }

    /// 同一个服务、同一个路径每次都是同一块；和 compose 里的卷名不会重名
    @Test func anonymousVolumeNameIsStableAndApart() {
        let name = ComposeProject.anonymousVolumeName(service: "db", path: "/var/lib/postgresql/data")
        #expect(name == ComposeProject.anonymousVolumeName(service: "db", path: "/var/lib/postgresql/data/"))
        #expect(name != ComposeProject.anonymousVolumeName(service: "db", path: "/var/lib/postgresql"))
        #expect(name != ComposeProject.anonymousVolumeName(service: "db2", path: "/var/lib/postgresql/data"))
        #expect(name.hasPrefix(ComposeProject.anonymousVolumePrefix))
    }

    /// 从匿名卷的名字认出是哪个服务的（服务名里有 _ 也认得对），不是匿名卷的名字认不出
    @Test func anonymousVolumeServiceIsRecovered() {
        for service in ["db", "web_app", "a_1b2c3d4e5f6a", "x-y"] {
            #expect(ComposeProject.anonymousVolumeService(ComposeProject.anonymousVolumeName(service: service, path: "/data")) == service)
        }
        #expect(ComposeProject.anonymousVolumeService("pgdata") == nil)
        #expect(ComposeProject.anonymousVolumeService("_anon_db") == nil)
        #expect(ComposeProject.anonymousVolumeService("_anon_db_nothexdigits") == nil)
    }

    @Test func reservedPrefixIsRejected() throws {
        let found = try issues(["compose.yaml": """
            services:
              db:
                image: postgres:17-alpine
                volumes: [_anon_db_x:/data]
            volumes:
              _anon_db_x:
            """])
        #expect(found.contains { "\($0)".contains("_anon_") })
    }
}
