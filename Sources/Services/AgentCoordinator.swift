import Foundation
import SwiftUI
import Combine

@MainActor
final class StreamingTurnState: ObservableObject {
    @Published var activeMessageId: String? = nil
    @Published var displayedText: String = ""
    @Published var displayedReasoning: String = ""
    @Published var isStreamingReasoning: Bool = false

    var isScrollInteracting: Bool { false }

    private var targetText: String = ""
    private var targetReasoning: String = ""
    private var displayedTextUTF8Count: Int = 0
    private var displayedReasoningUTF8Count: Int = 0
    private var isStreamComplete: Bool = false
    private var drainTimer: Timer? = nil

    private static let tickInterval: TimeInterval = 0.032

    func begin(messageId: String) {
        stopDrainTimer()
        targetText = ""
        targetReasoning = ""
        displayedTextUTF8Count = 0
        displayedReasoningUTF8Count = 0
        isStreamComplete = false

        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            activeMessageId = messageId
            displayedText = ""
            displayedReasoning = ""
            isStreamingReasoning = false
        }
    }

    func setDisplayPaused(_ paused: Bool) {
        // 不再在用户触摸滚动时冻结文本输出，避免松手瞬间大量积压文本一次性暴涨导致高度跳变
    }

    func pushPartialText(_ newText: String) {
        guard targetText.utf8.count != newText.utf8.count || targetText != newText else { return }
        targetText = newText

        if displayedTextUTF8Count == 0 && !newText.isEmpty {
            let (initialSlice, byteCount) = Self.safeUTF8Prefix(of: newText, targetBytes: 54)
            displayedTextUTF8Count = byteCount
            commitDisplayed(text: initialSlice, reasoning: nil, streamingReasoning: false)
        } else if isStreamingReasoning {
            commitDisplayed(text: nil, reasoning: nil, streamingReasoning: false)
        }
        ensureDrainTimer()
    }

    func pushPartialReasoning(_ newReasoning: String) {
        guard targetReasoning.utf8.count != newReasoning.utf8.count || targetReasoning != newReasoning else { return }
        targetReasoning = newReasoning

        let stillOnlyReasoning = targetText.isEmpty && !newReasoning.isEmpty
        if displayedReasoningUTF8Count == 0 && !newReasoning.isEmpty {
            displayedReasoningUTF8Count = newReasoning.utf8.count
            commitDisplayed(text: nil, reasoning: newReasoning, streamingReasoning: stillOnlyReasoning)
        }
        ensureDrainTimer()
    }

    private func ensureDrainTimer() {
        guard drainTimer == nil else { return }
        let timer = Timer(timeInterval: Self.tickInterval, repeats: true) { [weak self] _ in
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
        var nextText: String? = nil
        var nextReasoning: String? = nil

        let targetReasoningBytes = targetReasoning.utf8.count
        if displayedReasoningUTF8Count != targetReasoningBytes {
            displayedReasoningUTF8Count = targetReasoningBytes
            nextReasoning = targetReasoning
        }

        let targetTextBytes = targetText.utf8.count
        if displayedTextUTF8Count != targetTextBytes {
            if targetTextBytes < displayedTextUTF8Count {
                displayedTextUTF8Count = targetTextBytes
                nextText = targetText
            } else {
                let remainingBytes = targetTextBytes - displayedTextUTF8Count
                let stepBytes: Int
                if isStreamComplete {
                    stepBytes = max(96, (remainingBytes + 1) / 2)
                } else if remainingBytes > 600 {
                    stepBytes = max(140, remainingBytes / 3)
                } else if remainingBytes > 240 {
                    stepBytes = max(72, remainingBytes / 3)
                } else if remainingBytes > 90 {
                    stepBytes = max(36, remainingBytes / 3)
                } else if remainingBytes > 24 {
                    stepBytes = 20
                } else {
                    stepBytes = remainingBytes
                }
                let desiredBytes = min(targetTextBytes, displayedTextUTF8Count + stepBytes)
                let (slice, actualBytes) = Self.safeUTF8Prefix(of: targetText, targetBytes: desiredBytes)
                displayedTextUTF8Count = actualBytes
                nextText = slice
            }
        }

        let nextStreamingReasoning = (targetTextBytes == 0 && targetReasoningBytes > 0 && !isStreamComplete)
        if nextText != nil || nextReasoning != nil || isStreamingReasoning != nextStreamingReasoning {
            commitDisplayed(text: nextText, reasoning: nextReasoning, streamingReasoning: nextStreamingReasoning)
        }

        if displayedTextUTF8Count == targetTextBytes && displayedReasoningUTF8Count == targetReasoningBytes {
            stopDrainTimer()
        }
    }

    private static func safeUTF8Prefix(of text: String, targetBytes: Int) -> (String, Int) {
        let utf8 = text.utf8
        let total = utf8.count
        guard targetBytes < total else {
            return (text, total)
        }
        guard targetBytes > 0 else {
            return ("", 0)
        }

        var utf8Index = utf8.index(utf8.startIndex, offsetBy: targetBytes)
        while utf8Index < utf8.endIndex && (utf8[utf8Index] & 0xC0) == 0x80 {
            utf8Index = utf8.index(after: utf8Index)
        }

        guard let scalarIndex = utf8Index.samePosition(in: text), scalarIndex < text.endIndex else {
            return (text, total)
        }

        let composedRange = text.rangeOfComposedCharacterSequence(at: scalarIndex)
        let alignedIndex = composedRange.lowerBound < scalarIndex ? composedRange.upperBound : scalarIndex
        if alignedIndex >= text.endIndex {
            return (text, total)
        }
        let slice = String(text[..<alignedIndex])
        return (slice, slice.utf8.count)
    }

    private func commitDisplayed(text: String?, reasoning: String?, streamingReasoning: Bool?) {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            if let text = text, displayedText != text {
                displayedText = text
            }
            if let reasoning = reasoning, displayedReasoning != reasoning {
                displayedReasoning = reasoning
            }
            if let streamingReasoning = streamingReasoning, isStreamingReasoning != streamingReasoning {
                isStreamingReasoning = streamingReasoning
            }
        }
    }

    func prepareForContinuation() {
        isStreamComplete = false
    }

    func finishImmediate(with finalText: String, finalReasoning: String? = nil) {
        stopDrainTimer()
        targetText = finalText
        displayedTextUTF8Count = finalText.utf8.count
        if let finalReasoning = finalReasoning {
            targetReasoning = finalReasoning
            displayedReasoningUTF8Count = finalReasoning.utf8.count
        }
        isStreamComplete = true
        commitDisplayed(text: finalText, reasoning: finalReasoning, streamingReasoning: false)
    }

    func reset() {
        stopDrainTimer()
        targetText = ""
        targetReasoning = ""
        displayedTextUTF8Count = 0
        displayedReasoningUTF8Count = 0
        isStreamComplete = false

        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            activeMessageId = nil
            displayedText = ""
            displayedReasoning = ""
            isStreamingReasoning = false
        }
    }
}

@MainActor
final class GenerationActivityTracker: ObservableObject {
    static let shared = GenerationActivityTracker()

    @Published private(set) var labels: [String: String] = [:]

    func set(_ label: String?, for conversationId: String) {
        if let label = label, !label.isEmpty {
            guard labels[conversationId] != label else { return }
            labels[conversationId] = label
        } else {
            guard labels[conversationId] != nil else { return }
            labels.removeValue(forKey: conversationId)
        }
    }
}

final class ContextTokenStore: ObservableObject {
    static let shared = ContextTokenStore()

    struct Entry: Codable, Equatable {
        var count: Int
    }

    @Published private(set) var entries: [String: Entry]

    private let storageKey = "OpenMCP_ContextTokenEntries_v2"

    private init() {
        UserDefaults.standard.removeObject(forKey: "OpenMCP_ContextTokenEntries")
        UserDefaults.standard.removeObject(forKey: "OpenMCP_MeasuredToolTokens")
        if let data = UserDefaults.standard.data(forKey: storageKey),
           let decoded = try? JSONDecoder().decode([String: Entry].self, from: data) {
            entries = decoded
        } else {
            entries = [:]
        }
    }

    func set(_ count: Int, for conversationId: String) {
        let entry = Entry(count: max(0, count))
        guard entries[conversationId] != entry else { return }
        entries[conversationId] = entry
        persist()
    }

    func remove(_ conversationId: String) {
        guard entries.removeValue(forKey: conversationId) != nil else { return }
        persist()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(entries) {
            UserDefaults.standard.set(data, forKey: storageKey)
        }
    }
}

@MainActor
class AgentCoordinator: ObservableObject {
    @Published var isGenerating: Bool = false {
        didSet {
            publishActivity(isGenerating ? (statusText.isEmpty ? "思考中" : statusText) : nil)
        }
    }
    @Published var statusText: String = "" {
        didSet {
            publishActivity(isGenerating && !statusText.isEmpty ? statusText : nil)
        }
    }
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

    private static func readableToolName(_ rawName: String) -> String {
        let parts = rawName.split(separator: "_", maxSplits: 1, omittingEmptySubsequences: false)
        if parts.count == 2, parts[0].count == 6, parts[0].allSatisfy({ $0.isHexDigit }) {
            return String(parts[1])
        }
        return rawName
    }

    private func publishActivity(_ label: String?) {
        guard let conversationId = activeConversationId else { return }
        GenerationActivityTracker.shared.set(label, for: conversationId)
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

        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
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

        let preparedTools = OpenAIService.shared.prepareTools(servers: servers)
        let availableMCPTools = preparedTools.definitions
        let toolServerMap = preparedTools.serverMap
        var selectedMCPTools: [[String: Any]] = []
        var discoveryAttempts = 0
        var requestMessages = conversation.messages
        var stepIndex = 0

        while true {
            if isCancelledByUser || Task.isCancelled {
                return
            }
            stepIndex += 1
            let contextMessages = requestMessages
            let requestTools: [[String: Any]]? = {
                guard !availableMCPTools.isEmpty else { return nil }
                var tools = selectedMCPTools
                if discoveryAttempts < MCPToolDiscovery.maximumSearchRounds {
                    tools.append(MCPToolDiscovery.definition)
                }
                return tools.isEmpty ? nil : tools
            }()
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
                    tools: requestTools,
                    conversationId: conversationId,
                    conversationTitle: conversation.title,
                    turnId: turnId,
                    turnPrompt: turnPrompt,
                    stepIndex: stepIndex,
                    onPartialUpdate: { [weak self] partialText in
                        guard let self = self, !self.isCancelledByUser, !Task.isCancelled else { return }
                        if !partialText.isEmpty {
                            self.publishActivity("输出中")
                        }
                        self.streamingState.pushPartialText(partialText)
                    },
                    onReasoningUpdate: { [weak self] partialReasoning in
                        guard let self = self, !self.isCancelledByUser, !Task.isCancelled else { return }
                        if !partialReasoning.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            self.publishActivity("深度思考中")
                        }
                        self.streamingState.pushPartialReasoning(partialReasoning)
                    },
                    onContextTokenCount: { count in
                        ContextTokenStore.shared.set(count, for: conversationId)
                    }
                )

                if isCancelledByUser || Task.isCancelled {
                    return
                }

                let finalText = content ?? ""
                streamingState.finishImmediate(with: finalText, finalReasoning: reasoning)

                conversation.messages[msgIndex].content = finalText
                conversation.messages[msgIndex].reasoningContent = reasoning
                DataStorage.shared.updateConversation(conversation, persistImmediately: false)

                if let calls = toolCalls, !calls.isEmpty {
                    let requestAssistantMessage = ChatMessage(
                        role: .assistant,
                        content: finalText,
                        reasoningContent: reasoning,
                        toolCalls: calls
                    )
                    let previouslyExposedToolNames = Set(selectedMCPTools.compactMap {
                        ($0["function"] as? [String: Any])?["name"] as? String
                    })
                    let discoveryCalls = calls.filter { MCPToolDiscovery.isDiscoveryCall(name: $0.name) }
                    let actualCalls = calls.filter { !MCPToolDiscovery.isDiscoveryCall(name: $0.name) }
                    var requestResultsByCallId: [String: ChatMessage] = [:]

                    if let discoveryCall = discoveryCalls.first {
                        statusText = "检索相关工具中"
                        discoveryAttempts = min(
                            MCPToolDiscovery.maximumSearchRounds,
                            discoveryAttempts + discoveryCalls.count
                        )
                        let query = MCPToolDiscovery.query(from: discoveryCall.arguments)
                        selectedMCPTools = MCPToolDiscovery.selectTools(
                            query: query,
                            allTools: availableMCPTools,
                            existingTools: selectedMCPTools,
                            settings: effectiveSettings,
                            messages: contextMessages
                        )
                        requestResultsByCallId[discoveryCall.id] = ChatMessage(
                            role: .tool,
                            content: MCPToolDiscovery.result(query: query, tools: selectedMCPTools),
                            toolCallId: discoveryCall.id
                        )
                        for extraCall in discoveryCalls.dropFirst() {
                            requestResultsByCallId[extraCall.id] = ChatMessage(
                                role: .tool,
                                content: "本轮已处理一个工具搜索请求；如需其他工具，请在下一轮继续搜索。",
                                toolCallId: extraCall.id
                            )
                        }
                    }

                    var executingCalls = actualCalls.map { call -> ToolCallItem in
                        var item = call
                        item.isExecuting = true
                        return item
                    }
                    conversation.messages[msgIndex].toolCalls = executingCalls.isEmpty ? nil : executingCalls
                    if !executingCalls.isEmpty {
                        DataStorage.shared.updateConversation(conversation, persistImmediately: false)
                    }

                    for i in executingCalls.indices {
                        if isCancelledByUser || Task.isCancelled {
                            return
                        }
                        let call = executingCalls[i]
                        statusText = "调用工具: \(Self.readableToolName(call.name))"

                        var toolOutput = ""
                        if previouslyExposedToolNames.contains(call.name),
                           let mapping = toolServerMap[call.name] {
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
                        requestResultsByCallId[call.id] = toolMsg
                        DataStorage.shared.updateConversation(conversation, persistImmediately: false)
                    }

                    requestMessages.append(requestAssistantMessage)
                    for call in calls {
                        if let result = requestResultsByCallId[call.id] {
                            requestMessages.append(result)
                        }
                    }

                    if actualCalls.isEmpty,
                       finalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                       (reasoning ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                       msgIndex < conversation.messages.count {
                        conversation.messages.remove(at: msgIndex)
                        currentRunGeneratedMessageIds.remove(placeholderMsg.id)
                    }
                    DataStorage.shared.updateConversation(conversation, persistImmediately: true)
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
                                if !partialReasoning.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                    self.publishActivity("深度思考中")
                                }
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
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                isGenerating = false
                streamingState.reset()
                thinkingStartTime = nil
                statusText = ""
            }
            currentRunGeneratedMessageIds.removeAll()
            releaseAfterGeneration(activeConversationId)
            activeConversationId = nil
            activeTurnId = nil
            activeTurnPrompt = nil
        }
    }
}
