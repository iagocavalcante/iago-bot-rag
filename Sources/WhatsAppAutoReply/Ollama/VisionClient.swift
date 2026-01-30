import Foundation

/// Client for OpenAI GPT-4 Vision API - Image Understanding
class VisionClient {
    private let apiKey: String
    private let model: String
    private let baseURL = URL(string: "https://api.openai.com/v1/chat/completions")!
    private let session: URLSession

    init(apiKey: String, model: String = "gpt-4o-mini") {
        self.apiKey = apiKey
        self.model = model

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60
        self.session = URLSession(configuration: config)
    }

    /// Analyze an image and describe it
    func analyzeImage(imageURL: URL, prompt: String) async throws -> String {
        let imageData = try Data(contentsOf: imageURL)
        return try await analyzeImage(imageData: imageData, prompt: prompt)
    }

    /// Analyze image data and describe it
    func analyzeImage(imageData: Data, prompt: String) async throws -> String {
        let base64Image = imageData.base64EncodedString()

        // Detect image type
        let imageType = detectImageType(data: imageData)

        let messages: [[String: Any]] = [
            [
                "role": "user",
                "content": [
                    [
                        "type": "text",
                        "text": prompt
                    ],
                    [
                        "type": "image_url",
                        "image_url": [
                            "url": "data:image/\(imageType);base64,\(base64Image)",
                            "detail": "low" // Use low detail for faster/cheaper analysis
                        ]
                    ]
                ]
            ]
        ]

        let body: [String: Any] = [
            "model": model,
            "messages": messages,
            "max_tokens": 150
        ]

        var request = URLRequest(url: baseURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw VisionError.invalidResponse
        }

        guard httpResponse.statusCode == 200 else {
            if let errorJson = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let error = errorJson["error"] as? [String: Any],
               let message = error["message"] as? String {
                throw VisionError.apiError(message)
            }
            throw VisionError.httpError(httpResponse.statusCode)
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let firstChoice = choices.first,
              let message = firstChoice["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw VisionError.parseError
        }

        return content.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Analyze a sticker/meme and suggest a fun reaction
    func analyzeStickerForReaction(imageData: Data) async throws -> StickerAnalysis {
        let prompt = """
        Analise este sticker/figurinha de WhatsApp e responda em JSON:
        {
            "description": "descrição curta do que mostra (max 20 palavras)",
            "mood": "happy/funny/sad/surprised/angry/love/confused/sarcastic",
            "suggestedEmojis": ["emoji1", "emoji2", "emoji3"],
            "funnyReply": "uma resposta curta e engraçada em português brasileiro (max 15 palavras)"
        }

        Seja criativo e use gírias brasileiras se apropriado!
        """

        let response = try await analyzeImage(imageData: imageData, prompt: prompt)

        // Try to parse JSON from response
        if let jsonData = response.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] {
            return StickerAnalysis(
                description: json["description"] as? String ?? "sticker",
                mood: json["mood"] as? String ?? "funny",
                suggestedEmojis: json["suggestedEmojis"] as? [String] ?? ["😄"],
                funnyReply: json["funnyReply"] as? String
            )
        }

        // Fallback: extract what we can from plain text
        return StickerAnalysis(
            description: response,
            mood: "funny",
            suggestedEmojis: ["😄", "🤣", "👍"],
            funnyReply: nil
        )
    }

    private func detectImageType(data: Data) -> String {
        guard data.count >= 8 else { return "jpeg" }

        let bytes = [UInt8](data.prefix(8))

        // PNG: 89 50 4E 47
        if bytes[0] == 0x89 && bytes[1] == 0x50 && bytes[2] == 0x4E && bytes[3] == 0x47 {
            return "png"
        }
        // GIF: 47 49 46 38
        if bytes[0] == 0x47 && bytes[1] == 0x49 && bytes[2] == 0x46 {
            return "gif"
        }
        // WebP: 52 49 46 46 ... 57 45 42 50
        if bytes[0] == 0x52 && bytes[1] == 0x49 && bytes[2] == 0x46 && bytes[3] == 0x46 {
            return "webp"
        }

        return "jpeg"
    }

    struct StickerAnalysis {
        let description: String
        let mood: String
        let suggestedEmojis: [String]
        let funnyReply: String?

        /// Generate a response based on the analysis
        func generateResponse() -> String {
            if let reply = funnyReply, !reply.isEmpty {
                let emojis = suggestedEmojis.prefix(2).joined()
                return "\(reply) \(emojis)"
            }

            // Fallback responses by mood
            let moodResponses: [String: [String]] = [
                "happy": ["Adorei! 😄", "Que fofura! 🥰", "Haha muito bom! 😊"],
                "funny": ["KKKKKK 🤣", "Rachei! 😂", "Não tankei essa 💀"],
                "sad": ["😢 Força!", "Tô assim também 😔", "Sad demais 🥺"],
                "surprised": ["😱 Nossa!", "Não acredito! 😮", "QUE?! 🤯"],
                "angry": ["Calma! 😅", "Eita! 😬", "Pesado! 💀"],
                "love": ["Ownt! 🥰", "Que amor! ❤️", "Fofura! 💕"],
                "confused": ["???? 🤔", "Não entendi nada 😂", "Hã?! 🫠"],
                "sarcastic": ["Tá bom então 😏", "Sei... 🙄", "Confia! 😂"]
            ]

            let responses = moodResponses[mood] ?? moodResponses["funny"]!
            return responses.randomElement()!
        }
    }

    enum VisionError: Error, LocalizedError {
        case invalidResponse
        case httpError(Int)
        case parseError
        case apiError(String)
        case imageNotFound

        var errorDescription: String? {
            switch self {
            case .invalidResponse: return "Invalid response from Vision API"
            case .httpError(let code): return "HTTP error: \(code)"
            case .parseError: return "Failed to parse response"
            case .apiError(let msg): return "Vision API error: \(msg)"
            case .imageNotFound: return "Image file not found"
            }
        }
    }
}
