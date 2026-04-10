import Foundation

/// Bridges to embed_metadata.py to write FLAC tags and cover art.
public actor MetadataEmbedder {

    public enum EmbedError: Error, LocalizedError {
        case pythonNotFound
        case scriptNotFound
        case encodingFailed
        case tempFileFailed
        case scriptFailed(String)

        public var errorDescription: String? {
            switch self {
            case .pythonNotFound: return "Python 3 not found in PATH"
            case .scriptNotFound: return "embed_metadata.py not found"
            case .encodingFailed: return "Failed to encode metadata as JSON"
            case .tempFileFailed: return "Failed to write temp JSON file"
            case .scriptFailed(let msg): return "Metadata script error: \(msg)"
            }
        }
    }

    private let pythonPath: String
    private let scriptPath: String

    public init() {
        self.pythonPath = "/opt/homebrew/bin/python3"
        // In SPM CLI builds, Resources/embed_metadata.py is placed next to the executable.
        if let exePath = CommandLine.arguments.first.map({ URL(fileURLWithPath: $0).deletingLastPathComponent().path }) {
            self.scriptPath = (exePath as NSString).appendingPathComponent("embed_metadata.py")
        } else {
            self.scriptPath = "embed_metadata.py"
        }
    }

    /// Embed metadata into multiple FLAC files at once.
    public func embedBatch(
        files: [(url: URL, title: String, trackNumber: Int)],
        artist: String,
        album: String,
        year: String,
        genre: String,
        totalTracks: Int,
        coverData: Data?
    ) async throws {
        struct Item: Encodable {
            let path: String; let title: String; let artist: String
            let album: String; let year: String; let genre: String
            let tracknum: String; let total: String
        }

        let items = files.map { f in
            Item(path: f.url.path, title: f.title, artist: artist, album: album,
                 year: year, genre: genre, tracknum: String(f.trackNumber), total: String(totalTracks))
        }

        let coverB64: String? = coverData.map { Data($0).base64EncodedString() }
        struct Payload: Encodable { let files: [Item]; let coverData: String? }
        let payload = Payload(files: items, coverData: coverB64)

        guard let jsonData = try? JSONEncoder().encode(payload) else {
            throw EmbedError.encodingFailed
        }

        let tempDir = FileManager.default.temporaryDirectory
        let tempFile = tempDir.appendingPathComponent("tracksplitter_payload_\(UUID().uuidString).json")
        do {
            try jsonData.write(to: tempFile)
        } catch {
            throw EmbedError.tempFileFailed
        }

        defer { try? FileManager.default.removeItem(at: tempFile) }
        try await runScript(jsonFile: tempFile)
    }

    private func runScript(jsonFile: URL) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: pythonPath)
            process.arguments = [scriptPath, jsonFile.path]

            let outPipe = Pipe()
            let errPipe = Pipe()
            process.standardOutput = outPipe
            process.standardError = errPipe

            do {
                try process.run()
                process.waitUntilExit()

                let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
                let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                let stdout = String(data: outData, encoding: .utf8) ?? ""
                let stderr = String(data: errData, encoding: .utf8) ?? ""

                if process.terminationStatus == 0 {
                    cont.resume()
                } else {
                    cont.resume(throwing: EmbedError.scriptFailed(
                        "RC=\(process.terminationStatus) STDERR=\(stderr.prefix(200)) STDOUT=\(stdout.prefix(100))"
                    ))
                }
            } catch {
                cont.resume(throwing: error)
            }
        }
    }
}
