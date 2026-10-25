import Foundation
import SwiftUI

enum AppLogCategory: String, Codable, CaseIterable {
    case all = "全部"
    case aiRequest = "AI请求"
    case aiStop = "流结束"
    case aiTruncated = "流截断"
    case mcpTool = "MCP工具"
    case error = "错误异常"

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        switch raw {
        case "全部": self = .all
        case "AI请求", "AI流式": self = .aiRequest
        case "流结束", "流结束/截断": self = .aiStop
        case "流截断": self = .aiTruncated
        case "MCP工具": self = .mcpTool
        case "错误异常": self = .error
        default: self = .aiStop
        }
    }
}

enum AppLogLevel: String, Codable {
    case info = "INFO"
    case warning = "WARN"
    case error = "ERROR"
}

struct AppLogToolItem: Identifiable, Codable, Equatable {
    var id: String = UUID().uuidString
    var timestamp: Date = Date()
    var toolName: String
    var serverName: String
    var elapsed: String
    var isSuccess: Bool
    var summary: String
    var arguments: String
    var outputPreview: String
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
    var conversationTitle: String? = nil
    var turnId: String? = nil
    var turnPrompt: String? = nil
    var stepIndex: Int? = nil
    var toolItems: [AppLogToolItem]? = nil
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
            self.logs = decoded.map { entry in
                var updated = entry
                if updated.category == .aiStop && (updated.level != .info || updated.title.contains("截断") || updated.title.contains("异常断开")) {
                    updated.category = .aiTruncated
                }
                return updated
            }
        }
    }

    func resolvedConversationTitle(for conversationId: String?, fallback: String? = nil) -> String {
        guard let cid = conversationId, !cid.isEmpty else {
            return fallback ?? "全局系统日志"
        }
        if let conv = DataStorage.shared.conversations.first(where: { $0.id == cid }) {
            let trimmed = conv.title.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return trimmed
            }
        }
        if let fb = fallback?.trimmingCharacters(in: .whitespacesAndNewlines), !fb.isEmpty {
            return fb
        }
        return "对话记录"
    }

    @discardableResult
    func log(
        category: AppLogCategory,
        level: AppLogLevel = .info,
        title: String,
        summary: String,
        details: String = "",
        conversationId: String? = nil,
        conversationTitle: String? = nil,
        turnId: String? = nil,
        turnPrompt: String? = nil,
        stepIndex: Int? = nil,
        toolItems: [AppLogToolItem]? = nil
    ) -> String {
        let resolvedTitle = conversationId != nil ? resolvedConversationTitle(for: conversationId, fallback: conversationTitle) : conversationTitle
        let entry = AppLogEntry(
            category: category,
            level: level,
            title: title,
            summary: summary,
            details: details,
            conversationId: conversationId,
            conversationTitle: resolvedTitle,
            turnId: turnId,
            turnPrompt: turnPrompt,
            stepIndex: stepIndex,
            toolItems: toolItems
        )
        logs.insert(entry, at: 0)
        if logs.count > maxLogCount {
            logs.removeSubrange(maxLogCount..<logs.count)
        }
        persist()
        return entry.id
    }

    func updateLog(
        id: String,
        category: AppLogCategory? = nil,
        level: AppLogLevel? = nil,
        title: String? = nil,
        summary: String? = nil,
        details: String? = nil,
        conversationTitle: String? = nil
    ) {
        guard let idx = logs.firstIndex(where: { $0.id == id }) else { return }
        if let category = category {
            logs[idx].category = category
        }
        if let level = level {
            logs[idx].level = level
        }
        if let title = title {
            logs[idx].title = title
        }
        if let summary = summary {
            logs[idx].summary = summary
        }
        if let details = details {
            logs[idx].details = details
        }
        if let conversationTitle = conversationTitle {
            logs[idx].conversationTitle = conversationTitle
        } else if let cid = logs[idx].conversationId {
            logs[idx].conversationTitle = resolvedConversationTitle(for: cid, fallback: logs[idx].conversationTitle)
        }
        logs[idx].timestamp = Date()
        persist()
    }

    func logToolCall(
        conversationId: String?,
        conversationTitle: String? = nil,
        turnId: String?,
        turnPrompt: String? = nil,
        stepIndex: Int? = nil,
        toolName: String,
        serverName: String,
        elapsed: String,
        isSuccess: Bool,
        summary: String,
        arguments: String,
        outputPreview: String
    ) {
        let item = AppLogToolItem(
            toolName: toolName,
            serverName: serverName,
            elapsed: elapsed,
            isSuccess: isSuccess,
            summary: summary,
            arguments: arguments,
            outputPreview: outputPreview
        )
        let resolvedConvTitle = conversationId != nil ? resolvedConversationTitle(for: conversationId, fallback: conversationTitle) : conversationTitle

        if let turnId = turnId,
           let idx = logs.firstIndex(where: { $0.category == .mcpTool && $0.conversationId == conversationId && $0.turnId == turnId }) {
            var currentItems = logs[idx].toolItems ?? []
            currentItems.append(item)
            let totalCount = currentItems.count
            let failCount = currentItems.filter { !$0.isSuccess }.count
            let namesPreview = currentItems.map { $0.toolName }.joined(separator: " → ")

            logs[idx].toolItems = currentItems
            logs[idx].level = failCount > 0 ? .error : .info
            logs[idx].title = totalCount == 1
                ? "MCP 工具调用 [\(toolName)]"
                : "MCP 工具调用汇总 (共 \(totalCount) 次)"
            logs[idx].summary = failCount > 0
                ? "成功 \(totalCount - failCount) 次 · 失败 \(failCount) 次 · \(namesPreview)"
                : "已执行 \(totalCount) 次工具 · \(namesPreview)"
            logs[idx].details = Self.buildAggregatedToolDetails(from: currentItems)
            logs[idx].conversationTitle = resolvedConvTitle
            logs[idx].timestamp = Date()
            persist()
            return
        }

        let singleDetails = Self.buildAggregatedToolDetails(from: [item])
        _ = log(
            category: .mcpTool,
            level: isSuccess ? .info : .error,
            title: "MCP 工具调用 [\(toolName)]",
            summary: summary,
            details: singleDetails,
            conversationId: conversationId,
            conversationTitle: resolvedConvTitle,
            turnId: turnId,
            turnPrompt: turnPrompt,
            stepIndex: stepIndex,
            toolItems: [item]
        )
    }

    private static func buildAggregatedToolDetails(from items: [AppLogToolItem]) -> String {
        items.enumerated().map { idx, item in
            let status = item.isSuccess ? "SUCCESS" : "FAILED"
            return "[#\(idx + 1)] [\(status)] \(item.toolName) (\(item.serverName)) · \(item.elapsed)\nArguments:\n\(item.arguments)\n\nOutput:\n\(item.outputPreview)"
        }.joined(separator: "\n\n----------------------------------------\n\n")
    }

    func clearLogs(forConversationId conversationId: String? = nil) {
        if let cid = conversationId {
            logs.removeAll { $0.conversationId == cid }
            persist()
        } else {
            logs.removeAll()
            UserDefaults.standard.removeObject(forKey: storageKey)
        }
    }

    func exportAllText(filterConversationId: String? = nil) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        let targetLogs = logs.filter { entry in
            guard let cid = filterConversationId else { return true }
            return entry.conversationId == cid
        }
        return targetLogs.map { entry in
            let convTitle = resolvedConversationTitle(for: entry.conversationId, fallback: entry.conversationTitle)
            var block = "[\(formatter.string(from: entry.timestamp))] [\(convTitle)] [\(entry.level.rawValue)] [\(entry.category.rawValue)] \(entry.title)\n摘要: \(entry.summary)"
            if !entry.details.isEmpty {
                block += "\n详情:\n\(entry.details)"
            }
            return block
        }.joined(separator: "\n\n========================================\n\n")
    }

    private func persist() {
        let snapshot = Array(logs.prefix(150))
        if let data = try? JSONEncoder().encode(snapshot) {
            UserDefaults.standard.set(data, forKey: storageKey)
        }
    }
}
