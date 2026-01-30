import Foundation

class OpenAIClient {
    private let apiKey: String
    private let model: String
    private let session: URLSession
    private let baseURL = URL(string: "https://api.openai.com/v1/chat/completions")!

    init(apiKey: String, model: String = "gpt-4o-mini") {
        self.apiKey = apiKey
        self.model = model
        self.session = URLSession.shared
    }

    func generateResponse(prompt: String, systemPrompt: String? = nil) async throws -> String {
        var request = URLRequest(url: baseURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 30

        var messages: [[String: String]] = []

        if let system = systemPrompt {
            messages.append(["role": "system", "content": system])
        }

        messages.append(["role": "user", "content": prompt])

        let body: [String: Any] = [
            "model": model,
            "messages": messages,
            "max_tokens": 150,
            "temperature": 0.7,
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw OpenAIError.invalidResponse
        }

        guard httpResponse.statusCode == 200 else {
            if let errorJson = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let error = errorJson["error"] as? [String: Any],
               let message = error["message"] as? String {
                throw OpenAIError.apiError(message)
            }
            throw OpenAIError.httpError(httpResponse.statusCode)
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let firstChoice = choices.first,
              let message = firstChoice["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw OpenAIError.parseError
        }

        return content.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func isAvailable() async -> Bool {
        // Just check if API key is set
        return !apiKey.isEmpty
    }

    enum OpenAIError: Error, LocalizedError {
        case invalidResponse
        case httpError(Int)
        case parseError
        case apiError(String)

        var errorDescription: String? {
            switch self {
            case .invalidResponse: return "Invalid response from OpenAI"
            case .httpError(let code): return "HTTP error: \(code)"
            case .parseError: return "Failed to parse OpenAI response"
            case .apiError(let msg): return "OpenAI API error: \(msg)"
            }
        }
    }
}
