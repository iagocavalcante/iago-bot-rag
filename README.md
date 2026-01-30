# WhatsApp Auto-Reply Bot

A macOS menu bar application that automatically responds to WhatsApp messages using AI, mimicking your personal writing style based on your chat history.

## Features

- **Style Mimicking**: Learns your writing style from exported chat history
- **Multiple AI Providers**: Supports both local Ollama and OpenAI API
- **RAG (Retrieval Augmented Generation)**: Uses semantic search to find similar past conversations for better context
- **Smart Response**: Intelligently decides when to respond (skips acknowledgments, late-night messages)
- **Group Support**: Detects group chats and only responds when mentioned
- **Per-Contact Control**: Enable/disable auto-reply for individual contacts
- **5-Second Cancel Window**: Review and cancel responses before they're sent

## Requirements

- macOS 13.0+
- WhatsApp Desktop app
- Accessibility permissions (for reading/sending messages)
- Either:
  - [Ollama](https://ollama.ai) running locally with `llama3.2:3b` model, OR
  - OpenAI API key

## Installation

1. Clone the repository:
```bash
git clone https://github.com/IagoCavalcante/iago-bot-rag.git
cd iago-bot-rag
```

2. Build the project:
```bash
swift build -c release
```

3. Run the app:
```bash
.build/release/WhatsAppAutoReply
```

4. Grant Accessibility permissions when prompted:
   - System Settings → Privacy & Security → Accessibility → Enable WhatsAppAutoReply

## Usage

1. **Import Chat History**: Export a chat from WhatsApp (Settings → Chats → Export Chat → Without Media) and import the `.zip` file
2. **Configure AI Provider**: Choose between Ollama (local) or OpenAI (cloud) in Settings
3. **Enable Auto-Reply**: Toggle auto-reply for specific contacts
4. **Monitor**: The app will detect new messages and generate responses automatically

## Security Best Practices

### API Key Storage

⚠️ **Important**: The current implementation stores the OpenAI API key in UserDefaults. For production use, consider:

- Using macOS Keychain for secure credential storage
- Implementing environment variable configuration
- Never committing API keys to version control

```swift
// Recommended: Use Keychain instead of UserDefaults
// See: https://developer.apple.com/documentation/security/keychain_services
```

### Prompt Injection Protection

The app includes several layers of protection against prompt injection attacks:

1. **Input Sanitization**: Dangerous patterns are filtered from incoming messages:
   - "ignore all", "ignore previous", "new instructions"
   - System prompt manipulation attempts
   - Code injection patterns (`\`\`\``, `---`, `###`)

2. **Output Validation**: Responses are checked for suspicious content:
   - AI self-references ("As an AI", "I cannot")
   - JSON/code output attempts
   - System information leakage

3. **Length Limits**: Both input (500 chars) and output (200 chars) are limited

### Privacy Considerations

- **Local Processing Option**: Use Ollama for completely local AI processing
- **No Cloud Storage**: Chat history is stored only in local SQLite database
- **Embeddings Privacy**: When using RAG with OpenAI, message content is sent for embedding generation

### Accessibility API Usage

The app uses macOS Accessibility APIs which require explicit user permission. The app:
- Only reads from WhatsApp Desktop window
- Does not access other applications
- Does not log or transmit accessibility data externally

### Recommendations for Production Use

1. **Rotate API Keys**: Regularly rotate your OpenAI API key
2. **Monitor Usage**: Check OpenAI dashboard for unexpected API usage
3. **Review Responses**: Use the Response Log to audit what the bot sends
4. **Limit Contacts**: Only enable auto-reply for trusted contacts
5. **Test Thoroughly**: Test with non-critical conversations first

## Configuration

### Settings

| Setting | Description |
|---------|-------------|
| Your Name | Used in prompts to identify your messages |
| AI Provider | Ollama (local) or OpenAI (cloud) |
| OpenAI Model | gpt-4o-mini, gpt-4o, gpt-4-turbo, gpt-3.5-turbo |
| Smart Response | Skip messages that don't need replies |
| Semantic Search (RAG) | Use embeddings for better context matching |

### Environment Variables (Optional)

```bash
# For headless/automated setups
export OPENAI_API_KEY="sk-..."
export WHATSAPP_USER_NAME="Your Name"
```

## Architecture

```
Sources/WhatsAppAutoReply/
├── App/
│   └── WhatsAppAutoReplyApp.swift    # App entry point
├── Monitor/
│   ├── WhatsAppMonitor.swift         # Message detection via Accessibility
│   └── AccessibilityHelper.swift     # AX API wrapper
├── Services/
│   ├── ResponseGenerator.swift       # AI response generation
│   ├── ResponseDecider.swift         # Smart response logic
│   ├── StyleAnalyzer.swift           # Writing style extraction
│   ├── SettingsManager.swift         # App settings
│   └── ChatParser.swift              # Chat export parser
├── RAG/
│   ├── EmbeddingService.swift        # OpenAI embeddings API
│   ├── VectorStore.swift             # Local vector storage
│   └── RAGManager.swift              # RAG orchestration
├── Ollama/
│   ├── OllamaClient.swift            # Local LLM client
│   └── OpenAIClient.swift            # OpenAI API client
├── Models/
│   └── StyleProfile.swift            # Writing style model
├── Database/
│   └── DatabaseManager.swift         # SQLite persistence
├── ViewModels/
│   └── AppViewModel.swift            # UI state management
└── Views/
    └── MenuBarView.swift             # SwiftUI menu bar UI
```

## Known Limitations

- Only works with WhatsApp Desktop (not WhatsApp Web)
- Requires WhatsApp window to be visible (can be in background)
- Media messages (images, stickers, videos) are ignored
- Response quality depends on chat history quantity

## Troubleshooting

### "No accessibility permission"
Grant permission in System Settings → Privacy & Security → Accessibility

### "WhatsApp not found"
Ensure WhatsApp Desktop is running (not WhatsApp Web in browser)

### "Not enough message history"
Import more chat history - the bot needs at least 10 conversation pairs

### "No response generated"
Check that Ollama is running (`ollama serve`) or OpenAI API key is configured

## Contributing

Contributions are welcome! Please:
1. Fork the repository
2. Create a feature branch
3. Submit a pull request

## License

MIT License - see [LICENSE](LICENSE) for details.

## Disclaimer

This tool is for personal use only. Ensure you comply with:
- WhatsApp's Terms of Service
- Local privacy laws and regulations
- Consent requirements for automated messaging

The authors are not responsible for any misuse of this software.
