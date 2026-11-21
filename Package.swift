// swift-tools-version: 6.0
import PackageDescription

// 与 Palmhelm 的 Mac 客户端共用的 Bridge 客户端：模型、HTTP 调用、SSE 解析。核心不依赖 UI 框架。
let package = Package(
    name: "PalmhelmKit",
    defaultLocalization: "en",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "PalmhelmKit", targets: ["PalmhelmKit"]),
    ],
    targets: [
        .target(name: "PalmhelmKit", resources: [.process("Resources")], swiftSettings: [.swiftLanguageMode(.v6)]),
        .testTarget(name: "PalmhelmKitTests", dependencies: ["PalmhelmKit"], exclude: ["Support/tls-fixture.mjs", "ReceiptFixtures"], swiftSettings: [.swiftLanguageMode(.v6)]),
    ]
)
