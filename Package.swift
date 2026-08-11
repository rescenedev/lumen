// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Lumen",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "6.0.0")
    ],
    targets: [
        // All real app code lives in this library so it can be linked by both
        // the app executable and the test runner. (Executable targets can't be
        // linked against — hence the library + thin-executable split.)
        .target(
            name: "LumenKit",
            dependencies: [.product(name: "GRDB", package: "GRDB.swift")],
            path: "Sources/Lumen",
            resources: [.process("Resources")]
        ),
        // The shipping app: a 2-line executable that launches LumenKit. Kept
        // named "Lumen" so Scripts/make_app.sh copies .build/release/Lumen.
        .executableTarget(
            name: "Lumen",
            dependencies: ["LumenKit"],
            path: "Sources/LumenMain"
        ),
        // Metadata reader, in a process of its own. ImageIO can abort on a
        // malformed file; out here that costs one photo instead of the app.
        // Shipped inside Lumen.app/Contents/MacOS/ by Scripts/make_app.sh.
        .executableTarget(
            name: "lumen-meta-bg",
            dependencies: ["LumenKit"],
            path: "Sources/LumenMetaBG"
        ),
        // Thumbnail builder, in a process of its own. The decode path falls
        // back to QuickLook, which can block forever on a wedged mount — out
        // here the parent can kill it and carry on.
        .executableTarget(
            name: "lumen-thumb-bg",
            dependencies: ["LumenKit"],
            path: "Sources/LumenThumbBG"
        ),
        // Test runner. macOS Command Line Tools (no full Xcode) ship neither
        // XCTest nor swift-testing, so `swift test` can't run here. Instead this
        // is a plain executable with a tiny zero-dependency assertion harness:
        //   swift run LumenTests
        .executableTarget(
            name: "LumenTests",
            dependencies: ["LumenKit", .product(name: "GRDB", package: "GRDB.swift")],
            path: "Tests/LumenTests"
        )
    ]
)
