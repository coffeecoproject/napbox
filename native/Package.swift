// swift-tools-version: 6.2
// napbox 的原生部分：napboxd（守护进程）和 napbox（命令行），共用 NapboxProtocol 里的协议定义。
import PackageDescription

let package = Package(
    name: "napbox-native",
    platforms: [.macOS("26.0")],
    products: [
        .executable(name: "napboxd", targets: ["napboxd"]),
        .executable(name: "napbox", targets: ["napbox"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.105.0"),
        .package(url: "https://github.com/apple/swift-nio-extras.git", from: "1.35.2"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.8.2"),
        .package(url: "https://github.com/jpsim/Yams.git", from: "6.2.2"),
        // LinuxPod 是实验 API，锁定版本
        .package(url: "https://github.com/apple/containerization.git", exact: "0.53.0"),
        // 建空的 ext4 数据卷要用它的 FilePath（Containerization 本身也依赖它）
        .package(url: "https://github.com/apple/swift-system.git", from: "1.6.4"),
    ],
    targets: [
        .target(name: "NapboxProtocol"),
        // napboxd 的环境管理：compose 解析、环境识别、端口登记。命令行不链接它。
        .target(
            name: "NapboxCore",
            dependencies: ["NapboxProtocol", .product(name: "Yams", package: "Yams")]
        ),
        .testTarget(name: "NapboxCoreTests", dependencies: ["NapboxCore", "NapboxProtocol"]),
        // 用 Containerization 起环境：镜像、根文件系统、数据卷、LinuxPod
        .target(
            name: "NapboxRuntime",
            dependencies: [
                "NapboxCore", "NapboxProtocol",
                .product(name: "Containerization", package: "containerization"),
                .product(name: "ContainerizationOCI", package: "containerization"),
                .product(name: "ContainerizationExtras", package: "containerization"),
                .product(name: "ContainerizationEXT4", package: "containerization"),
                .product(name: "ContainerizationArchive", package: "containerization"),
                .product(name: "ContainerizationOS", package: "containerization"),
                .product(name: "SystemPackage", package: "swift-system"),
                .product(name: "NIOPosix", package: "swift-nio"),
            ]
        ),
        .testTarget(name: "NapboxRuntimeTests", dependencies: ["NapboxRuntime"]),
        .executableTarget(
            name: "napboxd",
            dependencies: [
                "NapboxProtocol",
                "NapboxCore",
                "NapboxRuntime",
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOConcurrencyHelpers", package: "swift-nio"),
                .product(name: "NIOExtras", package: "swift-nio-extras"),
            ]
        ),
        .executableTarget(
            name: "napbox",
            dependencies: [
                "NapboxProtocol",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
    ]
)
