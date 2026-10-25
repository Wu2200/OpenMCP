import Foundation

enum MessageRole: String, Codable, Hashable {
    case system
    case user
    case assistant
    case tool
}

enum AttachmentKind: String, Codable, Hashable {
    case image
    case file
    case longText
}

struct ChatAttachment: Identifiable, Codable, Equatable, Hashable {
    var id: String = UUID().uuidString
    var kind: AttachmentKind
    var fileName: String
    var mimeType: String
    var fileSize: Int
    var imageDataBase64: String? = nil
    var textContent: String? = nil

    var formattedByteSize: String {
        if fileSize < 1024 {
            return "\(fileSize) B"
        } else if fileSize < 1024 * 1024 {
            return String(format: "%.1f KB", Double(fileSize) / 1024.0)
        } else {
            return String(format: "%.2f MB", Double(fileSize) / (1024.0 * 1024.0))
        }
    }

    var characterCount: Int {
        textContent?.count ?? 0
    }

    var lineCount: Int {
        guard let text = textContent, !text.isEmpty else { return 0 }
        return text.components(separatedBy: .newlines).count
    }

    var metadataSummary: String {
        if let text = textContent, !text.isEmpty {
            return "\(text.count) 字符 · \(lineCount) 行 · \(formattedByteSize)"
        }
        return formattedByteSize
    }

    var previewSnippet: String {
        guard let text = textContent else { return "" }
        let lines = text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .prefix(2)
        return lines.joined(separator: " ")
    }

    var iconName: String {
        switch kind {
        case .image:
            return "photo.fill"
        case .longText:
            return "doc.text.fill"
        case .file:
            let lower = fileName.lowercased()
            if lower.hasSuffix(".pdf") {
                return "doc.richtext.fill"
            } else if lower.hasSuffix(".json") || lower.hasSuffix(".js") || lower.hasSuffix(".ts") || lower.hasSuffix(".swift") || lower.hasSuffix(".py") || lower.hasSuffix(".html") || lower.hasSuffix(".css") {
                return "chevron.left.forwardslash.chevron.right"
            }
            return "doc.fill"
        }
    }

    static func makeLongTextAttachment(from text: String, index: Int? = nil) -> ChatAttachment {
        let firstLine = text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first(where: { !$0.isEmpty }) ?? "长文本内容"
        let sanitized = firstLine
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
            .prefix(14)
        let baseName = sanitized.isEmpty ? "长文本内容" : String(sanitized)
        let suffix = index.map { "_\($0)" } ?? ""
        return ChatAttachment(
            kind: .longText,
            fileName: "\(baseName)\(suffix).txt",
            mimeType: "text/plain",
            fileSize: text.utf8.count,
            textContent: text
        )
    }

    static func shouldPackageAsLongText(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count >= 400 {
            return true
        }
        let lineCount = trimmed.components(separatedBy: .newlines).count
        return lineCount >= 12
    }
}

struct ToolCallItem: Identifiable, Codable, Equatable, Hashable {
    var id: String
    var name: String
    var arguments: String
    var result: String?
    var isExecuting: Bool = false
    var error: String?
}

struct ChatMessage: Identifiable, Codable, Equatable, Hashable {
    var id: String = UUID().uuidString
    var role: MessageRole
    var content: String
    var attachments: [ChatAttachment]? = nil
    var toolCalls: [ToolCallItem]?
    var toolCallId: String?
    var createdAt: Date = Date()
}
