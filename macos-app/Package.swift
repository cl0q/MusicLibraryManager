// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "MLM",
    platforms: [
        .macOS(.v14)
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
                .process("Resources"),
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
