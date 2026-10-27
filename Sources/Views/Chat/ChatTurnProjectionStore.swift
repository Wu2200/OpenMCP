import Combine
import Foundation
import SwiftUI

@MainActor
final class ChatTurnProjectionStore: ObservableObject {
    @Published private(set) var turns: [MessageDisplayTurn]

    private let conversationId: String
    private var conversationsCancellable: AnyCancellable?

    init(conversationId: String) {
        self.conversationId = conversationId
        let initialMessages = DataStorage.shared.conversations.first(where: { $0.id == conversationId })?.messages ?? []
        self.turns = Self.project(initialMessages)

        conversationsCancellable = DataStorage.shared.$conversations
            .receive(on: DispatchQueue.main)
            .sink { [weak self] conversations in
                guard let self else { return }
                let messages = conversations.first(where: { $0.id == self.conversationId })?.messages ?? []
                let projectedTurns = Self.project(messages)
                guard self.turns != projectedTurns else { return }
                self.turns = projectedTurns
            }
    }

    private static func project(_ messages: [ChatMessage]) -> [MessageDisplayTurn] {
        var turns: [MessageDisplayTurn] = []

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
                        createdAt: message.createdAt,
                        underlyingMessageIds: [message.id]
                    )
                )
            case .assistant:
                if let lastIndex = turns.indices.last, turns[lastIndex].role == .assistant {
                    if let calls = message.toolCalls, !calls.isEmpty {
                        turns[lastIndex].toolCalls.append(contentsOf: calls)
                    }
                    if let reasoning = message.reasoningContent?.trimmingCharacters(in: .whitespacesAndNewlines), !reasoning.isEmpty {
                        if turns[lastIndex].reasoningContent.isEmpty {
                            turns[lastIndex].reasoningContent = reasoning
                        } else {
                            turns[lastIndex].reasoningContent += "\n\n" + reasoning
                        }
                    }
                    let trimmedContent = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmedContent.isEmpty {
                        if turns[lastIndex].content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            turns[lastIndex].content = message.content
                        } else {
                            turns[lastIndex].content += "\n\n" + message.content
                        }
                        turns[lastIndex].primaryMessageId = message.id
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
