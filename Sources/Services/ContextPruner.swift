import Foundation

struct ContextPruningResult {
    var messages: [ChatMessage]
    var didPrune: Bool
    var estimatedInputTokens: Int
    var toolSchemaTokens: Int
}

enum ContextPruner {
    private static let contextNotice = "本次请求因上下文预算压缩了较早对话或已处理的工具结果；未发送的历史仍保留在本地聊天记录中。"
    private static let truncationNotice = "[工具结果已为控制上下文截短；完整结果仍保留在本地聊天记录中。]"

    static func prepare(
        settings: OpenAISettings,
        messages: [ChatMessage],
        tools: [[String: Any]]?
    ) -> ContextPruningResult {
        guard !messages.isEmpty else {
            return ContextPruningResult(messages: [], didPrune: false, estimatedInputTokens: instructionTokens(settings: settings, tools: tools), toolSchemaTokens: toolSchemaTokens(tools))
        }

        let schemaTokens = toolSchemaTokens(tools)
        let baseInstructionTokens = estimatedTokenCount(settings.systemPrompt) + schemaTokens + 4
        let contextLimit = max(4_096, settings.contextWindowTokens)
        let outputReserve = max(512, min(contextLimit / 10, 8_192))
        let inputBudget = max(1, contextLimit - outputReserve)
        var prepared = messages
        var didPrune = false

        func totalTokens(_ items: [ChatMessage]) -> Int {
            baseInstructionTokens + estimatedMessageTokens(items) + (didPrune ? estimatedTokenCount(contextNotice) : 0)
        }

        if totalTokens(prepared) > inputBudget * 4 / 5 {
            for index in prepared.indices where prepared[index].role == .tool && isConsumedToolResult(at: index, in: prepared) {
                let compacted = compact(prepared[index].content, characterLimit: 300)
                if compacted != prepared[index].content {
                    prepared[index].content = compacted
                    didPrune = true
                }
            }
        }

        var turns = turnRanges(in: prepared)
        while totalTokens(prepared) > inputBudget, turns.count > 1 {
            let oldestTurn = turns.removeFirst()
            prepared.removeSubrange(oldestTurn)
            didPrune = true
            turns = turnRanges(in: prepared)
        }

        if totalTokens(prepared) > inputBudget {
            let currentTurn = turnRanges(in: prepared).last ?? (0..<prepared.count)
            let callMessages = currentTurn.compactMap { index -> (Int, Set<String>)? in
                let message = prepared[index]
                guard message.role == .assistant,
                      let calls = message.toolCalls,
                      !calls.isEmpty else { return nil }
                return (index, Set(calls.map(\.id)))
            }

            if callMessages.count > 1 {
                for (index, callIDs) in callMessages.dropLast() {
                    let message = prepared[index]
                    if message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        prepared[index].toolCalls = nil
                    } else {
                        prepared[index].toolCalls = nil
                    }
                    for toolIndex in prepared.indices.reversed() where prepared[toolIndex].role == .tool && callIDs.contains(prepared[toolIndex].toolCallId ?? "") {
                        prepared.remove(at: toolIndex)
                    }
                    didPrune = true
                }
            }
        }

        if totalTokens(prepared) > inputBudget {
            truncateToolResults(&prepared, availableTokens: max(0, inputBudget - baseInstructionTokens - estimatedTokenCount(contextNotice)), notice: truncationNotice)
            didPrune = true
        }

        return ContextPruningResult(
            messages: prepared,
            didPrune: didPrune,
            estimatedInputTokens: totalTokens(prepared),
            toolSchemaTokens: schemaTokens
        )
    }

    private static func instructionTokens(settings: OpenAISettings, tools: [[String: Any]]?) -> Int {
        estimatedTokenCount(settings.systemPrompt) + toolSchemaTokens(tools) + 4
    }

    private static func toolSchemaTokens(_ tools: [[String: Any]]?) -> Int {
        guard let tools, !tools.isEmpty,
              let data = try? JSONSerialization.data(withJSONObject: tools, options: [.sortedKeys]),
              let serialized = String(data: data, encoding: .utf8) else { return 0 }
        return estimatedTokenCount(serialized)
    }

    private static func estimatedMessageTokens(_ messages: [ChatMessage]) -> Int {
        messages.reduce(0) { total, message in
            var messageTokens = estimatedTokenCount(message.content) + 4
            messageTokens += estimatedTokenCount(message.toolCallId ?? "")

            for attachment in message.attachments ?? [] {
                messageTokens += estimatedTokenCount(attachment.fileName)
                if attachment.kind == .image {
                    messageTokens += 1_536
                } else {
                    messageTokens += estimatedTokenCount(attachment.textContent ?? "")
                }
            }

            for call in message.toolCalls ?? [] {
                messageTokens += 8 + estimatedTokenCount(call.name) + estimatedTokenCount(call.arguments)
            }
            return total + messageTokens
        }
    }

    private static func estimatedTokenCount(_ text: String) -> Int {
        var tokens = 0
        var asciiRunLength = 0

        func flushASCIIRun() {
            if asciiRunLength > 0 {
                tokens += (asciiRunLength + 3) / 4
                asciiRunLength = 0
            }
        }

        for scalar in text.unicodeScalars {
            if scalar.value < 128 {
                let value = scalar.value
                let isWordCharacter = (value >= 48 && value <= 57)
                    || (value >= 65 && value <= 90)
                    || (value >= 97 && value <= 122)
                    || value == 95
                if isWordCharacter {
                    asciiRunLength += 1
                } else {
                    flushASCIIRun()
                    if !CharacterSet.whitespacesAndNewlines.contains(scalar) {
                        tokens += 1
                    }
                }
            } else {
                flushASCIIRun()
                tokens += 1
            }
        }
        flushASCIIRun()
        return tokens
    }

    private static func turnRanges(in messages: [ChatMessage]) -> [Range<Int>] {
        guard !messages.isEmpty else { return [] }
        var starts = messages.indices.filter { messages[$0].role == .user }
        if starts.isEmpty {
            return [0..<messages.count]
        }
        if starts[0] > 0 {
            starts.insert(0, at: 0)
        }
        return starts.indices.map { offset in
            let start = starts[offset]
            let end = offset + 1 < starts.count ? starts[offset + 1] : messages.count
            return start..<end
        }
    }

    private static func isConsumedToolResult(at index: Int, in messages: [ChatMessage]) -> Bool {
        guard index + 1 < messages.count else { return false }
        return messages[(index + 1)...].contains { message in
            message.role == .assistant && !message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    private static func compact(_ text: String, characterLimit: Int) -> String {
        guard text.count > characterLimit else { return text }
        let headCount = characterLimit * 2 / 3
        let tailCount = characterLimit - headCount
        return String(text.prefix(headCount)) + "\n…\n" + String(text.suffix(tailCount))
    }

    private static func truncateToolResults(_ messages: inout [ChatMessage], availableTokens: Int, notice: String) {
        var remainingTokens = availableTokens
        for index in messages.indices.reversed() where messages[index].role == .tool {
            let original = messages[index].content
            let originalTokens = estimatedTokenCount(original)
            if originalTokens <= remainingTokens {
                remainingTokens -= originalTokens
                continue
            }

            let replacement = truncatedContent(original, maxTokens: remainingTokens, notice: notice)
            messages[index].content = replacement
            remainingTokens = max(0, remainingTokens - estimatedTokenCount(replacement))
        }
    }

    private static func truncatedContent(_ text: String, maxTokens: Int, notice: String) -> String {
        guard maxTokens > 0 else { return "" }
        if estimatedTokenCount(text) <= maxTokens { return text }
        if estimatedTokenCount(notice) >= maxTokens {
            return String(text.prefix(maxTokens))
        }

        let availableTextTokens = maxTokens - estimatedTokenCount(notice)
        var low = 0
        var high = text.count
        var best = ""

        while low <= high {
            let retainedCount = (low + high) / 2
            let headCount = retainedCount * 2 / 3
            let tailCount = retainedCount - headCount
            let candidate = String(text.prefix(headCount)) + "\n…\n" + String(text.suffix(tailCount))
            if estimatedTokenCount(candidate) <= availableTextTokens {
                best = candidate
                low = retainedCount + 1
            } else {
                high = retainedCount - 1
            }
        }

        return best + "\n\n" + notice
    }
}
