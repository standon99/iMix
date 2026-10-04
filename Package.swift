// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "iSound",
    platforms: [.macOS("14.2")],
    targets: [
        .executableTarget(
            name: "iSound",
            path: "Sources/iSound"
        )
    ]
)
