import Foundation

/// Manages app settings including API keys
class SettingsManager: ObservableObject {
    static let shared = SettingsManager()

    private let defaults = UserDefaults.standard

    // Keys
    private let openAIKeyKey = "openai_api_key"
    private let useOpenAIKey = "use_openai"
    private let openAIModelKey = "openai_model"
    private let userNameKey = "user_name"
    private let smartResponseKey = "smart_response"
    private let useRAGKey = "use_rag"

    /// OpenAI API key (stored in UserDefaults - consider Keychain for production)
    @Published var openAIKey: String {
        didSet {
            defaults.set(openAIKey, forKey: openAIKeyKey)
        }
    }

    /// Whether to use OpenAI instead of Ollama
    @Published var useOpenAI: Bool {
        didSet {
            defaults.set(useOpenAI, forKey: useOpenAIKey)
        }
    }

    /// OpenAI model to use
    @Published var openAIModel: String {
        didSet {
            defaults.set(openAIModel, forKey: openAIModelKey)
        }
    }

    /// User's name for prompts
    @Published var userName: String {
        didSet {
            defaults.set(userName, forKey: userNameKey)
        }
    }

    /// Whether to use smart response decision (skip acknowledgments, check time, etc.)
    @Published var smartResponse: Bool {
        didSet {
            defaults.set(smartResponse, forKey: smartResponseKey)
        }
    }

    /// Whether to use RAG (semantic search) for finding relevant context
    @Published var useRAG: Bool {
        didSet {
            defaults.set(useRAG, forKey: useRAGKey)
        }
    }

    init() {
        self.openAIKey = defaults.string(forKey: openAIKeyKey) ?? ""
        self.useOpenAI = defaults.bool(forKey: useOpenAIKey)
        self.openAIModel = defaults.string(forKey: openAIModelKey) ?? "gpt-4o-mini"
        self.userName = defaults.string(forKey: userNameKey) ?? "Iago Cavalcante"
        self.smartResponse = defaults.object(forKey: smartResponseKey) == nil ? true : defaults.bool(forKey: smartResponseKey)
        self.useRAG = defaults.bool(forKey: useRAGKey)
    }

    /// Check if OpenAI is properly configured
    var isOpenAIConfigured: Bool {
        !openAIKey.isEmpty
    }

    /// Available OpenAI models
    static let availableModels = [
        "gpt-4o-mini",      // Fast, cheap, good
        "gpt-4o",           // Best quality
        "gpt-4-turbo",      // Fast, high quality
        "gpt-3.5-turbo",    // Cheapest
    ]
}
