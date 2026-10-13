// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Chillar",
    platforms: [.macOS(.v14)],
    targets: [
        // Use ./build.sh to produce the signed, sandboxed .app; this target is for editors and `swift build`.
        .executableTarget(name: "Chillar", path: "Sources/Chillar")
    ]
)
