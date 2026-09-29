// swift-tools-version: 5.9
import PackageDescription

// Kaze：原生的 macOS 菜单栏代理工具。用 swift build 编译，Scripts/build-app.sh 组装成 .app。
let package = Package(
    name: "Kaze",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Kaze",
            path: "Sources/Kaze"
        ),
        .testTarget(
            name: "KazeTests",
            dependencies: ["Kaze"],
            path: "Tests/KazeTests"
        ),
    ],
    swiftLanguageVersions: [.v5]
)
