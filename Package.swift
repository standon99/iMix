// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "SoundStage",
    platforms: [.macOS("14.2")],
    targets: [
        .executableTarget(
            name: "SoundStage",
            path: "Sources/SoundStage"
        )
    ]
)
