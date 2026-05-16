// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ClipMate",
    platforms: [
        .macOS("14.0")
    ],
    products: [
        .executable(
            name: "ClipMate",
            targets: ["App"]
        )
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift", from: "6.24.0"),
    ],
    targets: [
        .executableTarget(
            name: "App",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            path: "App/Sources",
            exclude: [],
            resources: [
                .process("../Resources")
            ]
        ),
    ]
)
