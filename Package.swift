// swift-tools-version:6.0
// Sonata — Native macOS memory system. Phase 0: SQLite + HTTP server.

import PackageDescription

let package = Package(
    name: "Sonata",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/hummingbird-project/hummingbird.git", from: "2.0.0"),
        .package(url: "https://github.com/hummingbird-project/hummingbird-websocket.git", from: "2.0.0"),
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", from: "1.0.0"),
        .package(url: "https://github.com/21-DOT-DEV/swift-secp256k1.git", from: "0.10.0"),
        .package(url: "https://github.com/Cocoanetics/SwiftMail.git", from: "1.6.3"),
    ],
    targets: [
        .executableTarget(
            name: "Sonata",
            dependencies: [
                .product(name: "Hummingbird", package: "hummingbird"),
                .product(name: "HummingbirdWebSocket", package: "hummingbird-websocket"),
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "SwiftTerm", package: "SwiftTerm"),
                .product(name: "P256K", package: "swift-secp256k1"),
                .product(name: "SwiftMail", package: "SwiftMail"),
            ],
            path: "Sources",
            resources: [
                .copy("Sonata/Resources/web"),
                .copy("Sonata/Resources/worker"),
                .copy("Sonata/Resources/supervisor"),
                .copy("Sonata/Resources/mcp"),
                .copy("Sonata/Resources/skills"),
                .copy("Sonata/Resources/shaders"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        ),
        .testTarget(
            name: "SonataTests",
            dependencies: [
                "Sonata",
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            path: "Tests/SonataTests",
            resources: [
                .copy("fixtures"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        ),
        // Phase A smoke-test executable — proves notifications/claude/channel
        // works over HTTP+SSE to a real Claude Code session before Phase B.
        // Plan: /Users/evan/memory/claude/documents/plans/sonata-mcp-in-app-server-plan.md §4.
        .executableTarget(
            name: "MCPHTTPSmokeTest",
            dependencies: [
                .product(name: "Hummingbird", package: "hummingbird"),
            ],
            path: "Tools/MCPHTTPSmokeTest",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        ),
    ]
)
