import SwiftUI
import UniformTypeIdentifiers

struct MenuBarView: View {
    @StateObject private var viewModel = AppViewModel()
    @StateObject private var settings = SettingsManager.shared
    @State private var showingImporter = false
    @State private var showingLog = false
    @State private var showingDebugLog = false
    @State private var showingSettings = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Header
            HStack {
                Image(systemName: "message.fill")
                    .foregroundColor(.green)
                Text("WhatsApp Auto-Reply")
                    .font(.headline)
            }
            .padding(.bottom, 4)

            // Status indicators
            StatusRow(
                label: "Accessibility",
                isOK: viewModel.hasAccessibilityPermission,
                action: viewModel.hasAccessibilityPermission ? nil : { viewModel.requestAccessibilityPermission() },
                helpText: "System Settings → Privacy & Security → Accessibility → Enable WhatsAppAutoReply"
            )

            StatusRow(
                label: "WhatsApp",
                isOK: viewModel.isWhatsAppRunning
            )

            // Show active AI provider
            if settings.useOpenAI && settings.isOpenAIConfigured {
                StatusRow(
                    label: "OpenAI (\(settings.openAIModel))",
                    isOK: true
                )
            } else {
                StatusRow(
                    label: "Ollama",
                    isOK: viewModel.isOllamaRunning
                )
            }

            StatusRow(
                label: "Monitoring",
                isOK: viewModel.isMonitoring
            )

            Divider()

            // Pending response notification
            if let pending = viewModel.pendingResponse {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Sending in 5s...")
                        .font(.caption)
                        .foregroundColor(.orange)
                    Text(pending.response)
                        .font(.caption)
                        .lineLimit(2)

                    Button("Cancel") {
                        viewModel.cancelPendingResponse()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .controlSize(.small)
                }
                .padding(8)
                .background(Color.orange.opacity(0.1))
                .cornerRadius(8)

                Divider()
            }

            // Contacts list
            if viewModel.contacts.isEmpty {
                Text("No contacts imported")
                    .foregroundColor(.secondary)
                    .font(.caption)
            } else {
                Text("Contacts")
                    .font(.caption)
                    .foregroundColor(.secondary)

                ForEach(viewModel.contacts) { contact in
                    ContactRow(contact: contact) {
                        viewModel.toggleAutoReply(for: contact)
                    }
                }
            }

            Divider()

            // Import progress
            if let progress = viewModel.importProgress {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Importing \(progress.contactName)...")
                        .font(.caption)
                        .foregroundColor(.blue)
                    ProgressView(value: progress.percent)
                        .progressViewStyle(.linear)
                    Text("\(progress.current) / \(progress.total) messages")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                .padding(8)
                .background(Color.blue.opacity(0.1))
                .cornerRadius(8)

                Divider()
            }

            // Actions
            Button("Import Chat Export...") {
                showingImporter = true
            }
            .disabled(viewModel.importProgress != nil)

            Button("View Response Log (\(viewModel.responseLog.count))") {
                showingLog = true
            }

            Button("View Debug Log (\(viewModel.debugLog.count))") {
                showingDebugLog = true
            }

            Button("Dump WhatsApp Tree") {
                viewModel.dumpWhatsAppTree()
                showingDebugLog = true
            }
            .disabled(!viewModel.isWhatsAppRunning)

            Button("Settings...") {
                showingSettings = true
            }

            Divider()

            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
        }
        .padding()
        .frame(width: 280)
        .fileImporter(
            isPresented: $showingImporter,
            allowedContentTypes: [UTType.zip],
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let url = urls.first {
                viewModel.importChatExport(url: url)
            }
        }
        .sheet(isPresented: $showingLog) {
            ResponseLogView(entries: viewModel.responseLog)
        }
        .sheet(isPresented: $showingDebugLog) {
            DebugLogView(entries: viewModel.debugLog)
        }
        .sheet(isPresented: $showingSettings) {
            SettingsView()
        }
    }
}

struct SettingsView: View {
    @StateObject private var settings = SettingsManager.shared
    @Environment(\.dismiss) var dismiss
    @State private var showingAPIKey = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Settings")
                    .font(.headline)
                Spacer()
                Button("Done") { dismiss() }
            }

            Divider()

            // User name
            VStack(alignment: .leading, spacing: 4) {
                Text("Your Name")
                    .font(.caption)
                    .foregroundColor(.secondary)
                TextField("Name", text: $settings.userName)
                    .textFieldStyle(.roundedBorder)
            }

            Divider()

            // AI Provider toggle
            VStack(alignment: .leading, spacing: 8) {
                Text("AI Provider")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Picker("Provider", selection: $settings.useOpenAI) {
                    Text("Ollama (Local)").tag(false)
                    Text("OpenAI (Cloud)").tag(true)
                }
                .pickerStyle(.segmented)
            }

            // OpenAI Settings
            if settings.useOpenAI {
                VStack(alignment: .leading, spacing: 8) {
                    Text("OpenAI API Key")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    HStack {
                        if showingAPIKey {
                            TextField("sk-...", text: $settings.openAIKey)
                                .textFieldStyle(.roundedBorder)
                        } else {
                            SecureField("sk-...", text: $settings.openAIKey)
                                .textFieldStyle(.roundedBorder)
                        }

                        Button(showingAPIKey ? "Hide" : "Show") {
                            showingAPIKey.toggle()
                        }
                        .buttonStyle(.link)
                    }

                    if !settings.isOpenAIConfigured {
                        Text("Enter your API key from platform.openai.com")
                            .font(.caption2)
                            .foregroundColor(.orange)
                    }

                    Text("Model")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    Picker("Model", selection: $settings.openAIModel) {
                        Text("GPT-4o Mini (Recommended)").tag("gpt-4o-mini")
                        Text("GPT-4o (Best)").tag("gpt-4o")
                        Text("GPT-4 Turbo").tag("gpt-4-turbo")
                        Text("GPT-3.5 Turbo (Cheapest)").tag("gpt-3.5-turbo")
                    }
                }
                .padding()
                .background(Color.blue.opacity(0.05))
                .cornerRadius(8)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Using local Ollama with llama3.2:3b")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text("Make sure Ollama is running: ollama serve")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                .padding()
                .background(Color.gray.opacity(0.1))
                .cornerRadius(8)
            }

            Spacer()
        }
        .padding()
        .frame(width: 350, height: 400)
    }
}

struct StatusRow: View {
    let label: String
    let isOK: Bool
    var action: (() -> Void)?
    var helpText: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Circle()
                    .fill(isOK ? Color.green : Color.red)
                    .frame(width: 8, height: 8)
                Text(label)
                    .font(.caption)
                Spacer()

                if !isOK, let action = action {
                    Button("Enable") {
                        action()
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                }
            }

            if !isOK, let help = helpText {
                Text(help)
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
                    .padding(.leading, 16)
            }
        }
    }
}

struct ContactRow: View {
    let contact: Contact
    let onToggle: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Circle()
                    .fill(contact.autoReplyEnabled ? Color.green : Color.gray)
                    .frame(width: 8, height: 8)

                // Group indicator
                if contact.isGroup {
                    Image(systemName: "person.3.fill")
                        .font(.system(size: 10))
                        .foregroundColor(.blue)
                }

                Text(contact.name)
                    .font(.system(size: 13))
                Spacer()

                Toggle("", isOn: Binding(
                    get: { contact.autoReplyEnabled },
                    set: { _ in onToggle() }
                ))
                .toggleStyle(.switch)
                .controlSize(.small)
            }

            // Group hint
            if contact.isGroup && contact.autoReplyEnabled {
                Text("Only responds when @mentioned")
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
                    .padding(.leading, 16)
            }
        }
    }
}

struct ResponseLogView: View {
    let entries: [AppViewModel.ResponseLogEntry]
    @Environment(\.dismiss) var dismiss

    var body: some View {
        VStack {
            HStack {
                Text("Response Log")
                    .font(.headline)
                Spacer()
                Button("Close") { dismiss() }
            }
            .padding()

            if entries.isEmpty {
                Text("No responses sent yet")
                    .foregroundColor(.secondary)
                    .padding()
            } else {
                List(entries) { entry in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(entry.contactName)
                                .font(.caption)
                                .bold()
                            Spacer()
                            Text(entry.timestamp, style: .time)
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                        Text("<- \(entry.incomingMessage)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text("-> \(entry.response)")
                            .font(.caption)
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .frame(width: 400, height: 300)
    }
}

struct DebugLogView: View {
    let entries: [AppViewModel.DebugLogEntry]
    @Environment(\.dismiss) var dismiss

    private let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    var body: some View {
        VStack {
            HStack {
                Text("Debug Log")
                    .font(.headline)
                Spacer()
                Button("Close") { dismiss() }
            }
            .padding()

            if entries.isEmpty {
                Text("No log entries yet")
                    .foregroundColor(.secondary)
                    .padding()
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(entries) { entry in
                            HStack(alignment: .top, spacing: 8) {
                                Text(timeFormatter.string(from: entry.timestamp))
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundColor(.secondary)
                                Text(entry.message)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundColor(entry.isError ? .red : .primary)
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(entry.isError ? Color.red.opacity(0.1) : Color.clear)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .frame(width: 500, height: 400)
    }
}
