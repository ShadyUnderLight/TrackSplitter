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
                "GUI/App/TrackSplitterApp.swift",
                "GUI/App/AppState.swift",
                "GUI/App/main.swift",
                "GUI/Views/ContentView.swift",
                "GUI/Views/DropZoneView.swift",
                "GUI/Views/TrackListView.swift",
                "GUI/Views/ProcessingView.swift",
                "GUI/ViewModels/SplitterViewModel.swift",
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
