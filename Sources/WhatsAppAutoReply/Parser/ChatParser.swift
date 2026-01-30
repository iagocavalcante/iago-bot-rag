import Foundation

struct ParsedMessage {
    let timestamp: Date
    let sender: String
    let content: String
}

class ChatParser {
    private let userName: String
    private let dateFormatter4: DateFormatter  // 4-digit year
    private let dateFormatter2: DateFormatter  // 2-digit year

    init(userName: String = "Iago Cavalcante") {
        self.userName = userName

        self.dateFormatter4 = DateFormatter()
        self.dateFormatter4.dateFormat = "dd/MM/yyyy, HH:mm:ss"
        self.dateFormatter4.locale = Locale(identifier: "pt_BR")

        self.dateFormatter2 = DateFormatter()
        self.dateFormatter2.dateFormat = "dd/MM/yy, HH:mm:ss"
        self.dateFormatter2.locale = Locale(identifier: "pt_BR")
    }

    private func parseDate(_ dateStr: String) -> Date? {
        dateFormatter4.date(from: dateStr) ?? dateFormatter2.date(from: dateStr)
    }

    func parseZipFile(at url: URL) throws -> (contactName: String, messages: [ParsedMessage]) {
        // Extract contact name from zip filename
        let filename = url.deletingPathExtension().lastPathComponent
        let contactName = filename.replacingOccurrences(of: "WhatsApp Chat - ", with: "")

        // Unzip and read _chat.txt
        let chatContent = try extractChatFromZip(url)
        let messages = parseChat(chatContent)

        return (contactName, messages)
    }

    /// Parse a zip file that's already in temp directory (no copy needed)
    func parseTempZipFile(at tempZip: URL) -> [ParsedMessage] {
        do {
            let chatContent = try extractFromTempZip(tempZip)
            return parseChat(chatContent)
        } catch {
            print("Parse error: \(error)")
            return []
        }
    }

    /// Parse with logging for debugging
    func parseTempZipFileWithLog(at tempZip: URL) -> ([ParsedMessage], [String]) {
        var log: [String] = []
        log.append("Temp zip path: \(tempZip.path)")
        log.append("File exists: \(FileManager.default.fileExists(atPath: tempZip.path))")

        do {
            let chatContent = try extractFromTempZip(tempZip)
            log.append("Extracted content length: \(chatContent.count) chars")

            // Show first few lines for debugging
            let lines = chatContent.components(separatedBy: .newlines)
            log.append("Total lines: \(lines.count)")
            if let firstLine = lines.first {
                let preview = String(firstLine.prefix(80))
                log.append("First line: \(preview)")
            }

            let messages = parseChat(chatContent)
            log.append("Parsed messages: \(messages.count)")

            return (messages, log)
        } catch {
            log.append("Parse error: \(error)")
            return ([], log)
        }
    }

    private func extractFromTempZip(_ tempZip: URL) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-p", tempZip.path, "_chat.txt"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        try process.run()

        // IMPORTANT: Read data BEFORE waitUntilExit to avoid pipe buffer deadlock
        // When output is large, pipe fills up (64KB), process blocks, but we'd be waiting for exit
        let data = pipe.fileHandleForReading.readDataToEndOfFile()

        process.waitUntilExit()

        guard let content = String(data: data, encoding: .utf8) else {
            throw ParserError.invalidEncoding
        }
        return content
    }

    private func extractChatFromZip(_ zipUrl: URL) throws -> String {
        // Copy to temp directory to avoid sandbox issues with Process
        let tempDir = FileManager.default.temporaryDirectory
        let tempZip = tempDir.appendingPathComponent(UUID().uuidString + ".zip")

        defer {
            try? FileManager.default.removeItem(at: tempZip)
        }

        try FileManager.default.copyItem(at: zipUrl, to: tempZip)
        return try extractFromTempZip(tempZip)
    }

    func parseChat(_ content: String) -> [ParsedMessage] {
        var messages: [ParsedMessage] = []
        let lines = content.components(separatedBy: .newlines)

        // Pattern: [DD/MM/YY or YYYY, HH:MM:SS] Sender: Message
        let pattern = #"^\[(\d{2}/\d{2}/\d{2,4}, \d{2}:\d{2}:\d{2})\] ([^:]+): (.+)$"#
        let regex = try? NSRegularExpression(pattern: pattern, options: [])

        var currentMessage: (date: String, sender: String, content: String)?

        for line in lines {
            let range = NSRange(line.startIndex..., in: line)

            if let match = regex?.firstMatch(in: line, options: [], range: range) {
                // Save previous message if exists
                if let current = currentMessage {
                    if let date = parseDate(current.date) {
                        messages.append(ParsedMessage(
                            timestamp: date,
                            sender: current.sender,
                            content: current.content
                        ))
                    }
                }

                // Parse new message
                let dateRange = Range(match.range(at: 1), in: line)!
                let senderRange = Range(match.range(at: 2), in: line)!
                let contentRange = Range(match.range(at: 3), in: line)!

                let dateStr = String(line[dateRange])
                let sender = String(line[senderRange])
                let content = String(line[contentRange])

                // Skip system messages and media
                if sender.contains("Messages and calls are end-to-end encrypted") ||
                   sender.contains("As mensagens e ligações são protegidas") ||
                   content.contains("<anexado:") ||
                   content.contains("<attached:") ||
                   content.contains("imagem ocultada") ||
                   content.contains("image omitted") {
                    currentMessage = nil
                    continue
                }

                currentMessage = (dateStr, sender, content)
            } else if currentMessage != nil {
                // Continuation of previous message (multiline)
                currentMessage?.content += "\n" + line
            }
        }

        // Don't forget last message
        if let current = currentMessage, let date = parseDate(current.date) {
            messages.append(ParsedMessage(
                timestamp: date,
                sender: current.sender,
                content: current.content
            ))
        }

        return messages
    }

    func convertToMessages(parsed: [ParsedMessage], contactId: Int64, contactName: String) -> [Message] {
        return parsed.map { pm in
            let sender: Message.Sender = pm.sender == userName ? .user : .contact
            return Message(
                contactId: contactId,
                sender: sender,
                content: pm.content,
                timestamp: pm.timestamp
            )
        }
    }

    /// Detect if messages are from a group chat (more than 2 unique senders)
    func isGroupChat(messages: [ParsedMessage]) -> Bool {
        let uniqueSenders = Set(messages.map { $0.sender })
        // In a 1-on-1 chat, there are only 2 senders: you and the contact
        // In a group, there are 3+ senders
        return uniqueSenders.count > 2
    }

    /// Get all unique senders (for group participant list)
    func getUniqueSenders(messages: [ParsedMessage]) -> [String] {
        Array(Set(messages.map { $0.sender })).sorted()
    }

    enum ParserError: Error {
        case invalidEncoding
        case fileNotFound
    }
}
