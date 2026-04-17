// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "TrackSplitter",
    platforms: [.macOS("13.0")],
    products: [
        .executable(name: "tracksplitter", targets: ["TrackSplitterCLI"]),
        .executable(name: "tracksplitter-gui", targets: ["TrackSplitterGUI"])
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
            sources: [
                "CueParser.swift",
                "AlbumArtFetcher.swift",
                "AudioSplitter.swift",
                "MetadataEmbedder.swift",
                "TrackSplitterEngine.swift",
            ]
        ),
        .executableTarget(
            name: "TrackSplitterGUI",
            dependencies: ["TrackSplitterLib"],
            path: ".",
            sources: [
                "App/TrackSplitterApp.swift",
                "App/AppState.swift",
                "Views/ContentView.swift",
                "Views/DropZoneView.swift",
                "Views/TrackListView.swift",
                "Views/ProcessingView.swift",
                "Views/ResultView.swift",
                "ViewModels/SplitterViewModel.swift",
            ]
        ),
        .testTarget(
            name: "TrackSplitterTests",
            dependencies: ["TrackSplitterLib"],
            path: "Tests",
            sources: ["AudioSplitterTests.swift"]
        )
    ]
)
