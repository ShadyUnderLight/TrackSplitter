import Foundation
import Network

// MARK: - HTTP Server

/// A minimal HTTP server that serves the TrackSplitter web UI and accepts file uploads.
public final class WebGUIServer: @unchecked Sendable {
    private let queue = DispatchQueue(label: "WebGUIServer", qos: .userInitiated)
    private var listener: NWListener?
    private let port: UInt16

    public typealias ProgressCallback = @Sendable (String) -> Void
    public typealias CompletionCallback = @Sendable (Result<String, Error>) -> Void

    private var progressCallback: ProgressCallback?
    private var completionCallback: CompletionCallback?

    public init(port: UInt16 = 7890) {
        self.port = port
    }

    /// Start the server and return the URL to open in browser.
    public func start(
        onProgress: @escaping ProgressCallback,
        onComplete: @escaping CompletionCallback
    ) throws -> String {
        self.progressCallback = onProgress
        self.completionCallback = onComplete

        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true

        let nwPort = NWEndpoint.Port(rawValue: port)!
        listener = try NWListener(using: parameters, on: nwPort)

        listener?.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.progressCallback?("ready")
            case .failed(let err):
                self?.progressCallback?("server_error: \(err)")
            default:
                break
            }
        }

        listener?.newConnectionHandler = { [weak self] conn in
            self?.handle(connection: conn)
        }

        listener?.start(queue: queue)
        return "http://localhost:\(port)"
    }

    public func stop() {
        listener?.cancel()
        listener = nil
    }

    private func handle(connection: NWConnection) {
        connection.stateUpdateHandler = { state in
            if case .failed = state { connection.cancel() }
        }
        connection.start(queue: queue)

        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self = self, let data = data, !data.isEmpty else {
                connection.cancel()
                return
            }

            if let request = String(data: data, encoding: .utf8) {
                self.respond(to: connection, request: request)
            } else {
                connection.cancel()
            }
        }
    }

    private func respond(to connection: NWConnection, request: String) {
        let lines = request.components(separatedBy: "\r\n")
        let requestLine = lines.first ?? ""

        if requestLine.hasPrefix("GET / ") || requestLine.hasPrefix("GET /index.html") {
            serveHTML(to: connection)
        } else if requestLine.hasPrefix("POST /upload") {
            handleUpload(request: request, connection: connection)
        } else if requestLine.hasPrefix("GET /progress") {
            serveSSE(to: connection)
        } else if requestLine.hasPrefix("GET /reveal") {
            handleReveal(request: request, connection: connection)
        } else {
            let notFound = "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n"
            connection.send(content: notFound.data(using: .utf8), completion: .contentProcessed { _ in connection.cancel() })
        }
    }

    private func serveHTML(to connection: NWConnection) {
        let html = EmbeddedWebUI.html
        let body = """
        HTTP/1.1 200 OK\r
        Content-Type: text/html; charset=utf-8\r
        Content-Length: \(html.utf8.count)\r
        Connection: close\r
        \r
        \(html)
        """
        connection.send(content: body.data(using: .utf8), completion: .contentProcessed { _ in connection.cancel() })
    }

    private func handleUpload(request: String, connection: NWConnection) {
        // Find boundary
        guard let boundaryMatch = request.range(of: "boundary=") else {
            sendError(to: connection, code: 400, message: "Missing boundary")
            return
        }
        let boundaryEnd = request[boundaryMatch.upperBound...]
        let boundary = "--\(String(boundaryEnd.prefix(while: { !$0.isNewline && !$0.isWhitespace })))"

        // Extract filename from Content-Disposition
        let dispositionMatch = request.range(of: "filename=\"")
        guard let fnameStart = dispositionMatch?.upperBound else {
            sendError(to: connection, code: 400, message: "Missing filename")
            return
        }
        let fname = String(request[fnameStart...]).prefix(while: { $0 != "\"" })
        let flacName = String(fname)

        // Get request body (after headers)
        guard let bodyStart = request.range(of: "\r\n\r\n")?.upperBound else {
            sendError(to: connection, code: 400, message: "Missing body")
            return
        }
        let body = String(request[bodyStart...])

        // Find file data start/end using boundary
        guard let dataStart = body.range(of: "\r\n\r\n")?.upperBound,
              let dataEnd = body.range(of: "\r\n\(boundary)--", options: .backwards)?.lowerBound else {
            sendError(to: connection, code: 400, message: "Cannot parse file data")
            return
        }
        let flacData = String(body[dataStart..<dataEnd])
        // Convert to Data (the body contains raw bytes, decode as UTF-8 lossily)
        let fileData = Data(flacData.utf8)

        // Save to temp
        let tempDir = FileManager.default.temporaryDirectory
        let flacURL = tempDir.appendingPathComponent(flacName)
        let cueURL = flacURL.deletingPathExtension().appendingPathExtension("cue")

        do {
            try fileData.write(to: flacURL)
            // Also write CUE if included
            if let cueRange = request.range(of: "name=\"cue\""),
               let cueStart = request.range(of: "\r\n\r\n", range: cueRange.upperBound..<request.endIndex)?.upperBound,
               let cueEnd = request.range(of: "\r\n\(boundary)--", options: .backwards)?.lowerBound {
                let cueStr = String(request[cueStart..<cueEnd])
                let cueData = Data(cueStr.utf8)
                try cueData.write(to: cueURL)
            }

            // Trigger processing asynchronously
            Task { [weak self] in
                await self?.processFile(flacURL: flacURL, connection: connection)
            }
        } catch {
            sendError(to: connection, code: 500, message: "Failed to save file: \(error.localizedDescription)")
        }
    }

    private func processFile(flacURL: URL, connection: NWConnection) async {
        let handler = TrackSplitterEngine.LogHandler { [weak self] msg in
            self?.sendSSEEvent(connection: connection, event: "progress", data: msg)
        }

        let engine = TrackSplitterEngine(logHandler: handler)

        do {
            let result = try await engine.process(flacURL: flacURL)
            sendSSEEvent(connection: connection, event: "complete", data: result.outputDirectory.path)
        } catch {
            sendSSEEvent(connection: connection, event: "error", data: error.localizedDescription)
        }

        // Clean up temp files
        try? FileManager.default.removeItem(at: flacURL)
        try? FileManager.default.removeItem(at: flacURL.deletingPathExtension().appendingPathExtension("cue"))
    }

    private func sendSSEEvent(connection: NWConnection, event: String, data: String) {
        let sse = "event: \(event)\r\ndata: \(data.replacingOccurrences(of: "\n", with: "\\n"))\r\n\r\n"
        connection.send(content: sse.data(using: .utf8), completion: .contentProcessed { _ in })
    }

    private func serveSSE(to connection: NWConnection) {
        connection.send(content: "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nCache-Control: no-cache\r\nConnection: keep-alive\r\n\r\n".data(using: .utf8), completion: .contentProcessed { _ in })
        // Keep connection alive (SSE)
        DispatchQueue.global().asyncAfter(deadline: .now() + 300) {
            connection.cancel()
        }
    }

    private func handleReveal(request: String, connection: NWConnection) {
        // GET /reveal?path=...
        guard let range = request.range(of: "GET /reveal?path="),
              let endRange = request.range(of: " ", range: range.upperBound..<request.endIndex) else {
            sendError(to: connection, code: 400, message: "Invalid path")
            return
        }

        let encodedPath = String(request[range.upperBound..<endRange.lowerBound])
        let path = encodedPath.removingPercentEncoding ?? encodedPath

        DispatchQueue.global().async {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            proc.arguments = ["-R", path]  // Reveal in Finder
            try? proc.run()
            proc.waitUntilExit()
        }

        let body = "OK"
        let response = "HTTP/1.1 200 OK\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)"
        connection.send(content: response.data(using: .utf8), completion: .contentProcessed { _ in connection.cancel() })
    }

    private func sendError(to connection: NWConnection, code: Int, message: String) {
        let body = "Error: \(message)"
        let response = "HTTP/1.1 \(code) \(code == 400 ? "Bad Request" : "Server Error")\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)"
        connection.send(content: response.data(using: .utf8), completion: .contentProcessed { _ in connection.cancel() })
    }
}
