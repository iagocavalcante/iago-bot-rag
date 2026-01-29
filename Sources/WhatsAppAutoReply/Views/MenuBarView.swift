import SwiftUI
import UniformTypeIdentifiers

struct MenuBarView: View {
    @StateObject private var viewModel = AppViewModel()
    @State private var showingImporter = false
    @State private var showingLog = false
    @State private var showingDebugLog = false

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

            StatusRow(
                label: "Ollama",
                isOK: viewModel.isOllamaRunning
            )

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
        HStack {
            Circle()
                .fill(contact.autoReplyEnabled ? Color.green : Color.gray)
                .frame(width: 8, height: 8)
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
