// swift-tools-version: 6.2
// 实验：不改苹果的框架，能不能让同一台虚拟机里的每个服务有自己的网络（各自的地址、各自的端口）。
import PackageDescription

let package = Package(
    name: "PodNetns",
    platforms: [.macOS("26.0")],
    dependencies: [
        .package(url: "https://github.com/apple/containerization.git", exact: "0.53.0"),
        .package(url: "https://github.com/apple/swift-system.git", from: "1.6.4"),
    ],
    targets: [
        .executableTarget(name: "PodNetns", dependencies: [
            .product(name: "Containerization", package: "containerization"),
            .product(name: "ContainerizationOCI", package: "containerization"),
            .product(name: "ContainerizationExtras", package: "containerization"),
            .product(name: "ContainerizationEXT4", package: "containerization"),
            .product(name: "SystemPackage", package: "swift-system"),
        ])
    ]
)
