import Foundation
import SwiftUI
import Combine

@MainActor
final class StreamingTurnState: ObservableObject {
    @Published var activeMessageId: String? = nil
    @Published var displayedText: String = ""
    @Published var displayedReasoning: String = ""
    @Published var isScrollInteracting: Bool = false

    private var targetText: String = ""
    private var targetReasoning: String = ""
    private var isStreamComplete: Bool = false
    private var isDisplayPaused: Bool = false
    private var drainTimer: Timer? = nil

    func begin(messageId: String) {
        stopDrainTimer()
        targetText = ""
        targetReasoning = ""
        isStreamComplete = false
        isDisplayPaused = false
        isScrollInteracting = false
        activeMessageId = messageId
        displayedText = ""
        displayedReasoning = ""
    }

    func setDisplayPaused(_ paused: Bool) {
        if isScrollInteracting != paused {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                isScrollInteracting = paused
            }
        }
        guard isDisplayPaused != paused else { return }
        isDisplayPaused = paused
        if paused {
            stopDrainTimer()
        } else {
            flushImmediatelyToTarget()
        }
    }

    func pushPartialText(_ newText: String) {
        guard targetText != newText else { return }
        targetText = newText
        guard !isDisplayPaused else { return }

        if displayedText.isEmpty {
            let initialEnd = advanceIndex(in: targetText, from: targetText.startIndex, maxChars: min(28, targetText.count))
            commitDisplayed(text: String(targetText[..<initialEnd]), reasoning: nil)
        }
        ensureDrainTimer()
    }

    func pushPartialReasoning(_ newReasoning: String) {
        guard targetReasoning != newReasoning else { return }
        targetReasoning = newReasoning
        guard !isDisplayPaused else { return }

        if displayedReasoning != targetReasoning {
            commitDisplayed(text: nil, reasoning: targetReasoning)
        }
    }

    private func ensureDrainTimer() {
        guard drainTimer == nil, !isDisplayPaused else { return }
        let timer = Timer(timeInterval: 0.055, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.tickDrain()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        drainTimer = timer
    }

    private func stopDrainTimer() {
        drainTimer?.invalidate()
        drainTimer = nil
    }

    private func tickDrain() {
        guard !isDisplayPaused else {
            stopDrainTimer()
            return
        }

        var didChange = false
        var nextText: String? = nil
        var nextReasoning: String? = nil

        if displayedReasoning != targetReasoning {
            nextReasoning = targetReasoning
            didChange = true
        }

        if displayedText != targetText {
            if !targetText.hasPrefix(displayedText) {
                nextText = targetText
            } else {
                let currentEnd = displayedText.endIndex
                let remainingCount = targetText.distance(from: currentEnd, to: targetText.endIndex)
                if remainingCount > 0 {
                    let stepChars: Int
                    if isStreamComplete {
                        stepChars = max(36, (remainingCount + 1) / 2)
                    } else if remainingCount > 300 {
                        stepChars = max(60, remainingCount / 3)
                    } else if remainingCount > 120 {
                        stepChars = max(32, remainingCount / 3)
                    } else if remainingCount > 40 {
                        stepChars = max(16, remainingCount / 3)
                    } else if remainingCount > 12 {
                        stepChars = 10
                    } else {
                        stepChars = remainingCount
                    }
                    let nextIdx = advanceIndex(in: targetText, from: currentEnd, maxChars: min(remainingCount, stepChars))
                    nextText = String(targetText[..<nextIdx])
                }
            }
            if nextText != nil {
                didChange = true
            }
        }

        if didChange {
            commitDisplayed(text: nextText, reasoning: nextReasoning)
        }

        if displayedText == targetText && displayedReasoning == targetReasoning {
            stopDrainTimer()
        }
    }

    private func advanceIndex(in text: String, from start: String.Index, maxChars: Int) -> String.Index {
        guard maxChars > 0, start < text.endIndex else { return start }
        return text.index(start, offsetBy: maxChars, limitedBy: text.endIndex) ?? text.endIndex
    }

    private func flushImmediatelyToTarget() {
        stopDrainTimer()
        let nextText = (displayedText != targetText) ? targetText : nil
        let nextReasoning = (displayedReasoning != targetReasoning) ? targetReasoning : nil
        if nextText != nil || nextReasoning != nil {
            commitDisplayed(text: nextText, reasoning: nextReasoning)
        }
    }

    private func commitDisplayed(text: String?, reasoning: String?) {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            if let text = text, displayedText != text {
                displayedText = text
            }
            if let reasoning = reasoning, displayedReasoning != reasoning {
                displayedReasoning = reasoning
            }
        }
    }

    func finishImmediate(with finalText: String, finalReasoning: String? = nil) {
        stopDrainTimer()
        targetText = finalText
        if let finalReasoning = finalReasoning {
            targetReasoning = finalReasoning
        }
        isStreamComplete = true
        commitDisplayed(text: finalText, reasoning: finalReasoning)
    }

    func reset() {
        stopDrainTimer()
        targetText = ""
        targetReasoning = ""
        isStreamComplete = false
        isDisplayPaused = false

        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            isScrollInteracting = false
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
    private var activeGenerationToken: UUID? = nil
    private var activeConversationId: String? = nil
    private var activeTurnId: String? = nil
    private var activeTurnPrompt: String? = nil
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

    private func completeGenerationTask(token: UUID, conversationId: String) {
        guard activeGenerationToken == token else { return }
        activeGenerationToken = nil
        generationTask = nil
        if !isGenerating {
            releaseAfterGeneration(conversationId)
        }
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
        guard activeGenerationToken == nil, !isGenerating else { return }
        let token = UUID()
        activeGenerationToken = token
        retainForActiveGeneration(conversationId)
        generationTask = Task { @MainActor in
            defer { completeGenerationTask(token: token, conversationId: conversationId) }
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
        guard activeGenerationToken == nil, !isGenerating else { return }
        let token = UUID()
        activeGenerationToken = token
        retainForActiveGeneration(conversationId)
        generationTask = Task { @MainActor in
            defer { completeGenerationTask(token: token, conversationId: conversationId) }
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
        activeGenerationToken = nil
        generationTask?.cancel()
        generationTask = nil

        let convId = activeConversationId
        let currentTurnId = activeTurnId
        let currentTurnPrompt = activeTurnPrompt
        let partialLength = streamingState.displayedText.count
        let idsToDelete = currentRunGeneratedMessageIds
        currentRunGeneratedMessageIds.removeAll()
        streamingState.reset()

        AppLogManager.shared.log(
            category: .aiStop,
            level: .info,
            title: "用户手动停止输出",
            summary: "已清理本轮生成消息 (\(idsToDelete.count) 条)，停止前已显示 \(partialLength) 字",
            conversationId: convId,
            turnId: currentTurnId,
            turnPrompt: currentTurnPrompt
        )

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
        activeTurnId = nil
        activeTurnPrompt = nil
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
        let effectiveSettings = settings.resolvedSettings(for: conversation)

        let turnId = UUID().uuidString
        let lastUserMsg = conversation.messages.last(where: { $0.role == .user })
        let rawPromptText: String = {
            if let text = lastUserMsg?.content.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
                return text
            }
            if let firstAtt = lastUserMsg?.attachments?.first {
                if let snippet = firstAtt.textContent?.trimmingCharacters(in: .whitespacesAndNewlines), !snippet.isEmpty {
                    return snippet
                }
                return firstAtt.fileName
            }
            return "对话交互"
        }()
        let turnPrompt = String(rawPromptText.replacingOccurrences(of: "\n", with: " ").prefix(48))

        isCancelledByUser = false
        activeConversationId = conversationId
        activeTurnId = turnId
        activeTurnPrompt = turnPrompt
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

        var stepIndex = 0

        while true {
            if isCancelledByUser || Task.isCancelled {
                return
            }
            stepIndex += 1
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
                    settings: effectiveSettings,
                    messages: contextMessages,
                    tools: openAITools.isEmpty ? nil : openAITools,
                    conversationId: conversationId,
                    conversationTitle: conversation.title,
                    turnId: turnId,
                    turnPrompt: turnPrompt,
                    stepIndex: stepIndex,
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
                            let callStart = CFAbsoluteTimeGetCurrent()
                            do {
                                toolOutput = try await MCPService.shared.callTool(
                                    server: mapping.server,
                                    rawName: mapping.originalToolName,
                                    argumentsJSON: call.arguments
                                )
                                executingCalls[i].result = toolOutput
                                let callElapsed = String(format: "%.2fs", CFAbsoluteTimeGetCurrent() - callStart)
                                AppLogManager.shared.logToolCall(
                                    conversationId: conversationId,
                                    conversationTitle: conversation.title,
                                    turnId: turnId,
                                    turnPrompt: turnPrompt,
                                    stepIndex: stepIndex,
                                    toolName: mapping.originalToolName,
                                    serverName: mapping.server.name,
                                    elapsed: callElapsed,
                                    isSuccess: true,
                                    summary: "服务: \(mapping.server.name) · 耗时: \(callElapsed) · 返回: \(toolOutput.count) 字",
                                    arguments: call.arguments,
                                    outputPreview: String(toolOutput.prefix(600))
                                )
                            } catch {
                                if isCancelledByUser || Task.isCancelled || error is CancellationError {
                                    return
                                }
                                let callElapsed = String(format: "%.2fs", CFAbsoluteTimeGetCurrent() - callStart)
                                let errStr = "Error: \(error.localizedDescription)"
                                toolOutput = errStr
                                executingCalls[i].error = error.localizedDescription
                                executingCalls[i].result = errStr
                                AppLogManager.shared.logToolCall(
                                    conversationId: conversationId,
                                    conversationTitle: conversation.title,
                                    turnId: turnId,
                                    turnPrompt: turnPrompt,
                                    stepIndex: stepIndex,
                                    toolName: mapping.originalToolName,
                                    serverName: mapping.server.name,
                                    elapsed: callElapsed,
                                    isSuccess: false,
                                    summary: "服务: \(mapping.server.name) · 失败: \(error.localizedDescription)",
                                    arguments: call.arguments,
                                    outputPreview: error.localizedDescription
                                )
                            }
                        } else {
                            toolOutput = "Error: 未找到对应的 MCP 工具映射 (\(call.name))"
                            executingCalls[i].error = "未找到工具"
                            executingCalls[i].result = toolOutput
                            AppLogManager.shared.logToolCall(
                                conversationId: conversationId,
                                conversationTitle: conversation.title,
                                turnId: turnId,
                                turnPrompt: turnPrompt,
                                stepIndex: stepIndex,
                                toolName: call.name,
                                serverName: "未知服务",
                                elapsed: "0.00s",
                                isSuccess: false,
                                summary: "未找到对应的 MCP 工具映射",
                                arguments: call.arguments,
                                outputPreview: toolOutput
                            )
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
                    if finalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && stepIndex > 1 {
                        statusText = "生成总结中"
                        var recoveryMessages = contextMessages
                        recoveryMessages.append(
                            ChatMessage(
                                role: .user,
                                content: "请基于以上已获取的工具执行结果，直接输出完整的中文分析与总结正文。"
                            )
                        )
                        if let recovered = try? await OpenAIService.shared.streamChatCompletion(
                            settings: effectiveSettings,
                            messages: recoveryMessages,
                            tools: nil,
                            conversationId: conversationId,
                            conversationTitle: conversation.title,
                            turnId: turnId,
                            turnPrompt: turnPrompt,
                            stepIndex: stepIndex + 1,
                            onPartialUpdate: { [weak self] partialText in
                                guard let self = self, !self.isCancelledByUser, !Task.isCancelled else { return }
                                self.streamingState.pushPartialText(partialText)
                            },
                            onReasoningUpdate: { [weak self] partialReasoning in
                                guard let self = self, !self.isCancelledByUser, !Task.isCancelled else { return }
                                self.streamingState.pushPartialReasoning(partialReasoning)
                            }
                        ), let recText = recovered.content, !recText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            let combinedReasoning = recovered.reasoning ?? reasoning
                            streamingState.finishImmediate(with: recText, finalReasoning: combinedReasoning)
                            conversation.messages[msgIndex].content = recText
                            conversation.messages[msgIndex].reasoningContent = combinedReasoning
                        }
                    }
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
            activeTurnId = nil
            activeTurnPrompt = nil
        }
    }
}
