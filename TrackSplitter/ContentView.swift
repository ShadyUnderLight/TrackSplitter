import AppKit
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var engine: SplitterEngine

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("TrackSplitter")
                .font(.largeTitle.bold())

            DropZoneView(isProcessing: engine.isProcessing, onDropFile: handleDrop(providers:))

            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Progress Log")
                        .font(.headline)
                    Spacer()
                    if let outputDir = engine.outputDir {
                        Button("Reveal in Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting([outputDir])
                        }
                    }
                }

                ProgressLogView(logLines: engine.log)
                    .frame(minHeight: 220)
            }

            if !engine.finishedTracks.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Generated Tracks")
                        .font(.headline)
                    List(engine.finishedTracks, id: \.self) { track in
                        Text(track)
                    }
                    .frame(minHeight: 180)
                }
            }
        }
        .padding(24)
    }

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        guard !engine.isProcessing else {
            engine.appendLog("Already processing a FLAC file. Please wait.")
            return false
        }

        guard let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier("public.file-url") }) else {
            engine.appendLog("Drop did not contain a file URL.")
            return false
        }

        provider.loadDataRepresentation(forTypeIdentifier: "public.file-url") { data, error in
            if let error {
                Task { @MainActor in engine.appendLog("Failed to read dropped file: \(error.localizedDescription)") }
                return
            }

            guard let data, let url = URL(dataRepresentation: data, relativeTo: nil) else {
                Task { @MainActor in engine.appendLog("Could not decode dropped file URL.") }
                return
            }

            Task { @MainActor in
                do {
                    _ = try await engine.process(flacURL: url)
                } catch {
                    engine.appendLog(error.localizedDescription)
                }
            }
        }

        return true
    }
}
