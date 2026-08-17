// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "mcp-manager",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "MCPMCore", targets: ["MCPMCore"]),
        .library(name: "MCPMControl", targets: ["MCPMControl"]),
        .executable(name: "mcpmd", targets: ["mcpmd"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.70.0"),
        .package(url: "https://github.com/apple/swift-nio-extras.git", from: "1.24.0"),
        .package(url: "https://github.com/LebJe/TOMLKit.git", from: "0.6.0"),
    ],
    targets: [
        .target(name: "MCPMCore", dependencies: [.product(name: "TOMLKit", package: "TOMLKit")]),
        .target(name: "MCPMControl", dependencies: [
            "MCPMCore",
            .product(name: "NIO", package: "swift-nio"),
            .product(name: "NIOExtras", package: "swift-nio-extras"),
        ]),
        .executableTarget(name: "mcpmd", dependencies: ["MCPMCore", "MCPMControl"]),
        .testTarget(name: "MCPMCoreTests", dependencies: ["MCPMCore"], resources: [.copy("Fixtures")]),
        .testTarget(name: "MCPMControlTests", dependencies: ["MCPMControl"]),
    ],
    swiftLanguageModes: [.v6]
)
