// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "MLM",
    platforms: [
        .macOS("15.0")
    ],
    products: [
        .executable(name: "MLM", targets: ["MLM"]),
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
