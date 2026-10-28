import Foundation

struct ContextPruningResult {
    var messages: [ChatMessage]
    var didPrune: Bool
    var estimatedInputTokens: Int
    var toolSchemaTokens: Int
    var inputBudgetTokens: Int
    var fitsBudget: Bool
}

enum ContextPruner {
    static let contextNotice = "本次请求按上下文预算省略或截短了较早消息或已处理的工具记录；完整聊天记录仍保留在本地。"
    private static let toolTruncationNotice = "[工具结果因上下文预算截短；完整结果仍保留在本地聊天记录中。]"
    private static let messageTruncationNotice = "[消息内容因上下文预算截短；完整内容仍保留在本地聊天记录中。]"

    private enum TextField {
        case content
        case attachmentText(Int)
    }

    private struct ToolCallGroup {
        var messageId: String
        var callIDs: Set<String>
    }

    static func prepare(
        settings: OpenAISettings,
        messages: [ChatMessage],
        tools: [[String: Any]]?
    ) -> ContextPruningResult {
        let schemaTokens = toolSchemaTokens(tools)
        let contextLimit = max(4_096, settings.contextWindowTokens)
        let outputReserve = max(512, min(contextLimit / 10, 8_192))
        let inputBudget = max(1, contextLimit - outputReserve)
        let baseInstructionTokens = estimatedTokenCount(settings.systemPrompt) + schemaTokens + 4
        var prepared = messages
        var didPrune = false

        func totalTokens(_ items: [ChatMessage]) -> Int {
            baseInstructionTokens
                + estimatedMessageTokens(items)
                + (didPrune ? estimatedTokenCount(contextNotice) + 2 : 0)
        }

        if totalTokens(prepared) > inputBudget {
            let groups = turnRanges(in: prepared).flatMap { turn in
                toolCallGroups(in: turn, messages: prepared)
            }
            for group in groups.dropLast() {
                guard totalTokens(prepared) > inputBudget else { break }
                let resultIDs = Set(prepared.compactMap { message in
                    message.role == .tool ? message.toolCallId : nil
                })
                guard group.callIDs.isSubset(of: resultIDs) else { continue }
                didPrune = true
                if let index = prepared.firstIndex(where: { $0.id == group.messageId }) {
                    if prepared[index].content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        prepared.remove(at: index)
                    } else {
                        prepared[index].toolCalls = nil
                    }
                }
                prepared.removeAll { message in
                    message.role == .tool && group.callIDs.contains(message.toolCallId ?? "")
                }
            }
        }

        while totalTokens(prepared) > inputBudget {
            let turns = turnRanges(in: prepared)
            guard turns.count > 1, let oldestTurn = turns.first else { break }
            prepared.removeSubrange(oldestTurn)
            didPrune = true
        }

        if totalTokens(prepared) > inputBudget {
            let currentTurn = turnRanges(in: prepared).last ?? (0..<prepared.count)
            let groups = toolCallGroups(in: currentTurn, messages: prepared)
            for group in groups.dropLast() {
                guard totalTokens(prepared) > inputBudget else { break }
                let resultIDs = Set(prepared.compactMap { message in
                    message.role == .tool ? message.toolCallId : nil
                })
                guard group.callIDs.isSubset(of: resultIDs) else { continue }
                didPrune = true
                if let index = prepared.firstIndex(where: { $0.id == group.messageId }) {
                    if prepared[index].content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        prepared.remove(at: index)
                    } else {
                        prepared[index].toolCalls = nil
                    }
                }
                prepared.removeAll { message in
                    message.role == .tool && group.callIDs.contains(message.toolCallId ?? "")
                }
            }
        }

        if totalTokens(prepared) > inputBudget {
            for index in prepared.indices where prepared[index].role == .tool {
                guard totalTokens(prepared) > inputBudget else { break }
                let original = prepared[index].content
                guard !original.isEmpty else { continue }
                didPrune = true
                prepared[index].content = bestFittingText(
                    original,
                    notice: toolTruncationNotice,
                    messages: prepared,
                    messageIndex: index,
                    field: .content,
                    inputBudget: inputBudget,
                    totalTokens: totalTokens
                )
            }
        }

        if totalTokens(prepared) > inputBudget {
            let currentTurn = turnRanges(in: prepared).last ?? (0..<prepared.count)
            for index in currentTurn where prepared[index].role == .assistant {
                guard totalTokens(prepared) > inputBudget else { break }
                let original = prepared[index].content
                guard !original.isEmpty else { continue }
                didPrune = true
                prepared[index].content = bestFittingText(
                    original,
                    notice: messageTruncationNotice,
                    messages: prepared,
                    messageIndex: index,
                    field: .content,
                    inputBudget: inputBudget,
                    totalTokens: totalTokens
                )
            }

            for index in currentTurn where prepared[index].role == .user {
                guard totalTokens(prepared) > inputBudget else { break }
                let attachmentIndices = (prepared[index].attachments ?? []).indices
                for attachmentIndex in attachmentIndices {
                    guard totalTokens(prepared) > inputBudget else { break }
                    guard let original = prepared[index].attachments?[attachmentIndex].textContent,
                          !original.isEmpty else { continue }
                    didPrune = true
                    let replacement = bestFittingText(
                        original,
                        notice: messageTruncationNotice,
                        messages: prepared,
                        messageIndex: index,
                        field: .attachmentText(attachmentIndex),
                        inputBudget: inputBudget,
                        totalTokens: totalTokens
                    )
                    var attachments = prepared[index].attachments ?? []
                    attachments[attachmentIndex].textContent = replacement
                    prepared[index].attachments = attachments
                }

                guard totalTokens(prepared) > inputBudget else { continue }
                let original = prepared[index].content
                guard !original.isEmpty else { continue }
                didPrune = true
                prepared[index].content = bestFittingText(
                    original,
                    notice: messageTruncationNotice,
                    messages: prepared,
                    messageIndex: index,
                    field: .content,
                    inputBudget: inputBudget,
                    totalTokens: totalTokens
                )
            }
        }

        let estimatedTokens = totalTokens(prepared)
        return ContextPruningResult(
            messages: prepared,
            didPrune: didPrune,
            estimatedInputTokens: estimatedTokens,
            toolSchemaTokens: schemaTokens,
            inputBudgetTokens: inputBudget,
            fitsBudget: estimatedTokens <= inputBudget
        )
    }

    private static func toolCallGroups(in range: Range<Int>, messages: [ChatMessage]) -> [ToolCallGroup] {
        range.compactMap { index in
            let message = messages[index]
            guard message.role == .assistant,
                  let calls = message.toolCalls,
                  !calls.isEmpty else { return nil }
            return ToolCallGroup(messageId: message.id, callIDs: Set(calls.map(\.id)))
        }
    }

    private static func toolSchemaTokens(_ tools: [[String: Any]]?) -> Int {
        guard let tools, !tools.isEmpty,
              let data = try? JSONSerialization.data(withJSONObject: tools, options: [.sortedKeys]),
              let serialized = String(data: data, encoding: .utf8) else { return 0 }
        return estimatedTokenCount(serialized)
    }

    private static func estimatedMessageTokens(_ messages: [ChatMessage]) -> Int {
        messages.reduce(0) { total, message in
            var messageTokens = estimatedTokenCount(serializedText(for: message)) + 4
            messageTokens += estimatedTokenCount(message.toolCallId ?? "")
            if message.role == .user {
                messageTokens += (message.attachments ?? []).reduce(0) { count, attachment in
                    count + (attachment.kind == .image && !(attachment.imageDataBase64 ?? "").isEmpty ? 1_536 : 0)
                }
            }
            for call in message.toolCalls ?? [] {
                messageTokens += 8 + estimatedTokenCount(call.name) + estimatedTokenCount(call.arguments)
            }
            return total + messageTokens
        }
    }

    private static func serializedText(for message: ChatMessage) -> String {
        var combinedText = message.content
        for attachment in message.attachments ?? [] {
            switch attachment.kind {
            case .longText:
                if let text = attachment.textContent, !text.isEmpty {
                    combinedText = combinedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        ? text
                        : combinedText + "\n\n" + text
                }
            case .file:
                if let text = attachment.textContent, !text.isEmpty {
                    let block = "--- 文件: \(attachment.fileName) ---\n\(text)\n--- 文件结束 ---"
                    combinedText = combinedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        ? block
                        : combinedText + "\n\n" + block
                }
            case .image:
                break
            }
        }
        return combinedText
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

    private static func bestFittingText(
        _ original: String,
        notice: String,
        messages: [ChatMessage],
        messageIndex: Int,
        field: TextField,
        inputBudget: Int,
        totalTokens: ([ChatMessage]) -> Int
    ) -> String {
        var low = 0
        var high = original.count
        var best = ""

        while low <= high {
            let retainedCharacters = (low + high) / 2
            let candidate = boundedText(original, retainedCharacters: retainedCharacters, notice: notice)
            let candidateMessages = replacingText(candidate, in: messages, messageIndex: messageIndex, field: field)
            if totalTokens(candidateMessages) <= inputBudget {
                best = candidate
                low = retainedCharacters + 1
            } else {
                high = retainedCharacters - 1
            }
        }

        return best
    }

    private static func boundedText(_ text: String, retainedCharacters: Int, notice: String) -> String {
        guard retainedCharacters < text.count else { return text }
        guard retainedCharacters > 0 else { return notice }
        let headCount = retainedCharacters * 2 / 3
        let tailCount = retainedCharacters - headCount
        return String(text.prefix(headCount))
            + "\n…\n"
            + String(text.suffix(tailCount))
            + "\n\n"
            + notice
    }

    private static func replacingText(
        _ text: String,
        in messages: [ChatMessage],
        messageIndex: Int,
        field: TextField
    ) -> [ChatMessage] {
        var replacement = messages
        switch field {
        case .content:
            replacement[messageIndex].content = text
        case .attachmentText(let attachmentIndex):
            guard var attachments = replacement[messageIndex].attachments,
                  attachments.indices.contains(attachmentIndex) else { return replacement }
            attachments[attachmentIndex].textContent = text
            replacement[messageIndex].attachments = attachments
        }
        return replacement
    }
}

