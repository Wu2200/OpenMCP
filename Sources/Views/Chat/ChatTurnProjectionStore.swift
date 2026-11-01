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

    var isPureToolCalls: Bool {
        trimmedContent.isEmpty && trimmedReasoning.isEmpty && !toolCalls.isEmpty
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
}

@MainActor
final class ChatTurnProjectionStore: ObservableObject {
    @Published private(set) var turns: [MessageDisplayTurn]
    @Published private(set) var conversationTitle: String
    @Published private(set) var selectedProfileId: String?
    @Published private(set) var selectedModelName: String?
    @Published private(set) var rawMessageCount: Int

    private struct QuickStamp: Equatable {
        struct MessageDigest: Equatable {
            let id: String
            let role: MessageRole
            let contentBytes: Int
            let contentTail: Substring
            let reasoningBytes: Int
            let attachmentCount: Int
            let toolCalls: [ToolCallItem]
        }

        let title: String
        let selectedProfileId: String?
        let selectedModelName: String?
        let digests: [MessageDigest]

        init(_ conversation: Conversation) {
            self.title = conversation.title
            self.selectedProfileId = conversation.selectedProfileId
            self.selectedModelName = conversation.selectedModelName
            self.digests = conversation.messages.map { msg in
                MessageDigest(
                    id: msg.id,
                    role: msg.role,
                    contentBytes: msg.content.utf8.count,
                    contentTail: msg.content.suffix(24),
                    reasoningBytes: msg.reasoningContent?.utf8.count ?? 0,
                    attachmentCount: msg.attachments?.count ?? 0,
                    toolCalls: msg.toolCalls ?? []
                )
            }
        }
    }

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
        self.turns = Self.project(initialConv?.messages ?? [])
        if let initialConv {
            self.lastStamp = QuickStamp(initialConv)
        }

        // 在主线程同步处理会话更新，消除 .receive(on: DispatchQueue.main) 推迟一帧导致的流式结束瞬间气泡闪烁空窗
        conversationsCancellable = DataStorage.shared.$conversations
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

    private func ingest(_ conversations: [Conversation]) {
        guard let conv = conversations.first(where: { $0.id == conversationId }) else {
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
            let projectedTurns = Self.project(conv.messages)
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

                    if let stepLastIdx = turns[lastIndex].steps.indices.last {
                        let prevStep = turns[lastIndex].steps[stepLastIdx]
                        if prevStep.isEmptyPlaceholder {
                            turns[lastIndex].steps[stepLastIdx] = newStep
                        } else if prevStep.isPureToolCalls && newStep.isPureToolCalls {
                            turns[lastIndex].steps[stepLastIdx].toolCalls.append(contentsOf: newStep.toolCalls)
                        } else {
                            turns[lastIndex].steps.append(newStep)
                        }
                    } else {
                        turns[lastIndex].steps.append(newStep)
                    }

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
