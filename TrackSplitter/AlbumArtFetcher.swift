import Foundation

struct AlbumArtFetcher {
    typealias Logger = @MainActor (String) -> Void

    func fetchAlbumArt(from pageURL: String, albumName: String, logger: Logger? = nil) async -> Data? {
        let html = await fetchHTML(from: pageURL, logger: logger)
        guard let html else {
            await logger?("Warning: could not fetch album art page.")
            return nil
        }

        let preferredURL = imageURL(in: html, prioritizedBy: ["別讓我哭", albumName]) ?? imageURL(in: html, prioritizedBy: [])
        guard let imageURLString = preferredURL else {
            await logger?("Warning: no album art image found on leftfm page.")
            return nil
        }

        guard let imageData = await downloadBinary(from: imageURLString, logger: logger) else {
            await logger?("Warning: album art download failed.")
            return nil
        }

        return imageData
    }

    private func fetchHTML(from pageURL: String, logger: Logger?) async -> String? {
        await runCurl(arguments: ["-L", "--silent", "--show-error", pageURL], logger: logger)
    }

    private func downloadBinary(from url: String, logger: Logger?) async -> Data? {
        guard let curl = ExecutableLocator.find("curl") else { return nil }
        let process = Process()
        process.executableURL = curl
        process.arguments = ["-L", "--silent", "--show-error", url]

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            await logger?("Warning: curl failed to start: \(error.localizedDescription)")
            return nil
        }

        let errorData = stderr.fileHandleForReading.readDataToEndOfFile()
        if let text = String(data: errorData, encoding: .utf8), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            await logger?(text.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        guard process.terminationStatus == 0 else { return nil }
        return stdout.fileHandleForReading.readDataToEndOfFile()
    }

    private func runCurl(arguments: [String], logger: Logger?) async -> String? {
        guard let curl = ExecutableLocator.find("curl") else { return nil }
        let process = Process()
        process.executableURL = curl
        process.arguments = arguments

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            await logger?("Warning: curl failed to start: \(error.localizedDescription)")
            return nil
        }

        let errorText = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let trimmedError = errorText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedError.isEmpty {
            await logger?(trimmedError)
        }

        guard process.terminationStatus == 0 else { return nil }
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)
    }

    private func imageURL(in html: String, prioritizedBy keywords: [String]) -> String? {
        let nsHTML = html as NSString
        let patterns = [#"<img[^>]+src=\"([^\"]+)\"[^>]*"#, #"<img[^>]+src='([^']+)'[^>]*"#]

        for keyword in keywords where !keyword.isEmpty {
            if let range = html.range(of: keyword) {
                let lowerBound = html.distance(from: html.startIndex, to: range.lowerBound)
                let searchRange = NSRange(location: max(0, lowerBound - 500), length: min(nsHTML.length - max(0, lowerBound - 500), 2500))
                for pattern in patterns {
                    if let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
                       let match = regex.firstMatch(in: html, options: [], range: searchRange),
                       match.numberOfRanges > 1,
                       let resultRange = Range(match.range(at: 1), in: html) {
                        return normalize(url: String(html[resultRange]))
                    }
                }
            }
        }

        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) {
                let fullRange = NSRange(location: 0, length: nsHTML.length)
                let matches = regex.matches(in: html, options: [], range: fullRange)
                for match in matches where match.numberOfRanges > 1 {
                    guard let resultRange = Range(match.range(at: 1), in: html) else { continue }
                    let candidate = normalize(url: String(html[resultRange]))
                    if candidate.lowercased().contains("jpg") || candidate.lowercased().contains("jpeg") || candidate.lowercased().contains("png") || candidate.lowercased().contains("webp") {
                        return candidate
                    }
                }
            }
        }

        return nil
    }

    private func normalize(url: String) -> String {
        if url.hasPrefix("//") { return "https:\(url)" }
        return url
    }
}
