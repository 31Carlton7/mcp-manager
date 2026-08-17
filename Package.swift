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
        .package(url: "https://github.com/hummingbird-project/hummingbird.git", from: "2.5.0"),
        // Already in the graph under Hummingbird; named here so the gateway can import them
        // directly instead of relying on a transitive search path.
        .package(url: "https://github.com/apple/swift-http-types.git", from: "1.0.0"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.5.0"),
        .package(url: "https://github.com/swift-server/swift-service-lifecycle.git", from: "2.6.0"),
    ],
    targets: [
        .target(name: "MCPMCore", dependencies: [.product(name: "TOMLKit", package: "TOMLKit")]),
        .target(name: "MCPMControl", dependencies: [
            "MCPMCore",
            .product(name: "NIO", package: "swift-nio"),
            .product(name: "NIOConcurrencyHelpers", package: "swift-nio"),
            .product(name: "NIOExtras", package: "swift-nio-extras"),
        ]),
        .target(name: "MCPMGateway", dependencies: [
            "MCPMCore",
            .product(name: "Hummingbird", package: "hummingbird"),
            .product(name: "HTTPTypes", package: "swift-http-types"),
            .product(name: "NIOCore", package: "swift-nio"),
            .product(name: "Logging", package: "swift-log"),
            .product(name: "ServiceLifecycle", package: "swift-service-lifecycle"),
        ]),
        .executableTarget(name: "mcpmd", dependencies: ["MCPMCore", "MCPMControl", "MCPMGateway"]),
        .testTarget(name: "MCPMCoreTests", dependencies: ["MCPMCore"], resources: [.copy("Fixtures")]),
        .testTarget(name: "MCPMControlTests", dependencies: ["MCPMControl"]),
        .testTarget(name: "MCPMGatewayTests", dependencies: [
            "MCPMGateway",
            .product(name: "Hummingbird", package: "hummingbird"),
            .product(name: "HummingbirdTesting", package: "hummingbird"),
            .product(name: "HTTPTypes", package: "swift-http-types"),
            .product(name: "NIOCore", package: "swift-nio"),
            .product(name: "Logging", package: "swift-log"),
            .product(name: "ServiceLifecycle", package: "swift-service-lifecycle"),
        ], resources: [.copy("Fixtures")]),
    ],
    swiftLanguageModes: [.v6]
)
