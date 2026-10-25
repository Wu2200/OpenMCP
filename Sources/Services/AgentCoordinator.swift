import Foundation
import SwiftUI
import Combine

@MainActor
final class StreamingTurnState: ObservableObject {
    @Published var activeMessageId: String? = nil
    @Published var displayedText: String = ""
    @Published var displayedReasoning: String = ""

    func begin(messageId: String) {
        activeMessageId = messageId
        displayedText = ""
        displayedReasoning = ""
    }

    func pushPartialText(_ newText: String) {
        if displayedText != newText {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                displayedText = newText
            }
        }
    }

    func pushPartialReasoning(_ newReasoning: String) {
        if displayedReasoning != newReasoning {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                displayedReasoning = newReasoning
            }
        }
    }

    func finishImmediate(with finalText: String, finalReasoning: String? = nil) {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            displayedText = finalText
            if let finalReasoning {
                displayedReasoning = finalReasoning
            }
        }
    }

    func reset() {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            activeMessageId = nil
            displayedText = ""
            displayedReasoning = ""
        }
    }
}

@MainActor
class AgentCoordinator: ObservableObject {
    @Published var isGenerating: Bool = false
    @Published var statusText: String = ""
    @Published var errorMessage: String? = nil
    @Published var thinkingStartTime: Date? = nil

    let streamingState = StreamingTurnState()

    private var activeTask: Task<Void, Never>? = nil
    private var activeConversationId: String? = nil
    private var currentTurnMessageIds: Set<String> = []

    func startSendMessage(
        conversationId: String,
        userPrompt: String,
        attachments: [ChatAttachment] = [],
        settings: OpenAISettings,
        servers: [MCPServerConfig]
    ) {
        activeTask?.cancel()
        currentTurnMessageIds.removeAll()
        streamingState.reset()
        activeConversationId = conversationId
        activeTask = Task { [weak self] in
            guard let self = self else { return }
            await self.sendMessage(
                conversationId: conversationId,
                userPrompt: userPrompt,
                attachments: attachments,
                settings: settings,
                servers: servers
            )
        }
    }

    func startRetryFromMessage(
        conversationId: String,
        messageId: String,
        newPrompt: String? = nil,
        settings: OpenAISettings,
        servers: [MCPServerConfig]
    ) {
        activeTask?.cancel()
        currentTurnMessageIds.removeAll()
        streamingState.reset()
        activeConversationId = conversationId
        activeTask = Task { [weak self] in
            guard let self = self else { return }
            await self.retryFromMessage(
                conversationId: conversationId,
                messageId: messageId,
                newPrompt: newPrompt,
                settings: settings,
                servers: servers
            )
        }
    }

    func stopGeneration() {
        activeTask?.cancel()
        activeTask = nil

        if let convId = activeConversationId, !currentTurnMessageIds.isEmpty {
            let idsToRemove = Array(currentTurnMessageIds)
            withAnimation(.easeInOut(duration: 0.18)) {
                DataStorage.shared.deleteMessageTurn(conversationId: convId, messageIds: idsToRemove)
            }
        }

        currentTurnMessageIds.removeAll()
        streamingState.reset()
        withAnimation(.easeInOut(duration: 0.18)) {
            isGenerating = false
            statusText = ""
            thinkingStartTime = nil
            errorMessage = nil
        }
    }

    func sendMessage(
        conversationId: String,
        userPrompt: String,
        attachments: [ChatAttachment] = [],
        settings: OpenAISettings,
        servers: [MCPServerConfig]
    ) async {
        let trimmed = userPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !attachments.isEmpty else { return }

        errorMessage = nil
        isGenerating = true
        thinkingStartTime = Date()
        statusText = "思考中"

        let userMsg = ChatMessage(
            role: .user,
            content: userPrompt,
            attachments: attachments.isEmpty ? nil : attachments
        )
        DataStorage.shared.appendMessage(to: conversationId, message: userMsg)

        await runGenerationLoop(conversationId: conversationId, settings: settings, servers: servers)
    }

    func retryFromMessage(
        conversationId: String,
        messageId: String,
        newPrompt: String? = nil,
        settings: OpenAISettings,
        servers: [MCPServerConfig]
    ) async {
        guard let conv = DataStorage.shared.conversations.first(where: { $0.id == conversationId }),
              let targetIndex = conv.messages.firstIndex(where: { $0.id == messageId }) else { return }

        errorMessage = nil
        isGenerating = true
        thinkingStartTime = Date()
        statusText = "思考中"

        let targetMsg = conv.messages[targetIndex]
        if targetMsg.role == .user {
            DataStorage.shared.truncateMessages(conversationId: conversationId, upToIndex: targetIndex + 1)
            if let updated = newPrompt?.trimmingCharacters(in: .whitespacesAndNewlines), !updated.isEmpty {
                DataStorage.shared.updateMessageContent(conversationId: conversationId, messageId: messageId, newContent: updated)
            }
        } else {
            if let precedingUserIdx = conv.messages[..<targetIndex].lastIndex(where: { $0.role == .user }) {
                DataStorage.shared.truncateMessages(conversationId: conversationId, upToIndex: precedingUserIdx + 1)
            } else {
                DataStorage.shared.truncateMessages(conversationId: conversationId, upToIndex: targetIndex)
            }
        }

        await runGenerationLoop(conversationId: conversationId, settings: settings, servers: servers)
    }

    private func cleanupInterruptedTurn(conversationId: String) {
        if !currentTurnMessageIds.isEmpty {
            let ids = Array(currentTurnMessageIds)
            DataStorage.shared.deleteMessageTurn(conversationId: conversationId, messageIds: ids)
            currentTurnMessageIds.removeAll()
        }
        streamingState.reset()
        isGenerating = false
        statusText = ""
        thinkingStartTime = nil
    }

    private func runGenerationLoop(
        conversationId: String,
        settings: OpenAISettings,
        servers: [MCPServerConfig]
    ) async {
        var enabledTools: [(serverName: String, tool: MCPTool)] = []
        var toolServerMap: [String: MCPServerConfig] = [:]

        for server in servers where server.isEnabled {
            for tool in server.tools where tool.isEnabled {
                enabledTools.append((serverName: server.name, tool: tool))
                toolServerMap[tool.name] = server
            }
        }

        var maxIterations = 8
        while maxIterations > 0 {
            if Task.isCancelled {
                cleanupInterruptedTurn(conversationId: conversationId)
                return
            }
            maxIterations -= 1

            let currentMessages = DataStorage.shared.conversations.first(where: { $0.id == conversationId })?.messages ?? []
            let placeholderMsg = ChatMessage(role: .assistant, content: "")
            let placeholderId = placeholderMsg.id
            currentTurnMessageIds.insert(placeholderId)
            streamingState.begin(messageId: placeholderId)
            DataStorage.shared.appendMessage(to: conversationId, message: placeholderMsg)

            do {
                statusText = "思考中"
                let assistantMsg = try await OpenAIService.shared.createChatCompletionStream(
                    messages: currentMessages,
                    settings: settings,
                    tools: enabledTools,
                    onDelta: { [weak self] partialText in
                        await MainActor.run {
                            guard let self = self, !Task.isCancelled else { return }
                            self.streamingState.pushPartialText(partialText)
                        }
                    },
                    onReasoningDelta: { [weak self] partialReasoning in
                        await MainActor.run {
                            guard let self = self, !Task.isCancelled else { return }
                            self.streamingState.pushPartialReasoning(partialReasoning)
                        }
                    }
                )

                if Task.isCancelled {
                    cleanupInterruptedTurn(conversationId: conversationId)
                    return
                }

                streamingState.finishImmediate(
                    with: assistantMsg.content,
                    finalReasoning: assistantMsg.reasoningContent
                )

                var finalizedAssistantMsg = assistantMsg
                finalizedAssistantMsg.id = placeholderId
                DataStorage.shared.replaceMessage(
                    in: conversationId,
                    messageId: placeholderId,
                    with: finalizedAssistantMsg,
                    persist: true
                )
                streamingState.reset()

                guard let toolCalls = finalizedAssistantMsg.toolCalls, !toolCalls.isEmpty else {
                    break
                }

                for tc in toolCalls {
                    if Task.isCancelled {
                        cleanupInterruptedTurn(conversationId: conversationId)
                        return
                    }

                    statusText = "正在调用 \(tc.name)"

                    let toolOutput: String
                    var isErr = false

                    if let server = toolServerMap[tc.name] {
                        do {
                            toolOutput = try await MCPService.shared.callTool(
                                server: server,
                                toolName: tc.name,
                                argumentsJSON: tc.arguments
                            )
                        } catch {
                            isErr = true
                            toolOutput = "Error executing tool \(tc.name): \(error.localizedDescription)"
                        }
                    } else {
                        isErr = true
                        toolOutput = "Error: Server for tool \(tc.name) not found or disabled."
                    }

                    if Task.isCancelled {
                        cleanupInterruptedTurn(conversationId: conversationId)
                        return
                    }

                    DataStorage.shared.updateToolCallStatus(
                        in: conversationId,
                        messageId: finalizedAssistantMsg.id,
                        toolCallId: tc.id,
                        result: toolOutput,
                        isExecuting: false,
                        error: isErr ? toolOutput : nil
                    )

                    let toolReplyMsg = ChatMessage(
                        role: .tool,
                        content: toolOutput,
                        toolCallId: tc.id
                    )
                    currentTurnMessageIds.insert(toolReplyMsg.id)
                    DataStorage.shared.appendMessage(to: conversationId, message: toolReplyMsg)
                }

            } catch is CancellationError {
                cleanupInterruptedTurn(conversationId: conversationId)
                return
            } catch let urlError as URLError where urlError.code == .cancelled {
                cleanupInterruptedTurn(conversationId: conversationId)
                return
            } catch {
                if Task.isCancelled {
                    cleanupInterruptedTurn(conversationId: conversationId)
                    return
                }
                streamingState.reset()
                let currentPlaceholder = DataStorage.shared.conversations
                    .first(where: { $0.id == conversationId })?
                    .messages.first(where: { $0.id == placeholderId })
                if currentPlaceholder?.content.isEmpty == true && (currentPlaceholder?.toolCalls?.isEmpty ?? true) {
                    DataStorage.shared.deleteMessageTurn(conversationId: conversationId, messageIds: [placeholderId])
                }
                errorMessage = error.localizedDescription
                break
            }
        }

        currentTurnMessageIds.removeAll()
        streamingState.reset()
        isGenerating = false
        statusText = ""
        thinkingStartTime = nil
    }
}
