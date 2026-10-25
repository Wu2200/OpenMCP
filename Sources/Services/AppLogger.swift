import Foundation
import SwiftUI

enum AppLogCategory: String, Codable, CaseIterable {
    case all = "全部"
    case aiRequest = "AI请求"
    case aiStream = "AI流式"
    case aiStop = "流结束/截断"
    case mcpTool = "MCP工具"
    case error = "错误异常"
}

enum AppLogLevel: String, Codable {
    case info = "INFO"
    case warning = "WARN"
    case error = "ERROR"
}

struct AppLogEntry: Identifiable, Codable, Equatable {
    var id: String = UUID().uuidString
    var timestamp: Date = Date()
    var category: AppLogCategory
    var level: AppLogLevel
    var title: String
    var summary: String
    var details: String
    var conversationId: String? = nil
}

@MainActor
final class AppLogManager: ObservableObject {
    static let shared = AppLogManager()

    @Published private(set) var logs: [AppLogEntry] = []
    private let maxLogCount = 250
    private let storageKey = "OpenMCP_AppDiagnosticLogs"

    private init() {
        if let data = UserDefaults.standard.data(forKey: storageKey),
           let decoded = try? JSONDecoder().decode([AppLogEntry].self, from: data) {
            self.logs = decoded
        }
    }

    func log(
        category: AppLogCategory,
        level: AppLogLevel = .info,
        title: String,
        summary: String,
        details: String = "",
        conversationId: String? = nil
    ) {
        let entry = AppLogEntry(
            category: category,
            level: level,
            title: title,
            summary: summary,
            details: details,
            conversationId: conversationId
        )
        logs.insert(entry, at: 0)
        if logs.count > maxLogCount {
            logs.removeSubrange(maxLogCount..<logs.count)
        }
        persist()
    }

    func clearLogs() {
        logs.removeAll()
        UserDefaults.standard.removeObject(forKey: storageKey)
    }

    func exportAllText(filterConversationId: String? = nil) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        let targetLogs = logs.filter { entry in
            guard let cid = filterConversationId else { return true }
            return entry.conversationId == nil || entry.conversationId == cid
        }
        return targetLogs.map { entry in
            var block = "[\(formatter.string(from: entry.timestamp))] [\(entry.level.rawValue)] [\(entry.category.rawValue)] \(entry.title)\n摘要: \(entry.summary)"
            if !entry.details.isEmpty {
                block += "\n详情:\n\(entry.details)"
            }
            return block
        }.joined(separator: "\n\n----------------------------------------\n\n")
    }

    private func persist() {
        let snapshot = Array(logs.prefix(120))
        if let data = try? JSONEncoder().encode(snapshot) {
            UserDefaults.standard.set(data, forKey: storageKey)
        }
    }
}
