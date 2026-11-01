import Combine
import Foundation
import SwiftUI

struct AssistantTurnStep: Identifiable, Equatable {
    var id: String
    var content: String
    var reasoningContent: String
    var toolCalls: [ToolCallItem]

    var trimmedContent: String {
        content.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var trimmedReasoning: String {
        reasoningContent.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var isEmptyPlaceholder: Bool {
        trimmedContent.isEmpty && trimmedReasoning.isEmpty && toolCalls.isEmpty
    }
}

struct MessageDisplayTurn: Identifiable, Equatable {
    var id: String
    var role: MessageRole
    var primaryMessageId: String
    var content: String
    var reasoningContent: String
    var attachments: [ChatAttachment]
    var toolCalls: [ToolCallItem]
    var steps: [AssistantTurnStep]
    var createdAt: Date
    var underlyingMessageIds: [String]

    var isCompletelyEmptyAssistantTurn: Bool {
        role == .assistant
            && content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && reasoningContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && toolCalls.isEmpty
            && attachments.isEmpty
    }
}

@MainActor
final class ChatTurnProjectionStore: ObservableObject {
    @Published private(set) var turns: [MessageDisplayTurn]
    @Published private(set) var conversationTitle: String
    @Published private(set) var selectedProfileId: String?
    @Published private(set) var selectedModelName: String?
    @Published private(set) var rawMessageCount: Int

    private struct QuickStamp: Equatable {
        let title: String
        let selectedProfileId: String?
        let selectedModelName: String?
        let messageCount: Int
        let firstMessageId: String?
        let lastMessageId: String?
        let contentChecksum: UInt64

        init(_ conversation: Conversation) {
            self.title = conversation.title
            self.selectedProfileId = conversation.selectedProfileId
            self.selectedModelName = conversation.selectedModelName
            self.messageCount = conversation.messages.count
            self.firstMessageId = conversation.messages.first?.id
            self.lastMessageId = conversation.messages.last?.id

            var hash: UInt64 = 14695981039346656037
            func mix(_ value: UInt64) {
                hash ^= value
                hash &*= 1099511628211
            }

            for msg in conversation.messages {
                mix(UInt64(bitPattern: Int64(msg.id.hashValue)))
                mix(UInt64(msg.content.utf8.count))
                if let lastByte = msg.content.utf8.last {
                    mix(UInt64(lastByte))
                }
                mix(UInt64(msg.reasoningContent?.utf8.count ?? 0))
                mix(UInt64(msg.attachments?.count ?? 0))
                if let calls = msg.toolCalls {
                    mix(UInt64(calls.count))
                    for c in calls {
                        mix(c.isExecuting ? 1 : 0)
                        mix(UInt64(c.result?.utf8.count ?? 0))
                        mix(c.error != nil ? 2 : 0)
                    }
                }
            }
            self.contentChecksum = hash
        }
    }

    private struct CachedEntry {
        let stamp: QuickStamp
        let turns: [MessageDisplayTurn]
    }

    private static var projectionCache: [String: CachedEntry] = [:]

    private let conversationId: String
    private var lastStamp: QuickStamp?
    private var conversationsCancellable: AnyCancellable?

    init(conversationId: String) {
        self.conversationId = conversationId
        let initialConv = DataStorage.shared.conversations.first(where: { $0.id == conversationId })
        self.conversationTitle = initialConv?.title ?? "对话"
        self.selectedProfileId = initialConv?.selectedProfileId
        self.selectedModelName = initialConv?.selectedModelName
        self.rawMessageCount = initialConv?.messages.count ?? 0

        if let initialConv {
            let stamp = QuickStamp(initialConv)
            self.lastStamp = stamp
            if let cached = Self.projectionCache[conversationId], cached.stamp == stamp {
                self.turns = cached.turns
            } else {
                let projected = Self.project(initialConv.messages)
                self.turns = projected
                Self.storeCache(conversationId: conversationId, stamp: stamp, turns: projected)
            }
        } else {
            self.turns = []
        }

        conversationsCancellable = DataStorage.shared.$conversations
            .dropFirst()
            .sink { [weak self] conversations in
                let applyUpdate = { [weak self] in
                    guard let self else { return }
                    self.ingest(conversations)
                }
                if Thread.isMainThread {
                    applyUpdate()
                } else {
                    DispatchQueue.main.async(execute: applyUpdate)
                }
            }
    }

    private static func storeCache(conversationId: String, stamp: QuickStamp, turns: [MessageDisplayTurn]) {
        if projectionCache.count > 24 && projectionCache[conversationId] == nil {
            projectionCache.removeAll(keepingCapacity: true)
        }
        projectionCache[conversationId] = CachedEntry(stamp: stamp, turns: turns)
    }

    private func ingest(_ conversations: [Conversation]) {
        guard let conv = conversations.first(where: { $0.id == conversationId }) else {
            Self.projectionCache.removeValue(forKey: conversationId)
            if !turns.isEmpty || rawMessageCount != 0 {
                lastStamp = nil
                rawMessageCount = 0
                turns = []
            }
            return
        }

        let stamp = QuickStamp(conv)
        guard stamp != lastStamp else { return }
        lastStamp = stamp

        let projectedTurns: [MessageDisplayTurn]
        if let cached = Self.projectionCache[conversationId], cached.stamp == stamp {
            projectedTurns = cached.turns
        } else {
            projectedTurns = Self.project(conv.messages)
            Self.storeCache(conversationId: conversationId, stamp: stamp, turns: projectedTurns)
        }

        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            if conversationTitle != conv.title {
                conversationTitle = conv.title
            }
            if selectedProfileId != conv.selectedProfileId {
                selectedProfileId = conv.selectedProfileId
            }
            if selectedModelName != conv.selectedModelName {
                selectedModelName = conv.selectedModelName
            }
            if rawMessageCount != conv.messages.count {
                rawMessageCount = conv.messages.count
            }
            if turns != projectedTurns {
                turns = projectedTurns
            }
        }
    }

    static func project(_ messages: [ChatMessage]) -> [MessageDisplayTurn] {
        var turns: [MessageDisplayTurn] = []
        turns.reserveCapacity(messages.count)

        for message in messages {
            switch message.role {
            case .user:
                // 若遇到新的用户消息前残留了历史空占位 assistant turn，先清理掉避免空卡片
                if let lastIdx = turns.indices.last, turns[lastIdx].isCompletelyEmptyAssistantTurn {
                    turns.removeLast()
                }
                turns.append(
                    MessageDisplayTurn(
                        id: message.id,
                        role: .user,
                        primaryMessageId: message.id,
                        content: message.content,
                        reasoningContent: "",
                        attachments: message.attachments ?? [],
                        toolCalls: [],
                        steps: [],
                        createdAt: message.createdAt,
                        underlyingMessageIds: [message.id]
                    )
                )

            case .assistant:
                let newStep = AssistantTurnStep(
                    id: message.id,
                    content: message.content,
                    reasoningContent: message.reasoningContent ?? "",
                    toolCalls: message.toolCalls ?? []
                )

                if let lastIndex = turns.indices.last, turns[lastIndex].role == .assistant {
                    if let calls = message.toolCalls, !calls.isEmpty {
                        turns[lastIndex].toolCalls.append(contentsOf: calls)
                    }
                    let trimmedReasoning = newStep.trimmedReasoning
                    if !trimmedReasoning.isEmpty {
                        if turns[lastIndex].reasoningContent.isEmpty {
                            turns[lastIndex].reasoningContent = trimmedReasoning
                        } else {
                            turns[lastIndex].reasoningContent += "\n\n" + trimmedReasoning
                        }
                    }
                    let trimmedContent = newStep.trimmedContent
                    if !trimmedContent.isEmpty {
                        if turns[lastIndex].content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            turns[lastIndex].content = message.content
                        } else {
                            turns[lastIndex].content += "\n\n" + message.content
                        }
                        turns[lastIndex].primaryMessageId = message.id
                    }
                    turns[lastIndex].steps.append(newStep)
                    turns[lastIndex].underlyingMessageIds.append(message.id)
                } else {
                    turns.append(
                        MessageDisplayTurn(
                            id: message.id,
                            role: .assistant,
                            primaryMessageId: message.id,
                            content: message.content,
                            reasoningContent: message.reasoningContent ?? "",
                            attachments: message.attachments ?? [],
                            toolCalls: message.toolCalls ?? [],
                            steps: [newStep],
                            createdAt: message.createdAt,
                            underlyingMessageIds: [message.id]
                        )
                    )
                }

            case .tool:
                if let lastIndex = turns.indices.last, turns[lastIndex].role == .assistant {
                    turns[lastIndex].underlyingMessageIds.append(message.id)
                }

            case .system:
                break
            }
        }

        return turns
    }
}
