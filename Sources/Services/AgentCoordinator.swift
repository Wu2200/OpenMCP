import Foundation
import SwiftUI
import Combine

@MainActor
final class StreamingTurnState: ObservableObject {
    @Published var activeMessageId: String? = nil
    @Published var displayedText: String = ""
    @Published var displayedReasoning: String = ""

    private var pendingText: String? = nil
    private var pendingReasoning: String? = nil
    private var lastTextCommitTime: CFAbsoluteTime = 0
    private var lastReasoningCommitTime: CFAbsoluteTime = 0
    private var coalesceWorkItem: DispatchWorkItem? = nil
    private var isDisplayPaused = false

    func begin(messageId: String) {
        coalesceWorkItem?.cancel()
        coalesceWorkItem = nil
        pendingText = nil
        pendingReasoning = nil
        lastTextCommitTime = 0
        lastReasoningCommitTime = 0
        isDisplayPaused = false
        activeMessageId = messageId
        displayedText = ""
        displayedReasoning = ""
    }

    func setDisplayPaused(_ paused: Bool) {
        guard isDisplayPaused != paused else { return }
        isDisplayPaused = paused
        if paused {
            coalesceWorkItem?.cancel()
            coalesceWorkItem = nil
        } else {
            commitPendingUpdates(at: CFAbsoluteTimeGetCurrent())
        }
    }

    func pushPartialText(_ newText: String) {
        guard displayedText != newText else { return }
        pendingText = newText
        guard !isDisplayPaused else { return }

        let now = CFAbsoluteTimeGetCurrent()
        let elapsed = now - lastTextCommitTime
        let minInterval: CFAbsoluteTime = 0.055

        if displayedText.isEmpty || elapsed >= minInterval {
            commitPendingUpdates(at: now)
        } else {
            scheduleCoalescedCommit(delay: minInterval - elapsed)
        }
    }

    func pushPartialReasoning(_ newReasoning: String) {
        guard displayedReasoning != newReasoning else { return }
        pendingReasoning = newReasoning
        guard !isDisplayPaused else { return }

        let now = CFAbsoluteTimeGetCurrent()
        let elapsed = now - lastReasoningCommitTime
        let minInterval: CFAbsoluteTime = 0.065

        if displayedReasoning.isEmpty || elapsed >= minInterval {
            commitPendingUpdates(at: now)
        } else {
            scheduleCoalescedCommit(delay: minInterval - elapsed)
        }
    }

    private func scheduleCoalescedCommit(delay: TimeInterval) {
        guard coalesceWorkItem == nil else { return }
        let item = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            self.coalesceWorkItem = nil
            self.commitPendingUpdates(at: CFAbsoluteTimeGetCurrent())
        }
        coalesceWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0.016, delay), execute: item)
    }

    private func commitPendingUpdates(at timestamp: CFAbsoluteTime) {
        coalesceWorkItem?.cancel()
        coalesceWorkItem = nil
        guard !isDisplayPaused else { return }

        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            if let text = pendingText, text != displayedText {
                displayedText = text
                lastTextCommitTime = timestamp
            }
            pendingText = nil

            if let reasoning = pendingReasoning, reasoning != displayedReasoning {
                displayedReasoning = reasoning
                lastReasoningCommitTime = timestamp
            }
            pendingReasoning = nil
        }
    }

    func finishImmediate(with finalText: String, finalReasoning: String? = nil) {
        coalesceWorkItem?.cancel()
        coalesceWorkItem = nil
        pendingText = nil
        pendingReasoning = nil

        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            displayedText = finalText
            if let finalReasoning = finalReasoning {
                displayedReasoning = finalReasoning
            }
        }
    }

    func reset() {
        coalesceWorkItem?.cancel()
        coalesceWorkItem = nil
        pendingText = nil
        pendingReasoning = nil
        isDisplayPaused = false

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

    private var generationTask: Task<Void, Never>? = nil
    private var activeConversationId: String? = nil
    private var currentRunGeneratedMessageIds: Set<String> = []
    private var isCancelledByUser: Bool = false
    private static var activeCoordinators: [String: AgentCoordinator] = [:]

    static func coordinator(for conversationId: String) -> AgentCoordinator {
        activeCoordinators[conversationId] ?? AgentCoordinator()
    }

    private func retainForActiveGeneration(_ conversationId: String) {
        Self.activeCoordinators[conversationId] = self
    }

    private func releaseAfterGeneration(_ conversationId: String?) {
        guard let conversationId = conversationId,
              Self.activeCoordinators[conversationId] === self else { return }
        Self.activeCoordinators.removeValue(forKey: conversationId)
    }

    func startSendMessage(
        conversationId: String,
        userPrompt: String,
        attachments: [ChatAttachment] = [],
        settings: OpenAISettings,
        servers: [MCPServer]
    ) {
        let trimmed = userPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !attachments.isEmpty else { return }
        guard DataStorage.shared.conversations.contains(where: { $0.id == conversationId }) else { return }
        generationTask?.cancel()
        retainForActiveGeneration(conversationId)
        generationTask = Task { @MainActor in
            await sendMessage(
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
        servers: [MCPServer]
    ) {
        guard let conversation = DataStorage.shared.conversations.first(where: { $0.id == conversationId }),
              conversation.messages.contains(where: { $0.id == messageId }) else { return }
        generationTask?.cancel()
        retainForActiveGeneration(conversationId)
        generationTask = Task { @MainActor in
            await retryFromMessage(
                conversationId: conversationId,
                messageId: messageId,
                newPrompt: newPrompt,
                settings: settings,
                servers: servers
            )
        }
    }

    func stopGeneration() {
        guard isGenerating else { return }
        isCancelledByUser = true
        generationTask?.cancel()
        generationTask = nil

        let convId = activeConversationId
        let idsToDelete = currentRunGeneratedMessageIds
        currentRunGeneratedMessageIds.removeAll()
        streamingState.reset()

        withAnimation(.spring(response: 0.26, dampingFraction: 0.86)) {
            if let convId = convId, !idsToDelete.isEmpty {
                DataStorage.shared.deleteMessageTurn(conversationId: convId, messageIds: Array(idsToDelete))
            }
            isGenerating = false
            thinkingStartTime = nil
            statusText = ""
            errorMessage = nil
        }
        releaseAfterGeneration(convId)
        activeConversationId = nil
    }

    func sendMessage(
        conversationId: String,
        userPrompt: String,
        attachments: [ChatAttachment] = [],
        settings: OpenAISettings,
        servers: [MCPServer]
    ) async {
        let trimmed = userPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !attachments.isEmpty else { return }
        guard var conversation = DataStorage.shared.conversations.first(where: { $0.id == conversationId }) else { return }

        var finalContent = trimmed
        var finalAttachments = attachments

        if ChatAttachment.shouldPackageAsLongText(trimmed) {
            let packaged = ChatAttachment.makeLongTextAttachment(from: trimmed)
            finalAttachments.append(packaged)
            finalContent = ""
        }

        let userMsg = ChatMessage(
            role: .user,
            content: finalContent,
            attachments: finalAttachments.isEmpty ? nil : finalAttachments
        )
        conversation.messages.append(userMsg)
        conversation.updatedAt = Date()

        if conversation.messages.filter({ $0.role == .user }).count == 1 && conversation.title == "新对话" {
            if !trimmed.isEmpty {
                let firstLine = trimmed.components(separatedBy: .newlines).first ?? trimmed
                conversation.title = String(firstLine.prefix(18))
            } else if let firstAtt = finalAttachments.first {
                conversation.title = String(firstAtt.fileName.prefix(18))
            }
        }
        DataStorage.shared.updateConversation(conversation)

        await runGenerationLoop(conversationId: conversationId, settings: settings, servers: servers)
    }

    func retryFromMessage(
        conversationId: String,
        messageId: String,
        newPrompt: String? = nil,
        settings: OpenAISettings,
        servers: [MCPServer]
    ) async {
        guard var conversation = DataStorage.shared.conversations.first(where: { $0.id == conversationId }) else { return }
        guard let idx = conversation.messages.firstIndex(where: { $0.id == messageId }) else { return }

        if conversation.messages[idx].role == .user {
            if let updated = newPrompt?.trimmingCharacters(in: .whitespacesAndNewlines), !updated.isEmpty {
                let nonLongAttachments = (conversation.messages[idx].attachments ?? []).filter { $0.kind != .longText }
                if ChatAttachment.shouldPackageAsLongText(updated) {
                    var newAtts = nonLongAttachments
                    newAtts.append(ChatAttachment.makeLongTextAttachment(from: updated))
                    conversation.messages[idx].content = ""
                    conversation.messages[idx].attachments = newAtts
                } else {
                    conversation.messages[idx].content = updated
                    conversation.messages[idx].attachments = nonLongAttachments.isEmpty ? nil : nonLongAttachments
                }
            }
            if idx + 1 < conversation.messages.count {
                conversation.messages.removeSubrange((idx + 1)..<conversation.messages.count)
            }
        } else {
            if let userIdx = conversation.messages[0...idx].lastIndex(where: { $0.role == .user }) {
                if userIdx + 1 < conversation.messages.count {
                    conversation.messages.removeSubrange((userIdx + 1)..<conversation.messages.count)
                }
            } else {
                conversation.messages.removeSubrange(idx..<conversation.messages.count)
            }
        }

        conversation.updatedAt = Date()
        DataStorage.shared.updateConversation(conversation)

        await runGenerationLoop(conversationId: conversationId, settings: settings, servers: servers)
    }

    private func runGenerationLoop(
        conversationId: String,
        settings: OpenAISettings,
        servers: [MCPServer]
    ) async {
        guard var conversation = DataStorage.shared.conversations.first(where: { $0.id == conversationId }) else { return }

        isCancelledByUser = false
        activeConversationId = conversationId
        currentRunGeneratedMessageIds.removeAll()
        errorMessage = nil
        isGenerating = true
        thinkingStartTime = Date()
        statusText = "思考中"

        var openAITools: [[String: Any]] = []
        var toolServerMap: [String: (server: MCPServer, originalToolName: String)] = [:]

        for server in servers where server.isEnabled {
            for tool in server.tools where tool.isEnabled {
                let safeName = "\(server.id.prefix(6))_\(tool.name)".replacingOccurrences(of: "-", with: "_")
                toolServerMap[safeName] = (server, tool.rawName)
                let schemaObj = (try? JSONSerialization.jsonObject(with: Data(tool.inputSchemaJSON.utf8))) as? [String: Any] ?? ["type": "object", "properties": [:]]
                openAITools.append([
                    "type": "function",
                    "function": [
                        "name": safeName,
                        "description": "[\(server.name)] \(tool.description)",
                        "parameters": schemaObj
                    ]
                ])
            }
        }

        var maxIterations = 8
        while maxIterations > 0 {
            if isCancelledByUser || Task.isCancelled {
                return
            }
            maxIterations -= 1
            let contextMessages = conversation.messages

            let placeholderMsg = ChatMessage(
                role: .assistant,
                content: "",
                reasoningContent: nil,
                toolCalls: nil
            )
            currentRunGeneratedMessageIds.insert(placeholderMsg.id)
            streamingState.begin(messageId: placeholderMsg.id)

            conversation.messages.append(placeholderMsg)
            let msgIndex = conversation.messages.count - 1
            DataStorage.shared.updateConversation(conversation, persistImmediately: false)

            do {
                let (content, reasoning, toolCalls) = try await OpenAIService.shared.streamChatCompletion(
                    settings: settings,
                    messages: contextMessages,
                    tools: openAITools.isEmpty ? nil : openAITools,
                    onPartialUpdate: { [weak self] partialText in
                        guard let self = self, !self.isCancelledByUser, !Task.isCancelled else { return }
                        self.streamingState.pushPartialText(partialText)
                    },
                    onReasoningUpdate: { [weak self] partialReasoning in
                        guard let self = self, !self.isCancelledByUser, !Task.isCancelled else { return }
                        self.streamingState.pushPartialReasoning(partialReasoning)
                    }
                )

                if isCancelledByUser || Task.isCancelled {
                    return
                }

                let finalText = content ?? ""
                streamingState.finishImmediate(with: finalText, finalReasoning: reasoning)

                conversation.messages[msgIndex].content = finalText
                conversation.messages[msgIndex].reasoningContent = reasoning

                if let calls = toolCalls, !calls.isEmpty {
                    var executingCalls = calls.map { c -> ToolCallItem in
                        var item = c
                        item.isExecuting = true
                        return item
                    }
                    conversation.messages[msgIndex].toolCalls = executingCalls
                    DataStorage.shared.updateConversation(conversation, persistImmediately: false)

                    for i in executingCalls.indices {
                        if isCancelledByUser || Task.isCancelled {
                            return
                        }
                        let call = executingCalls[i]
                        statusText = "调用工具中"

                        var toolOutput = ""
                        if let mapping = toolServerMap[call.name] {
                            do {
                                toolOutput = try await MCPService.shared.callTool(
                                    server: mapping.server,
                                    rawName: mapping.originalToolName,
                                    argumentsJSON: call.arguments
                                )
                                executingCalls[i].result = toolOutput
                            } catch {
                                if isCancelledByUser || Task.isCancelled || error is CancellationError {
                                    return
                                }
                                let errStr = "Error: \(error.localizedDescription)"
                                toolOutput = errStr
                                executingCalls[i].error = error.localizedDescription
                                executingCalls[i].result = errStr
                            }
                        } else {
                            toolOutput = "Error: 未找到对应的 MCP 工具映射 (\(call.name))"
                            executingCalls[i].error = "未找到工具"
                            executingCalls[i].result = toolOutput
                        }

                        if isCancelledByUser || Task.isCancelled {
                            return
                        }

                        executingCalls[i].isExecuting = false
                        conversation.messages[msgIndex].toolCalls = executingCalls

                        let toolMsg = ChatMessage(
                            role: .tool,
                            content: toolOutput,
                            toolCallId: call.id
                        )
                        currentRunGeneratedMessageIds.insert(toolMsg.id)
                        conversation.messages.append(toolMsg)
                        DataStorage.shared.updateConversation(conversation, persistImmediately: false)
                    }

                    DataStorage.shared.saveConversations()
                    statusText = "思考中"
                } else {
                    conversation.updatedAt = Date()
                    DataStorage.shared.updateConversation(conversation, persistImmediately: true)
                    break
                }
            } catch {
                if isCancelledByUser || Task.isCancelled || error is CancellationError || (error as NSError).code == NSURLErrorCancelled {
                    return
                }
                streamingState.reset()
                if msgIndex < conversation.messages.count,
                   conversation.messages[msgIndex].content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                   (conversation.messages[msgIndex].toolCalls ?? []).isEmpty {
                    conversation.messages.remove(at: msgIndex)
                }
                DataStorage.shared.updateConversation(conversation, persistImmediately: true)
                errorMessage = error.localizedDescription
                break
            }
        }

        if !isCancelledByUser && !Task.isCancelled {
            streamingState.reset()
            isGenerating = false
            thinkingStartTime = nil
            statusText = ""
            currentRunGeneratedMessageIds.removeAll()
            releaseAfterGeneration(activeConversationId)
            activeConversationId = nil
        }
    }
}
