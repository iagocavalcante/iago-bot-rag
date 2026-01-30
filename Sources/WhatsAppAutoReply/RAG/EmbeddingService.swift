import Foundation

/// Service for generating text embeddings using OpenAI API
class EmbeddingService {
    private let settings: SettingsManager
    private let session: URLSession
    private let baseURL = URL(string: "https://api.openai.com/v1/embeddings")!

    init(settings: SettingsManager = .shared) {
        self.settings = settings
        self.session = URLSession.shared
    }

    /// Generate embedding for a single text
    func embed(_ text: String) async throws -> [Float] {
        let embeddings = try await embedBatch([text])
        guard let first = embeddings.first else {
            throw EmbeddingError.emptyResponse
        }
        return first
    }

    /// Generate embeddings for multiple texts (more efficient)
    func embedBatch(_ texts: [String]) async throws -> [[Float]] {
        guard settings.isOpenAIConfigured else {
            throw EmbeddingError.apiKeyNotConfigured
        }

        guard !texts.isEmpty else {
            return []
        }

        var request = URLRequest(url: baseURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(settings.openAIKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 60

        let body: [String: Any] = [
            "model": "text-embedding-3-small",
            "input": texts
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw EmbeddingError.invalidResponse
        }

        guard httpResponse.statusCode == 200 else {
            if let errorJson = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let error = errorJson["error"] as? [String: Any],
               let message = error["message"] as? String {
                throw EmbeddingError.apiError(message)
            }
            throw EmbeddingError.httpError(httpResponse.statusCode)
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dataArray = json["data"] as? [[String: Any]] else {
            throw EmbeddingError.parseError
        }

        // Sort by index to maintain order
        let sorted = dataArray.sorted {
            ($0["index"] as? Int ?? 0) < ($1["index"] as? Int ?? 0)
        }

        var embeddings: [[Float]] = []
        for item in sorted {
            guard let embedding = item["embedding"] as? [Double] else {
                throw EmbeddingError.parseError
            }
            embeddings.append(embedding.map { Float($0) })
        }

        return embeddings
    }

    enum EmbeddingError: Error, LocalizedError {
        case apiKeyNotConfigured
        case invalidResponse
        case httpError(Int)
        case parseError
        case apiError(String)
        case emptyResponse

        var errorDescription: String? {
            switch self {
            case .apiKeyNotConfigured: return "OpenAI API key not configured"
            case .invalidResponse: return "Invalid response from OpenAI"
            case .httpError(let code): return "HTTP error: \(code)"
            case .parseError: return "Failed to parse embedding response"
            case .apiError(let msg): return "OpenAI API error: \(msg)"
            case .emptyResponse: return "Empty embedding response"
            }
        }
    }
}
