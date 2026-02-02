import Foundation

/// Service for analyzing WhatsApp images and stickers
class ImageAnalysisService {
    static let shared = ImageAnalysisService()

    private let settings = SettingsManager.shared
    private var visionClient: VisionClient?

    // MARK: - Security: File Size Limits

    /// Maximum image file size to analyze (10MB)
    static let maxImageSizeBytes: Int64 = 10 * 1024 * 1024

    private init() {}

    /// Analyze the most recent image/sticker for a specific chat
    /// Uses database lookup for accurate media identification
    /// - Parameter chatName: The chat/contact name to find image for
    /// - Returns: Generated response or nil if no valid image found
    func analyzeRecentImage(forChat chatName: String) async throws -> String? {
        guard settings.imageAnalysis && settings.isOpenAIConfigured else {
            print("[Image] Analysis disabled or OpenAI not configured")
            return nil
        }

        // Create vision client if needed
        if visionClient == nil {
            // Use gpt-4o-mini for cost efficiency (still has vision)
            visionClient = VisionClient(apiKey: settings.openAIKey, model: "gpt-4o-mini")
        }

        // Try database lookup first (more accurate)
        let dbMonitor = WhatsAppDatabaseMonitor()
        if let mediaInfo = dbMonitor.getMostRecentImage(forChat: chatName) {
            // Check file exists and size
            if let imageURL = mediaInfo.fullPath,
               FileManager.default.fileExists(atPath: imageURL.path) {
                print("[Image] Found via database: \(imageURL.lastPathComponent) (type: \(mediaInfo.mediaType.description))")

                // Security: Check file size
                if mediaInfo.fileSize > Self.maxImageSizeBytes {
                    print("[Image] File too large: \(mediaInfo.fileSize / 1024 / 1024)MB (max: \(Self.maxImageSizeBytes / 1024 / 1024)MB)")
                    return nil
                }

                return try await analyzeImage(at: imageURL)
            } else {
                print("[Image] Database path not accessible, falling back to file search")
            }
        }

        // Fallback to file system search
        return try await analyzeRecentImage()
    }

    /// Analyze the most recent image/sticker (legacy file-based search)
    func analyzeRecentImage() async throws -> String? {
        guard settings.imageAnalysis && settings.isOpenAIConfigured else {
            print("[Image] Analysis disabled or OpenAI not configured")
            return nil
        }

        // Create vision client if needed
        if visionClient == nil {
            // Use gpt-4o-mini for cost efficiency (still has vision)
            visionClient = VisionClient(apiKey: settings.openAIKey, model: "gpt-4o-mini")
        }

        // Try to find the most recent image file
        guard let imageURL = findMostRecentImageFile() else {
            print("[Image] No recent image file found")
            return nil
        }

        print("[Image] Found image: \(imageURL.lastPathComponent)")

        // Security: Check file size
        if let fileSize = try? FileManager.default.attributesOfItem(atPath: imageURL.path)[.size] as? Int64,
           fileSize > Self.maxImageSizeBytes {
            print("[Image] File too large: \(fileSize / 1024 / 1024)MB (max: \(Self.maxImageSizeBytes / 1024 / 1024)MB)")
            return nil
        }

        return try await analyzeImage(at: imageURL)
    }

    /// Analyze a specific image file
    private func analyzeImage(at imageURL: URL) async throws -> String? {
        do {
            let imageData = try Data(contentsOf: imageURL)
            let analysis = try await visionClient!.analyzeStickerForReaction(imageData: imageData)

            print("[Image] Analysis: \(analysis.description) (mood: \(analysis.mood))")

            let response = analysis.generateResponse()
            print("[Image] Generated response: \(response)")

            return response
        } catch {
            print("[Image] Analysis failed: \(error)")
            throw error
        }
    }

    /// Find the most recent image file from WhatsApp
    private func findMostRecentImageFile() -> URL? {
        let fileManager = FileManager.default
        let homeDir = fileManager.homeDirectoryForCurrentUser

        // WhatsApp Desktop stores images in various locations
        let possiblePaths = [
            // WhatsApp Group Container (most common)
            homeDir.appendingPathComponent("Library/Group Containers/group.net.whatsapp.WhatsApp.shared/Message/Media"),
            // Stickers folder
            homeDir.appendingPathComponent("Library/Group Containers/group.net.whatsapp.WhatsApp.shared/Stickers"),
            // Alternative WhatsApp paths
            homeDir.appendingPathComponent("Library/Application Support/WhatsApp/Media"),
            homeDir.appendingPathComponent("Library/Containers/desktop.WhatsApp/Data/Library/Application Support/WhatsApp/Media"),
        ]

        let imageExtensions = Set(["jpg", "jpeg", "png", "gif", "webp", "heic"])
        let cutoffTime = Date().addingTimeInterval(-30) // Only files from last 30 seconds

        var bestMatch: (url: URL, date: Date)?

        for basePath in possiblePaths {
            guard fileManager.fileExists(atPath: basePath.path) else { continue }

            if let match = findMostRecentImageIn(directory: basePath, extensions: imageExtensions, after: cutoffTime) {
                if bestMatch == nil || match.date > bestMatch!.date {
                    bestMatch = match
                }
            }
        }

        return bestMatch?.url
    }

    private func findMostRecentImageIn(directory: URL, extensions: Set<String>, after cutoff: Date) -> (url: URL, date: Date)? {
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

    /// Check if image analysis is available
    var isAvailable: Bool {
        settings.imageAnalysis && settings.isOpenAIConfigured
    }
}
