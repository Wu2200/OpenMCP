import Foundation
import SwiftUI
import Combine

@MainActor
final class StreamingTurnState: ObservableObject {
    @Published var activeMessageId: String? = nil
    @Published var displayedText: String = ""

    private var targetText: String = ""
    private var animationTimer: Timer? = nil
    private var drainContinuations: [CheckedContinuation<Void, Never>] = []
    private var isAcceleratingDrain: Bool = false

    func begin(messageId: String) {
        stopTimer()
        resumeAllContinuations()
        activeMessageId = messageId
        targetText = ""
        displayedText = ""
        isAcceleratingDrain = false
    }

    func pushPartialText(_ newText: String) {
        targetText = newText
        if displayedText.isEmpty && newText.count <= 4 {
            displayedText = newText
            return
        }
        startTimerIfNeeded()
    }

    func completeAndDrain(with finalText: String) async {
        targetText = finalText
        isAcceleratingDrain = true
        if displayedText.count >= targetText.count {
            displayedText = finalText
            stopTimer()
            return
        }
        startTimerIfNeeded()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            drainContinuations.append(continuation)
        }
    }

    func finishImmediate(with finalText: String) {
        stopTimer()
        targetText = finalText
        displayedText = finalText
        isAcceleratingDrain = false
        resumeAllContinuations()
    }

    func reset() {
        stopTimer()
        activeMessageId = nil
        targetText = ""
        displayedText = ""
        isAcceleratingDrain = false
        resumeAllContinuations()
    }

    private func startTimerIfNeeded() {
        guard animationTimer == nil else { return }
        animationTimer = Timer.scheduledTimer(withTimeInterval: 0.032, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.tick()
            }
        }
    }

    private func stopTimer() {
        animationTimer?.invalidate()
        animationTimer = nil
    }

    private func resumeAllContinuations() {
        guard !drainContinuations.isEmpty else { return }
        let pending = drainContinuations
        drainContinuations.removeAll()
        for cont in pending {
            cont.resume()
        }
    }

    private func tick() {
        guard displayedText.count < targetText.count else {
            if displayedText != targetText {
                displayedText = targetText
            }
            stopTimer()
            resumeAllContinuations()
            return
        }

        let remaining = targetText.count - displayedText.count
        let step: Int
        if isAcceleratingDrain {
            if remaining <= 36 {
                step = 2
            } else if remaining <= 120 {
                step = 4
            } else if remaining <= 360 {
                step = 9
            } else {
                step = max(14, remaining / 22)
            }
        } else {
            if remaining <= 30 {
                step = 2
            } else if remaining <= 90 {
                step = 3
            } else if remaining <= 240 {
                step = 6
            } else if remaining <= 600 {
                step = 12
            } else {
                step = max(16, remaining / 28)
            }
        }

        let nextCount = min(targetText.count, displayedText.count + step)
        let idx = targetText.index(targetText.startIndex, offsetBy: nextCount)
        displayedText = String(targetText[..<idx])

        if displayedText.count >= targetText.count {
            stopTimer()
            resumeAllContinuations()
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

    func startSendMessage(
        conversationId: String,
        userPrompt: String,
        attachments: [ChatAttachment] = [],
        settings: OpenAISettings,
        servers: [MCPServer]
    ) {
        generationTask?.cancel()
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
        generationTask?.cancel()
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
                toolCalls: nil
            )
            currentRunGeneratedMessageIds.insert(placeholderMsg.id)
            streamingState.begin(messageId: placeholderMsg.id)

            conversation.messages.append(placeholderMsg)
            let msgIndex = conversation.messages.count - 1
            DataStorage.shared.updateConversation(conversation, persistImmediately: false)

            do {
                let (content, toolCalls) = try await OpenAIService.shared.streamChatCompletion(
                    settings: settings,
                    messages: contextMessages,
                    tools: openAITools.isEmpty ? nil : openAITools,
                    onPartialUpdate: { [weak self] partialText in
                        guard let self = self, !self.isCancelledByUser, !Task.isCancelled else { return }
                        self.streamingState.pushPartialText(partialText)
                    }
                )

                if isCancelledByUser || Task.isCancelled {
                    return
                }

                let finalText = content ?? ""
                if !finalText.isEmpty {
                    await streamingState.completeAndDrain(with: finalText)
                } else {
                    streamingState.finishImmediate(with: "")
                }

                if isCancelledByUser || Task.isCancelled {
                    return
                }

                conversation.messages[msgIndex].content = finalText

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
        }
    }
}
