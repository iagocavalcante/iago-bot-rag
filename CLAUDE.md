# WhatsApp Auto Reply

macOS menu bar app that auto-responds to WhatsApp Desktop messages using AI, mimicking your personal writing style.

## Codebase Overview

A Swift/SwiftUI application with 37 source files organized into clear modules.

**Stack**: Swift 5.9, SwiftUI, SQLite.swift, macOS 13.0+

**Structure**:
- `Sources/WhatsAppAutoReply/` - Main app code
  - `Monitor/` - WhatsApp detection (Accessibility API or SQLite)
  - `Ollama/` - AI clients (Ollama, OpenAI, Maritaca, Vision, Whisper)
  - `RAG/` - Semantic search with embeddings
  - `Services/` - Core logic (ResponseGenerator, StyleAnalyzer, etc.)
  - `Views/` - SwiftUI menu bar interface
- `Tests/` - Unit tests

For detailed architecture, see [docs/CODEBASE_MAP.md](docs/CODEBASE_MAP.md).

## Quick Reference

### Build & Run
```bash
swift build
swift run
swift test
```

### Key Files
- `ResponseGenerator.swift` - Core AI response orchestration (400+ lines)
- `StyleAnalyzer.swift` - Extract 40+ writing style metrics
- `WhatsAppMonitor.swift` - Accessibility-based message detection
- `AppViewModel.swift` - Main state management

### Data Locations
- App DB: `~/Library/Application Support/WhatsAppAutoReply/data.sqlite`
- Embeddings: `~/Library/Application Support/WhatsAppAutoReply/embeddings.json`
- WhatsApp DB: `~/Library/Group Containers/group.net.whatsapp.WhatsApp.shared/ChatStorage.sqlite`

## Key Patterns

- **Singletons**: DatabaseManager, RAGManager, SettingsManager (`.shared`)
- **@MainActor**: All UI code (AppViewModel, Views)
- **Async/await**: Network operations
- **Progress callbacks**: Long operations (import, embeddings)

## Security

- Input sanitization for prompt injection
- Output validation (block AI self-references)
- Group name trick detection
- PII request deflection
