// swift-tools-version: 5.9
import PackageDescription

// Proxi：原生的 macOS 菜单栏代理工具。用 swift build 编译，Scripts/build-app.sh 组装成 .app。
let package = Package(
    name: "Proxi",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Proxi",
            path: "Sources/Proxi"
        ),
        .testTarget(
            name: "ProxiTests",
            dependencies: ["Proxi"],
            path: "Tests/ProxiTests"
        ),
    ],
    swiftLanguageVersions: [.v5]
)
