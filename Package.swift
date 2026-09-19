// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "MLM",
    platforms: [
        .macOS("15.0")
    ],
    products: [
        .executable(name: "MLM", targets: ["MLM"]),
        // Keychain access helper — the ONLY component that imports Security.
        // See MLMAuthHelper/main.swift for why it exists.
        .executable(name: "mlm-auth", targets: ["MLMAuthHelper"]),
    ],
    dependencies: [
        // GRDB — best Swift SQLite library, migration support, Codable mapping
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
    ],
    targets: [
        .executableTarget(
            name: "MLM",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            path: "MLM",
            resources: [
                .copy("Resources/YAMNet.mlmodelc"),
                .process("Resources/AppIcon.icns"),
                .process("Resources/MLM.entitlements"),
                .process("Resources/README.md")
            ],
            linkerSettings: [
                .linkedFramework("AVKit"),
                .linkedFramework("AVFoundation")
            ]
        ),
        // Small CLI that owns ALL keychain access for the app (single JSON
        // item per OAuth service). Signed with a stable identity by
        // scripts/setup-dev-signing.sh so a one-time keychain "Always Allow"
        // consent survives app rebuilds.
        .executableTarget(
            name: "MLMAuthHelper",
            path: "MLMAuthHelper"
        ),
        .testTarget(
            name: "MLMTests",
            dependencies: [
                "MLM",
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            path: "MLMTests"
        ),
    ]
)
