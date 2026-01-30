import Foundation
import AVFoundation

/// Service for transcribing WhatsApp audio messages
class AudioTranscriptionService {
    static let shared = AudioTranscriptionService()

    private let settings = SettingsManager.shared
    private var whisperClient: WhisperClient?

    private init() {}

    /// Transcribe the most recent audio message
    func transcribeRecentAudio() async throws -> String? {
        guard settings.audioTranscription && settings.isOpenAIConfigured else {
            print("[Audio] Transcription disabled or OpenAI not configured")
            return nil
        }

        // Create whisper client if needed
        if whisperClient == nil {
            whisperClient = WhisperClient(apiKey: settings.openAIKey)
        }

        // Try to find the most recent audio file
        guard let audioURL = findMostRecentAudioFile() else {
            print("[Audio] No recent audio file found")
            return nil
        }

        print("[Audio] Found audio file: \(audioURL.lastPathComponent)")

        do {
            // Determine language hint (Portuguese for Brazilian users)
            let language = "pt" // Can be made configurable

            let transcription = try await whisperClient!.transcribe(audioURL: audioURL, language: language)
            print("[Audio] Transcription: \(transcription.prefix(50))...")
            return transcription
        } catch {
            print("[Audio] Transcription failed: \(error)")
            throw error
        }
    }

    /// Find the most recent audio file from WhatsApp
    private func findMostRecentAudioFile() -> URL? {
        let fileManager = FileManager.default
        let homeDir = fileManager.homeDirectoryForCurrentUser

        // WhatsApp Desktop stores audio in various locations
        let possiblePaths = [
            // WhatsApp Group Container (most common)
            homeDir.appendingPathComponent("Library/Group Containers/group.net.whatsapp.WhatsApp.shared/Message/Media"),
            // Alternative WhatsApp paths
            homeDir.appendingPathComponent("Library/Application Support/WhatsApp/Media/Audio"),
            homeDir.appendingPathComponent("Library/Containers/desktop.WhatsApp/Data/Library/Application Support/WhatsApp/Media"),
            // Downloads folder (if user saved audio)
            homeDir.appendingPathComponent("Downloads"),
        ]

        let audioExtensions = Set(["opus", "ogg", "m4a", "mp3", "wav", "aac", "mp4"])
        let cutoffTime = Date().addingTimeInterval(-30) // Only files from last 30 seconds

        var bestMatch: (url: URL, date: Date)?

        for basePath in possiblePaths {
            guard fileManager.fileExists(atPath: basePath.path) else { continue }

            if let match = findMostRecentAudioIn(directory: basePath, extensions: audioExtensions, after: cutoffTime) {
                if bestMatch == nil || match.date > bestMatch!.date {
                    bestMatch = match
                }
            }
        }

        return bestMatch?.url
    }

    private func findMostRecentAudioIn(directory: URL, extensions: Set<String>, after cutoff: Date) -> (url: URL, date: Date)? {
        let fileManager = FileManager.default

        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return nil
        }

        var bestMatch: (url: URL, date: Date)?

        while let fileURL = enumerator.nextObject() as? URL {
            // Check extension
            let ext = fileURL.pathExtension.lowercased()
            guard extensions.contains(ext) else { continue }

            // Check modification date
            guard let resourceValues = try? fileURL.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey]),
                  let isRegularFile = resourceValues.isRegularFile, isRegularFile,
                  let modDate = resourceValues.contentModificationDate,
                  modDate > cutoff else {
                continue
            }

            // Keep most recent
            if bestMatch == nil || modDate > bestMatch!.date {
                bestMatch = (fileURL, modDate)
            }
        }

        return bestMatch
    }

    /// Check if audio transcription is available
    var isAvailable: Bool {
        settings.audioTranscription && settings.isOpenAIConfigured
    }
}

// MARK: - Alternative: System Audio Recording (if file access doesn't work)

extension AudioTranscriptionService {
    /// Record system audio for a duration and transcribe
    /// This is a fallback if we can't access WhatsApp's audio files directly
    func recordAndTranscribe(duration: TimeInterval = 10) async throws -> String? {
        // Note: This would require additional permissions and is more complex
        // For now, we rely on file access
        print("[Audio] System recording not implemented - using file access")
        return try await transcribeRecentAudio()
    }
}
