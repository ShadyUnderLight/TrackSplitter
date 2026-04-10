import Foundation

struct CueTrack: Identifiable, Equatable {
    let index: Int
    let title: String
    let startSeconds: Double
    let endSeconds: Double?

    var id: Int { index }
}

struct CueSheet {
    let albumTitle: String
    let artist: String
    let year: String
    let genre: String
    let pageURL: String?
    let tracks: [CueTrack]
}

enum TrackSplitterError: LocalizedError {
    case invalidDrop
    case missingCue(URL)
    case cueParse(String)
    case executableNotFound(String)
    case processFailed(String)
    case resourceMissing(String)

    var errorDescription: String? {
        switch self {
        case .invalidDrop:
            return "Drop a .flac file to begin."
        case .missingCue(let url):
            return "Missing matching CUE file: \(url.path)"
        case .cueParse(let message):
            return "CUE parsing failed: \(message)"
        case .executableNotFound(let name):
            return "Required tool not found: \(name). Install ffmpeg via Homebrew and ensure curl/python3 are available."
        case .processFailed(let message):
            return message
        case .resourceMissing(let name):
            return "Missing bundled resource: \(name)"
        }
    }
}
