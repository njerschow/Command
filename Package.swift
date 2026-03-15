// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Command",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Command",
            path: "Sources"
        )
    ]
)
