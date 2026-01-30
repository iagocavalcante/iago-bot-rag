import Foundation

/// Client for Maritaca AI (Sabiá models) - Brazilian Portuguese LLM
/// API is OpenAI-compatible, optimized for Portuguese
class MaritacaClient {
    private let apiKey: String
    private let model: String
    private let baseURL = URL(string: "https://chat.maritaca.ai/api/chat/completions")!
    private let session: URLSession

    init(apiKey: String, model: String = "sabia-3") {
        self.apiKey = apiKey
        self.model = model

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 120
        self.session = URLSession(configuration: config)
    }

    func generateResponse(prompt: String, systemPrompt: String? = nil) async throws -> String {
        var messages: [[String: Any]] = []

        // Add system prompt if provided
        if let system = systemPrompt {
            messages.append([
                "role": "system",
                "content": system
            ])
        }

        // Add user message
        messages.append([
            "role": "user",
            "content": prompt
        ])

        let body: [String: Any] = [
            "model": model,
            "messages": messages,
            "max_tokens": 150,
            "temperature": 0.7,
            "top_p": 0.9
        ]

        var request = URLRequest(url: baseURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw MaritacaError.invalidResponse
        }

        guard httpResponse.statusCode == 200 else {
            if let errorJson = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let error = errorJson["error"] as? [String: Any],
               let message = error["message"] as? String {
                throw MaritacaError.apiError(message)
            }
            throw MaritacaError.httpError(httpResponse.statusCode)
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let firstChoice = choices.first,
              let message = firstChoice["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw MaritacaError.parseError
        }

        return content.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    enum MaritacaError: Error, LocalizedError {
        case invalidResponse
        case httpError(Int)
        case parseError
        case apiError(String)

        var errorDescription: String? {
            switch self {
            case .invalidResponse: return "Invalid response from Maritaca"
            case .httpError(let code): return "HTTP error: \(code)"
            case .parseError: return "Failed to parse Maritaca response"
            case .apiError(let msg): return "Maritaca API error: \(msg)"
            }
        }
    }
}

// MARK: - Available Models

extension MaritacaClient {
    /// Available Maritaca models
    static let availableModels = [
        "sabia-3",          // Latest, best quality for Portuguese
        "sabia-2-small"     // Smaller, faster
    ]

    /// Model descriptions for UI
    static let modelDescriptions: [String: String] = [
        "sabia-3": "Best quality for Portuguese (recommended)",
        "sabia-2-small": "Faster, cheaper"
    ]
}
