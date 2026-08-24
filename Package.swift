// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PipelineIsland",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "PipelineIsland",
            path: "Sources/PipelineIsland"
        )
    ]
)
