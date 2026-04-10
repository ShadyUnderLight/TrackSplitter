// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "TrackSplitter",
    platforms: [.macOS("13.0")],
    products: [
        .executable(name: "tracksplitter", targets: ["TrackSplitterCLI"])
    ],
    dependencies: [],
    targets: [
        .executableTarget(
            name: "TrackSplitterCLI",
            dependencies: ["TrackSplitterLib"],
            path: "CLI",
            sources: ["main.swift"]
        ),
        .target(
            name: "TrackSplitterLib",
            dependencies: [],
            path: "Library",
            sources: ["CueParser.swift", "AlbumArtFetcher.swift", "FLACSplitter.swift", "MetadataEmbedder.swift", "TrackSplitterEngine.swift"]
        )
    ]
)
