// swift-tools-version: 6.2
import PackageDescription

// Build through scripts/bundle.sh, which builds the Rust static library first
// and passes its directory to the linker.
let package = Package(
    name: "Quill",
    platforms: [.macOS(.v26)],
    targets: [
        .systemLibrary(name: "CQuillCore", path: "Sources/CQuillCore"),
        .executableTarget(
            name: "Quill",
            dependencies: ["CQuillCore"]
        ),
    ]
)
