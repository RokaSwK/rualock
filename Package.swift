// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Rualock",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "Rualock", path: "Sources/Rualock"),
    ]
)
