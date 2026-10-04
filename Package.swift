// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "iMix",
    platforms: [.macOS("14.2")],
    targets: [
        .executableTarget(
            name: "iMix",
            path: "Sources/iMix"
        )
    ]
)
