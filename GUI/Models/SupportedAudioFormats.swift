import Foundation
import UniformTypeIdentifiers

/// Supported audio file extensions for input validation and system integration.
/// Single source of truth — all GUI code paths (drag/drop, file panel, engine load)
/// reference this constant to stay in sync.
enum SupportedAudioFormat {
    /// All supported input file extensions (lowercase, no dot), in canonical order.
    static let extensions: [String] = [
        "flac", "mp3", "wav", "aiff", "alac", "m4a", "aac", "ogg", "opus"
    ]

    /// Corresponding `UTType` values for file panels and document type declarations.
    /// Returns `.audio` as fallback for any extension not recognized by the system.
    static var utTypes: [UTType] {
        extensions.map { UTType(filenameExtension: $0) ?? .audio }
    }
}
