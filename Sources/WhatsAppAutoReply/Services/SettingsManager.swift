import Foundation

/// AI Provider options
enum AIProvider: String, CaseIterable {
    case ollama = "ollama"
    case openai = "openai"
    case maritaca = "maritaca"

    var displayName: String {
        switch self {
        case .ollama: return "Ollama (Local)"
        case .openai: return "OpenAI (Cloud)"
        case .maritaca: return "Maritaca AI (Portuguese)"
        }
    }
}

/// Monitoring method options
enum MonitoringMethod: String, CaseIterable {
    case accessibility = "accessibility"
    case database = "database"

    var displayName: String {
        switch self {
        case .accessibility: return "Accessibility API"
        case .database: return "Database (SQLite)"
        }
    }

    var description: String {
        switch self {
        case .accessibility: return "Screen reading via macOS Accessibility"
        case .database: return "Direct read from WhatsApp database"
        }
    }
}

/// Manages app settings including API keys
class SettingsManager: ObservableObject {
    static let shared = SettingsManager()

    private let defaults = UserDefaults.standard

    // Keys
    private let openAIKeyKey = "openai_api_key"
    private let openAIModelKey = "openai_model"
    private let maritacaKeyKey = "maritaca_api_key"
    private let maritacaModelKey = "maritaca_model"
    private let aiProviderKey = "ai_provider"
    private let userNameKey = "user_name"
    private let smartResponseKey = "smart_response"
    private let useRAGKey = "use_rag"
    private let groupTopicParticipationKey = "group_topic_participation"
    private let audioTranscriptionKey = "audio_transcription"
    private let imageAnalysisKey = "image_analysis"
    private let useReplyModeKey = "use_reply_mode"
    private let monitoringMethodKey = "monitoring_method"
    private let ignoreGroupNameTricksKey = "ignore_group_name_tricks"

    // Legacy key for migration
    private let useOpenAIKey = "use_openai"

    // MARK: - AI Provider Selection

    /// Selected AI provider
    @Published var aiProvider: AIProvider {
        didSet {
            defaults.set(aiProvider.rawValue, forKey: aiProviderKey)
        }
    }

    // MARK: - OpenAI Settings

    /// OpenAI API key
    @Published var openAIKey: String {
        didSet {
            defaults.set(openAIKey, forKey: openAIKeyKey)
        }
    }

    /// OpenAI model to use
    @Published var openAIModel: String {
        didSet {
            defaults.set(openAIModel, forKey: openAIModelKey)
        }
    }

    // MARK: - Maritaca Settings

    /// Maritaca API key
    @Published var maritacaKey: String {
        didSet {
            defaults.set(maritacaKey, forKey: maritacaKeyKey)
        }
    }

    /// Maritaca model to use
    @Published var maritacaModel: String {
        didSet {
            defaults.set(maritacaModel, forKey: maritacaModelKey)
        }
    }

    // MARK: - General Settings

    /// User's name for prompts
    @Published var userName: String {
        didSet {
            defaults.set(userName, forKey: userNameKey)
        }
    }

    /// Whether to use smart response decision
    @Published var smartResponse: Bool {
        didSet {
            defaults.set(smartResponse, forKey: smartResponseKey)
        }
    }

    /// Whether to use RAG (semantic search)
    @Published var useRAG: Bool {
        didSet {
            defaults.set(useRAG, forKey: useRAGKey)
        }
    }

    /// Whether to participate in group chats based on topic relevance
    @Published var groupTopicParticipation: Bool {
        didSet {
            defaults.set(groupTopicParticipation, forKey: groupTopicParticipationKey)
        }
    }

    /// Whether to transcribe audio messages using Whisper
    @Published var audioTranscription: Bool {
        didSet {
            defaults.set(audioTranscription, forKey: audioTranscriptionKey)
        }
    }

    /// Whether to analyze images/stickers using GPT-4 Vision
    @Published var imageAnalysis: Bool {
        didSet {
            defaults.set(imageAnalysis, forKey: imageAnalysisKey)
        }
    }

    /// Whether to use WhatsApp's native Reply feature (quotes the message)
    @Published var useReplyMode: Bool {
        didSet {
            defaults.set(useReplyMode, forKey: useReplyModeKey)
        }
    }

    /// Monitoring method: accessibility API or database
    @Published var monitoringMethod: MonitoringMethod {
        didSet {
            defaults.set(monitoringMethod.rawValue, forKey: monitoringMethodKey)
        }
    }

    /// Whether to silently ignore suspicious group name changes (instead of responding with humor)
    @Published var ignoreGroupNameTricks: Bool {
        didSet {
            defaults.set(ignoreGroupNameTricks, forKey: ignoreGroupNameTricksKey)
        }
    }

    // MARK: - Initialization

    init() {
        self.openAIKey = defaults.string(forKey: openAIKeyKey) ?? ""
        self.openAIModel = defaults.string(forKey: openAIModelKey) ?? "gpt-4o-mini"
        self.maritacaKey = defaults.string(forKey: maritacaKeyKey) ?? ""
        self.maritacaModel = defaults.string(forKey: maritacaModelKey) ?? "sabia-3"
        self.userName = defaults.string(forKey: userNameKey) ?? "Iago Cavalcante"
        self.smartResponse = defaults.object(forKey: smartResponseKey) == nil ? true : defaults.bool(forKey: smartResponseKey)
        self.useRAG = defaults.bool(forKey: useRAGKey)
        self.groupTopicParticipation = defaults.bool(forKey: groupTopicParticipationKey)
        self.audioTranscription = defaults.bool(forKey: audioTranscriptionKey)
        self.imageAnalysis = defaults.bool(forKey: imageAnalysisKey)
        self.useReplyMode = defaults.bool(forKey: useReplyModeKey)
        self.ignoreGroupNameTricks = defaults.object(forKey: ignoreGroupNameTricksKey) == nil ? true : defaults.bool(forKey: ignoreGroupNameTricksKey)  // Default to true (ignore)

        // Monitoring method
        if let methodRaw = defaults.string(forKey: monitoringMethodKey),
           let method = MonitoringMethod(rawValue: methodRaw) {
            self.monitoringMethod = method
        } else {
            self.monitoringMethod = .accessibility // Default to accessibility
        }

        // Migrate from legacy useOpenAI setting
        if let providerRaw = defaults.string(forKey: aiProviderKey),
           let provider = AIProvider(rawValue: providerRaw) {
            self.aiProvider = provider
        } else if defaults.bool(forKey: useOpenAIKey) {
            self.aiProvider = .openai
        } else {
            self.aiProvider = .ollama
        }
    }

    // MARK: - Convenience Properties

    /// Check if OpenAI is properly configured
    var isOpenAIConfigured: Bool {
        !openAIKey.isEmpty
    }

    /// Check if Maritaca is properly configured
    var isMaritacaConfigured: Bool {
        !maritacaKey.isEmpty
    }

    /// Check if any cloud API is configured (for RAG embeddings)
    var hasCloudAPIConfigured: Bool {
        isOpenAIConfigured || isMaritacaConfigured
    }

    /// Whether currently using OpenAI (for backward compatibility)
    var useOpenAI: Bool {
        aiProvider == .openai
    }

    /// Whether currently using Maritaca
    var useMaritaca: Bool {
        aiProvider == .maritaca
    }

    /// Get current provider's display name
    var currentProviderName: String {
        switch aiProvider {
        case .ollama:
            return "Ollama (llama3.2:3b)"
        case .openai:
            return "OpenAI (\(openAIModel))"
        case .maritaca:
            return "Maritaca (\(maritacaModel))"
        }
    }

    // MARK: - Available Models

    /// Available OpenAI models
    static let openAIModels = [
        "gpt-4o-mini",      // Fast, cheap, good
        "gpt-4o",           // Best quality
        "gpt-4-turbo",      // Fast, high quality
        "gpt-3.5-turbo",    // Cheapest
    ]

    /// Available Maritaca models
    static let maritacaModels = [
        "sabia-3",          // Best for Portuguese
        "sabia-2-small",    // Faster, cheaper
    ]
}
