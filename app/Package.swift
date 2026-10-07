// swift-tools-version: 6.2
import PackageDescription

// Build through scripts/bundle.sh, which builds the Rust static library first
// and passes its directory to the linker.
let package = Package(
    name: "Deckle",
    platforms: [.macOS(.v26)],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.10.0"),
    ],
    targets: [
        .systemLibrary(name: "CDeckleCore", path: "Sources/CDeckleCore"),
        .executableTarget(
            name: "Deckle",
            dependencies: [
                "CDeckleCore",
                .product(name: "Sparkle", package: "Sparkle"),
            ]
        ),
    ]
)
