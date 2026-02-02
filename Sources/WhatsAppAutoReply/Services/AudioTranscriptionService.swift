import Foundation
import AVFoundation

/// Service for transcribing WhatsApp audio messages
class AudioTranscriptionService {
    static let shared = AudioTranscriptionService()

    private let settings = SettingsManager.shared
    private var whisperClient: WhisperClient?

    // MARK: - Security: Audio Duration Limits

    /// Maximum allowed audio duration in seconds (5 minutes)
    /// Prevents abuse through extremely long audio files that would:
    /// - Cost excessive API credits
    /// - Take too long to process
    /// - Potentially be used for spam/abuse
    static let maxAudioDurationSeconds: TimeInterval = 300 // 5 minutes

    /// Minimum audio duration to process (avoid empty/corrupted files)
    static let minAudioDurationSeconds: TimeInterval = 0.5

    private init() {}

    // MARK: - Audio Duration Validation

    /// Check if audio file duration is within acceptable limits
    /// - Returns: Duration in seconds if valid, nil if invalid or cannot be determined
    func getAudioDuration(url: URL) async -> TimeInterval? {
        let asset = AVAsset(url: url)

        do {
            let duration = try await asset.load(.duration)
            let seconds = CMTimeGetSeconds(duration)

            // Check for invalid duration (NaN, infinity, or negative)
            guard seconds.isFinite && seconds > 0 else {
                print("[Audio] Invalid duration detected for: \(url.lastPathComponent)")
                return nil
            }

            return seconds
        } catch {
            print("[Audio] Failed to load duration for: \(url.lastPathComponent) - \(error)")
            return nil
        }
    }

    /// Validate audio file for security constraints
    /// - Throws: AudioSecurityError if validation fails
    func validateAudioFile(url: URL) async throws {
        guard let duration = await getAudioDuration(url: url) else {
            throw AudioSecurityError.invalidFile
        }

        if duration < Self.minAudioDurationSeconds {
            print("[Audio] File too short (\(String(format: "%.1f", duration))s): \(url.lastPathComponent)")
            throw AudioSecurityError.tooShort(duration: duration)
        }

        if duration > Self.maxAudioDurationSeconds {
            print("[Audio] File too long (\(String(format: "%.1f", duration))s, max: \(Self.maxAudioDurationSeconds)s): \(url.lastPathComponent)")
            throw AudioSecurityError.tooLong(duration: duration, maxAllowed: Self.maxAudioDurationSeconds)
        }

        // Check file size as additional protection (max 25MB - Whisper API limit)
        let maxFileSizeBytes: Int64 = 25 * 1024 * 1024
        if let fileSize = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64,
           fileSize > maxFileSizeBytes {
            print("[Audio] File too large (\(fileSize / 1024 / 1024)MB): \(url.lastPathComponent)")
            throw AudioSecurityError.fileTooLarge(sizeBytes: fileSize, maxBytes: maxFileSizeBytes)
        }

        print("[Audio] Validated: \(url.lastPathComponent) (\(String(format: "%.1f", duration))s)")
    }

    /// Security errors for audio processing
    enum AudioSecurityError: Error, LocalizedError {
        case invalidFile
        case tooShort(duration: TimeInterval)
        case tooLong(duration: TimeInterval, maxAllowed: TimeInterval)
        case fileTooLarge(sizeBytes: Int64, maxBytes: Int64)

        var errorDescription: String? {
            switch self {
            case .invalidFile:
                return "Invalid or corrupted audio file"
            case .tooShort(let duration):
                return "Audio too short (\(String(format: "%.1f", duration))s)"
            case .tooLong(let duration, let max):
                return "Audio too long (\(String(format: "%.0f", duration / 60)) min). Max allowed: \(Int(max / 60)) min"
            case .fileTooLarge(let size, let max):
                return "File too large (\(size / 1024 / 1024)MB). Max: \(max / 1024 / 1024)MB"
            }
        }
    }

    /// Transcribe the most recent audio message for a specific chat
    /// Uses database lookup for accurate media identification with duration pre-check
    /// - Parameter chatName: The chat/contact name to find audio for
    /// - Returns: Transcription text or nil if no valid audio found
    func transcribeRecentAudio(forChat chatName: String) async throws -> String? {
        guard settings.audioTranscription && settings.isOpenAIConfigured else {
            print("[Audio] Transcription disabled or OpenAI not configured")
            return nil
        }

        // Create whisper client if needed
        if whisperClient == nil {
            whisperClient = WhisperClient(apiKey: settings.openAIKey)
        }

        // Try database lookup first (more accurate)
        let dbMonitor = WhatsAppDatabaseMonitor()
        if let mediaInfo = dbMonitor.getMostRecentAudio(
            forChat: chatName,
            maxDurationSeconds: Self.maxAudioDurationSeconds
        ) {
            // Database already validated duration, now check file exists
            if let audioURL = mediaInfo.fullPath,
               FileManager.default.fileExists(atPath: audioURL.path) {
                print("[Audio] Found via database: \(audioURL.lastPathComponent)")

                // Pre-check: Use database duration if available (faster than loading file)
                if let dbDuration = mediaInfo.durationSeconds {
                    if dbDuration > Self.maxAudioDurationSeconds {
                        print("[Audio] Database reports audio too long: \(String(format: "%.0f", dbDuration))s")
                        return "[Audio message too long to transcribe - skipped for security]"
                    }
                    if dbDuration < Self.minAudioDurationSeconds {
                        print("[Audio] Database reports audio too short: \(String(format: "%.1f", dbDuration))s")
                        return nil
                    }
                    print("[Audio] Database duration: \(String(format: "%.1f", dbDuration))s - within limits")
                }

                // Additional file validation (size check)
                let maxFileSizeBytes: Int64 = 25 * 1024 * 1024
                if mediaInfo.fileSize > maxFileSizeBytes {
                    print("[Audio] File too large: \(mediaInfo.fileSize / 1024 / 1024)MB")
                    throw AudioSecurityError.fileTooLarge(sizeBytes: mediaInfo.fileSize, maxBytes: maxFileSizeBytes)
                }

                return try await transcribeFile(at: audioURL)
            } else {
                print("[Audio] Database path not accessible, falling back to file search")
            }
        }

        // Fallback to file system search
        return try await transcribeRecentAudio()
    }

    /// Transcribe the most recent audio message (legacy file-based search)
    /// Validates audio duration and file size before processing to prevent abuse
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

        // SECURITY: Validate audio duration and size before processing
        do {
            try await validateAudioFile(url: audioURL)
        } catch let error as AudioSecurityError {
            print("[Audio] Security validation failed: \(error.localizedDescription)")
            // Return a safe message instead of transcription for too-long audio
            if case .tooLong = error {
                return "[Audio message too long to transcribe - skipped for security]"
            }
            throw error
        }

        return try await transcribeFile(at: audioURL)
    }

    /// Transcribe a specific audio file
    private func transcribeFile(at audioURL: URL) async throws -> String? {
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
