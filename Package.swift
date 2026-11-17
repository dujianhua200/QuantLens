// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "QuantLens",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "QuantLens", targets: ["QuantLens"])
    ],
    targets: [
        .executableTarget(
            name: "QuantLens",
            path: "Sources/QuantLens",
            swiftSettings: [.unsafeFlags(["-Ounchecked"], .when(configuration: .release))]
        ),
        // 测试以 @testable import 引用可执行 target（SwiftPM 5.4+ 标准做法）：
        // 测试构建时 main.swift 被排除，不拆 library、不影响 build_app.sh 打包。
        .testTarget(
            name: "QuantLensTests",
            dependencies: ["QuantLens"],
            path: "Tests/QuantLensTests"
        )
    ]
)
