import Foundation

/// Client for OpenAI Whisper API - Speech-to-Text
class WhisperClient {
    private let apiKey: String
    private let baseURL = URL(string: "https://api.openai.com/v1/audio/transcriptions")!
    private let session: URLSession

    init(apiKey: String) {
        self.apiKey = apiKey

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 120
        self.session = URLSession(configuration: config)
    }

    /// Transcribe audio file to text
    func transcribe(audioURL: URL, language: String? = nil) async throws -> String {
        // Read audio file
        let audioData = try Data(contentsOf: audioURL)

        return try await transcribe(audioData: audioData, filename: audioURL.lastPathComponent, language: language)
    }

    /// Transcribe audio data to text
    func transcribe(audioData: Data, filename: String = "audio.ogg", language: String? = nil) async throws -> String {
        let boundary = UUID().uuidString

        var request = URLRequest(url: baseURL)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        // Build multipart form data
        var body = Data()

        // Model field
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"model\"\r\n\r\n".data(using: .utf8)!)
        body.append("whisper-1\r\n".data(using: .utf8)!)

        // Language field (optional but helps accuracy)
        if let lang = language {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"language\"\r\n\r\n".data(using: .utf8)!)
            body.append("\(lang)\r\n".data(using: .utf8)!)
        }

        // Response format
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"response_format\"\r\n\r\n".data(using: .utf8)!)
        body.append("text\r\n".data(using: .utf8)!)

        // Audio file
        let mimeType = getMimeType(for: filename)
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: \(mimeType)\r\n\r\n".data(using: .utf8)!)
        body.append(audioData)
        body.append("\r\n".data(using: .utf8)!)

        // End boundary
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)

        request.httpBody = body

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw WhisperError.invalidResponse
        }

        guard httpResponse.statusCode == 200 else {
            if let errorJson = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let error = errorJson["error"] as? [String: Any],
               let message = error["message"] as? String {
                throw WhisperError.apiError(message)
            }
            throw WhisperError.httpError(httpResponse.statusCode)
        }

        // Response is plain text when using response_format=text
        guard let transcription = String(data: data, encoding: .utf8) else {
            throw WhisperError.parseError
        }

        return transcription.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func getMimeType(for filename: String) -> String {
        let ext = (filename as NSString).pathExtension.lowercased()
        switch ext {
        case "mp3": return "audio/mpeg"
        case "mp4", "m4a": return "audio/mp4"
        case "wav": return "audio/wav"
        case "ogg", "opus": return "audio/ogg"
        case "webm": return "audio/webm"
        case "flac": return "audio/flac"
        default: return "audio/ogg" // WhatsApp default
        }
    }

    enum WhisperError: Error, LocalizedError {
        case invalidResponse
        case httpError(Int)
        case parseError
        case apiError(String)
        case fileNotFound

        var errorDescription: String? {
            switch self {
            case .invalidResponse: return "Invalid response from Whisper API"
            case .httpError(let code): return "HTTP error: \(code)"
            case .parseError: return "Failed to parse transcription"
            case .apiError(let msg): return "Whisper API error: \(msg)"
            case .fileNotFound: return "Audio file not found"
            }
        }
    }
}

// MARK: - WhatsApp Audio File Finder

extension WhisperClient {
    /// Try to find the most recent audio file from WhatsApp
    /// WhatsApp stores audio in its container directory
    static func findRecentWhatsAppAudio() -> URL? {
        let fileManager = FileManager.default

        // WhatsApp stores files in Group Containers
        guard let containerURL = fileManager.containerURL(
            forSecurityApplicationGroupIdentifier: "group.net.whatsapp.WhatsApp.shared"
        ) else {
            // Try alternative paths
            let homeDir = fileManager.homeDirectoryForCurrentUser
            let possiblePaths = [
                homeDir.appendingPathComponent("Library/Group Containers/group.net.whatsapp.WhatsApp.shared/Message/Media"),
                homeDir.appendingPathComponent("Library/Application Support/WhatsApp/Media"),
            ]

            for path in possiblePaths {
                if let audioURL = findMostRecentAudio(in: path) {
                    return audioURL
                }
            }
            return nil
        }

        let mediaPath = containerURL.appendingPathComponent("Message/Media")
        return findMostRecentAudio(in: mediaPath)
    }

    /// Find the most recent audio file in a directory
    private static func findMostRecentAudio(in directory: URL) -> URL? {
        let fileManager = FileManager.default

        guard fileManager.fileExists(atPath: directory.path) else {
            return nil
        }

        let audioExtensions = ["opus", "ogg", "m4a", "mp3", "wav", "aac"]

        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }

        var mostRecentAudio: (url: URL, date: Date)?
        let cutoffDate = Date().addingTimeInterval(-60) // Only files from last 60 seconds

        while let fileURL = enumerator.nextObject() as? URL {
            let ext = fileURL.pathExtension.lowercased()
            guard audioExtensions.contains(ext) else { continue }

            guard let resourceValues = try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]),
                  let modDate = resourceValues.contentModificationDate,
                  modDate > cutoffDate else {
                continue
            }

            if mostRecentAudio == nil || modDate > mostRecentAudio!.date {
                mostRecentAudio = (fileURL, modDate)
            }
        }

        return mostRecentAudio?.url
    }
}
