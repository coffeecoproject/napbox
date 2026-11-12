// swift-tools-version: 6.2
import PackageDescription

let deps: [Target.Dependency] = [
    .product(name: "Containerization", package: "containerization"),
    .product(name: "ContainerizationOCI", package: "containerization"),
    .product(name: "ContainerizationExtras", package: "containerization"),
]
let package = Package(
    name: "PodProto",
    platforms: [.macOS("26.0")],
    dependencies: [
        .package(url: "https://github.com/apple/containerization.git", exact: "0.53.0"),
    ],
    targets: [
        .executableTarget(name: "PodProto", dependencies: deps),
        .executableTarget(name: "PodNet", dependencies: deps),
        .executableTarget(name: "PodLife", dependencies: deps),
        .executableTarget(name: "PodOrder", dependencies: deps),
    ]
)
