// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Lumen",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "6.0.0")
    ],
    targets: [
        .executableTarget(
            name: "Lumen",
            dependencies: [.product(name: "GRDB", package: "GRDB.swift")],
            path: "Sources/Lumen"
        )
    ]
)
