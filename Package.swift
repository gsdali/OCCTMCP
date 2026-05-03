// swift-tools-version: 6.1
//
// OCCTMCP — Swift port of the Node MCP server. Coexists with the original
// TypeScript implementation under src/ during the migration; once feature
// parity is reached the Node code can be removed.
//
// SwiftPM expects test sources under Tests/<TargetName>, but this repo's
// existing TypeScript test directory is `tests/` and the volume is
// case-insensitive (APFS default), so we point SPM at SwiftTests/ to avoid
// the clash.

import PackageDescription

let package = Package(
    name: "OCCTMCP",
    platforms: [
        .macOS(.v15),
    ],
    products: [
        .library(name: "OCCTMCPCore", targets: ["OCCTMCPCore"]),
        .executable(name: "occtmcp-server", targets: ["OCCTMCPServer"]),
    ],
    dependencies: [
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", from: "0.11.0"),
        // Floor 0.168.0 matches OCCTSwiftTools' minimum (ImportProgress + the
        // GPU edge/vertex pick fields). When OCCT 8.0.0 GA tags, bump to
        // OCCTSwift 1.0.0.
        .package(url: "https://github.com/gsdali/OCCTSwift.git", from: "0.168.0"),
        .package(url: "https://github.com/gsdali/OCCTSwiftMesh.git", from: "0.1.0"),
        // ScriptHarness + DrawingComposer for shared types and the
        // generate_drawing pipeline.
        // NOTE: branch("main") rather than from: "0.9.0" because the
        // post-Tools-split fix (5533b89) hasn't been tagged yet. Bump to
        // a real tag once v0.9.0 ships.
        .package(url: "https://github.com/gsdali/OCCTSwiftScripts.git", branch: "main"),
        // Tools is the Shape ↔ ViewportBody bridge (split out of
        // OCCTSwiftViewport in v0.55.0). render_preview also pulls in
        // OCCTSwiftViewport directly for the OffscreenRenderer.
        .package(url: "https://github.com/gsdali/OCCTSwiftTools.git", from: "0.4.1"),
        .package(url: "https://github.com/gsdali/OCCTSwiftViewport.git", from: "0.55.0"),
    ],
    targets: [
        .target(
            name: "OCCTMCPCore",
            dependencies: [
                .product(name: "MCP", package: "swift-sdk"),
                .product(name: "OCCTSwift", package: "OCCTSwift"),
                .product(name: "OCCTSwiftMesh", package: "OCCTSwiftMesh"),
                .product(name: "ScriptHarness", package: "OCCTSwiftScripts"),
                .product(name: "DrawingComposer", package: "OCCTSwiftScripts"),
                .product(name: "OCCTSwiftTools", package: "OCCTSwiftTools"),
                .product(name: "OCCTSwiftViewport", package: "OCCTSwiftViewport"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "OCCTMCPServer",
            dependencies: [
                "OCCTMCPCore",
                .product(name: "MCP", package: "swift-sdk"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "OCCTMCPCoreTests",
            dependencies: ["OCCTMCPCore"],
            path: "SwiftTests/OCCTMCPCoreTests",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
