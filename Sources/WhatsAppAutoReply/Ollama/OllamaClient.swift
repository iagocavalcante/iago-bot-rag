import Foundation

class OllamaClient {
    private let baseURL: URL
    private let model: String
    private let session: URLSession

    init(baseURL: URL = URL(string: "http://localhost:11434")!, model: String = "llama3.2:3b") {
        self.baseURL = baseURL
        self.model = model
        self.session = URLSession.shared
    }

    func generateResponse(prompt: String) async throws -> String {
        let url = baseURL.appendingPathComponent("api/generate")

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 30

        let body: [String: Any] = [
            "model": model,
            "prompt": prompt,
            "stream": false,
            "options": [
                "temperature": 0.7,
                "num_predict": 100
            ]
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw OllamaError.invalidResponse
        }

        guard httpResponse.statusCode == 200 else {
            throw OllamaError.httpError(httpResponse.statusCode)
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let responseText = json["response"] as? String else {
            throw OllamaError.parseError
        }

        return responseText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func buildPrompt(contactName: String, examples: [Message], newMessage: String, userName: String = "Iago Cavalcante") -> String {
        var prompt = """
        You are \(userName). Respond exactly as he would based on these example conversations.
        Your responses should be in Portuguese (Brazilian), casual, short (1-2 sentences max).
        Use informal spelling, "kkkk" for laughing, and emojis when appropriate.
        Never explain yourself - just respond naturally.

        Example conversations with \(contactName):

        """

        // Group messages into conversation pairs
        var i = 0
        while i < examples.count - 1 {
            if examples[i].sender == .contact && examples[i + 1].sender == .user {
                prompt += "\(contactName): \(examples[i].content)\n"
                prompt += "\(userName): \(examples[i + 1].content)\n\n"
            }
            i += 1
        }

        prompt += """

        Now respond to this new message in the same style:
        \(contactName): \(newMessage)
        \(userName):
        """

        return prompt
    }

    func isAvailable() async -> Bool {
        let url = baseURL.appendingPathComponent("api/tags")
        var request = URLRequest(url: url)
        request.timeoutInterval = 5

        do {
            let (_, response) = try await session.data(for: request)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }

    enum OllamaError: Error {
        case invalidResponse
        case httpError(Int)
        case parseError
        case notRunning
    }
}
