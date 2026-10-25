import Foundation

class OpenAIService {
    static let shared = OpenAIService()

    func fetchModels(settings: OpenAISettings) async throws -> [String] {
        var base = settings.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if base.hasSuffix("/") {
            base = String(base.dropLast())
        }
        if base.hasSuffix("/chat/completions") {
            base = String(base.dropLast("/chat/completions".count))
        }
        let fullEndpoint = "\(base)/models"
        guard let url = URL(string: fullEndpoint) else {
            throw URLError(.badURL)
        }

        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if !settings.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let key = settings.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
            req.setValue(key.hasPrefix("Bearer ") ? key : "Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        req.timeoutInterval = 30

        let (data, response) = try await URLSession.shared.data(for: req)
        guard let httpRes = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }

        guard (200...299).contains(httpRes.statusCode) else {
            let errString = String(data: data, encoding: .utf8) ?? ""
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let errObj = json["error"] as? [String: Any],
               let msg = errObj["message"] as? String {
                throw NSError(domain: "OpenAIService", code: httpRes.statusCode, userInfo: [NSLocalizedDescriptionKey: msg])
            }
            throw NSError(domain: "OpenAIService", code: httpRes.statusCode, userInfo: [NSLocalizedDescriptionKey: "获取模型失败 (\(httpRes.statusCode)): \(errString.prefix(200))"])
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NSError(domain: "OpenAIService", code: -1, userInfo: [NSLocalizedDescriptionKey: "无法解析模型列表数据"])
        }

        var modelIds: [String] = []
        if let dataArray = json["data"] as? [[String: Any]] {
            for item in dataArray {
                if let id = item["id"] as? String {
                    modelIds.append(id)
                }
            }
        } else if let modelsArray = json["models"] as? [[String: Any]] {
            for item in modelsArray {
                if let id = item["id"] as? String ?? item["name"] as? String {
                    modelIds.append(id)
                }
            }
        }

        return modelIds.sorted()
    }

    func streamChatCompletion(
        settings: OpenAISettings,
        messages: [ChatMessage],
        tools: [[String: Any]]? = nil,
        onPartialUpdate: (@MainActor (String) -> Void)? = nil,
        onReasoningUpdate: (@MainActor (String) -> Void)? = nil
    ) async throws -> (content: String?, reasoning: String?, toolCalls: [ToolCallItem]?) {
        var base = settings.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if base.hasSuffix("/") {
            base = String(base.dropLast())
        }
        let fullEndpoint = base.hasSuffix("/chat/completions") ? base : "\(base)/chat/completions"
        guard let url = URL(string: fullEndpoint) else {
            throw URLError(.badURL)
        }

        let openAIMessages = buildOpenAIMessages(settings: settings, messages: messages)

        var payload: [String: Any] = [
            "model": settings.modelName,
            "temperature": settings.temperature,
            "messages": openAIMessages,
            "stream": true
        ]

        if let tools = tools, !tools.isEmpty {
            payload["tools"] = tools
        }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        req.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        if !settings.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let key = settings.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
            req.setValue(key.hasPrefix("Bearer ") ? key : "Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        req.httpBody = try JSONSerialization.data(withJSONObject: payload)
        req.timeoutInterval = 300

        let (bytes, response) = try await URLSession.shared.bytes(for: req)
        try Task.checkCancellation()

        guard let httpRes = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }

        guard (200...299).contains(httpRes.statusCode) else {
            var errorData = Data()
            for try await byte in bytes {
                try Task.checkCancellation()
                errorData.append(byte)
                if errorData.count > 8192 { break }
            }
            let errString = String(data: errorData, encoding: .utf8) ?? ""
            if let json = try? JSONSerialization.jsonObject(with: errorData) as? [String: Any],
               let errObj = json["error"] as? [String: Any],
               let msg = errObj["message"] as? String {
                throw NSError(domain: "OpenAIService", code: httpRes.statusCode, userInfo: [NSLocalizedDescriptionKey: msg])
            }
            throw NSError(domain: "OpenAIService", code: httpRes.statusCode, userInfo: [NSLocalizedDescriptionKey: "API 响应错误 (\(httpRes.statusCode)): \(errString.prefix(200))"])
        }

        let contentType = (httpRes.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
        if !contentType.contains("event-stream") && contentType.contains("application/json") {
            var rawData = Data()
            for try await byte in bytes {
                try Task.checkCancellation()
                rawData.append(byte)
            }
            if let json = try? JSONSerialization.jsonObject(with: rawData) as? [String: Any] {
                let parsed = try parseNonStreamingJSON(json)
                if let r = parsed.reasoning, !r.isEmpty {
                    await onReasoningUpdate?(r)
                }
                if let text = parsed.content, !text.isEmpty {
                    await onPartialUpdate?(text)
                }
                return parsed
            }
        }

        var accumulatedContent = ""
        var accumulatedReasoning = ""
        struct PartialToolCall {
            var id: String = ""
            var name: String = ""
            var arguments: String = ""
        }
        var toolCallsByIndex: [Int: PartialToolCall] = [:]
        var nonSSELines: [String] = []
        var receivedSSEEvent = false
        var lastYieldTime = CFAbsoluteTimeGetCurrent()
        var lastReasoningYieldTime = CFAbsoluteTimeGetCurrent()
        var lastFlushedLength = 0
        var lastFlushedReasoningLength = 0
        var lineBuffer = Data()

        func processLine(_ rawLine: String) async throws -> Bool {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty { return false }
            if line.hasPrefix(":") || line.hasPrefix("event:") || line.hasPrefix("id:") || line.hasPrefix("retry:") {
                return false
            }

            if !line.hasPrefix("data:") {
                if !receivedSSEEvent {
                    nonSSELines.append(rawLine)
                }
                return false
            }

            receivedSSEEvent = true
            let dataStr = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
            if dataStr == "[DONE]" {
                return true
            }
            guard let data = dataStr.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return false
            }

            if let errObj = json["error"] as? [String: Any],
               let msg = errObj["message"] as? String {
                throw NSError(domain: "OpenAIService", code: -1, userInfo: [NSLocalizedDescriptionKey: msg])
            }

            let eventType = json["type"] as? String ?? ""
            var contentPiece: String? = nil
            var reasoningPiece: String? = nil

            if let choices = json["choices"] as? [[String: Any]],
               let firstChoice = choices.first {
                if let delta = firstChoice["delta"] as? [String: Any] {
                    if let c = delta["content"] as? String, !c.isEmpty {
                        contentPiece = c
                    }
                    if let r = delta["reasoning_content"] as? String, !r.isEmpty {
                        reasoningPiece = r
                    } else if let r = delta["reasoning"] as? String, !r.isEmpty {
                        reasoningPiece = r
                    } else if let r = delta["thinking"] as? String, !r.isEmpty {
                        reasoningPiece = r
                    }

                    if let rawToolCalls = delta["tool_calls"] as? [[String: Any]] {
                        for (idx, tc) in rawToolCalls.enumerated() {
                            let tcIndex = (tc["index"] as? Int) ?? idx
                            var entry = toolCallsByIndex[tcIndex] ?? PartialToolCall()
                            if let id = tc["id"] as? String, !id.isEmpty {
                                entry.id = id
                            }
                            if let fn = tc["function"] as? [String: Any] {
                                if let namePiece = fn["name"] as? String, !namePiece.isEmpty {
                                    entry.name += namePiece
                                }
                                if let argPiece = fn["arguments"] as? String, !argPiece.isEmpty {
                                    entry.arguments += argPiece
                                }
                            }
                            toolCallsByIndex[tcIndex] = entry
                        }
                    }
                } else if let messageObj = firstChoice["message"] as? [String: Any] {
                    if let r = (messageObj["reasoning_content"] as? String)
                        ?? (messageObj["reasoning"] as? String)
                        ?? (messageObj["thinking"] as? String),
                       !r.isEmpty {
                        accumulatedReasoning = r
                        lastFlushedReasoningLength = accumulatedReasoning.count
                        await onReasoningUpdate?(accumulatedReasoning)
                    }
                    if let fullText = messageObj["content"] as? String, !fullText.isEmpty {
                        accumulatedContent = fullText
                        lastFlushedLength = accumulatedContent.count
                        await onPartialUpdate?(accumulatedContent)
                    }
                    if let rawCalls = messageObj["tool_calls"] as? [[String: Any]] {
                        for (idx, tc) in rawCalls.enumerated() {
                            var entry = PartialToolCall()
                            entry.id = (tc["id"] as? String) ?? "call_\(idx)"
                            if let fn = tc["function"] as? [String: Any] {
                                entry.name = (fn["name"] as? String) ?? ""
                                entry.arguments = (fn["arguments"] as? String) ?? "{}"
                            }
                            toolCallsByIndex[idx] = entry
                        }
                    }
                }
            } else if !eventType.isEmpty {
                switch eventType {
                case "response.output_text.delta":
                    if let d = json["delta"] as? String, !d.isEmpty {
                        contentPiece = d
                    }
                case "response.reasoning_summary_text.delta", "response.reasoning_text.delta":
                    if let d = json["delta"] as? String, !d.isEmpty {
                        reasoningPiece = d
                    }
                case "response.reasoning_summary_text.done", "response.reasoning_text.done":
                    if !accumulatedReasoning.isEmpty && !accumulatedReasoning.hasSuffix("\n\n") {
                        reasoningPiece = "\n\n"
                    }
                case "response.output_item.added":
                    if let item = json["item"] as? [String: Any],
                       let itemType = item["type"] as? String,
                       (itemType == "function_call" || itemType == "custom_tool_call") {
                        let idx = (json["output_index"] as? Int) ?? toolCallsByIndex.count
                        var entry = toolCallsByIndex[idx] ?? PartialToolCall()
                        if let callId = item["call_id"] as? String, !callId.isEmpty {
                            entry.id = callId
                        } else if let id = item["id"] as? String, !id.isEmpty {
                            entry.id = id
                        }
                        if let name = item["name"] as? String, !name.isEmpty {
                            entry.name = name
                        }
                        toolCallsByIndex[idx] = entry
                    }
                case "response.function_call_arguments.delta", "response.custom_tool_call_input.delta":
                    if let d = json["delta"] as? String, !d.isEmpty {
                        let idx = (json["output_index"] as? Int) ?? max(0, toolCallsByIndex.count - 1)
                        var entry = toolCallsByIndex[idx] ?? PartialToolCall()
                        entry.arguments += d
                        toolCallsByIndex[idx] = entry
                    }
                case "response.output_item.done":
                    if let item = json["item"] as? [String: Any],
                       let itemType = item["type"] as? String,
                       (itemType == "function_call" || itemType == "custom_tool_call") {
                        let idx = (json["output_index"] as? Int) ?? max(0, toolCallsByIndex.count - 1)
                        var entry = toolCallsByIndex[idx] ?? PartialToolCall()
                        if entry.id.isEmpty {
                            entry.id = (item["call_id"] as? String) ?? (item["id"] as? String) ?? "call_\(idx)"
                        }
                        if entry.name.isEmpty, let name = item["name"] as? String {
                            entry.name = name
                        }
                        if entry.arguments.isEmpty {
                            if let args = item["arguments"] as? String, !args.isEmpty {
                                entry.arguments = args
                            } else if let input = item["input"] as? String, !input.isEmpty {
                                entry.arguments = input
                            }
                        }
                        toolCallsByIndex[idx] = entry
                    }
                case "response.completed", "response.done":
                    if let respObj = json["response"] as? [String: Any],
                       let outputs = respObj["output"] as? [[String: Any]] {
                        for item in outputs {
                            let itemType = item["type"] as? String ?? ""
                            if itemType == "message", accumulatedContent.isEmpty,
                               let contentArr = item["content"] as? [[String: Any]] {
                                let texts = contentArr.compactMap { $0["text"] as? String }.joined()
                                if !texts.isEmpty {
                                    accumulatedContent = texts
                                    lastFlushedLength = accumulatedContent.count
                                    await onPartialUpdate?(accumulatedContent)
                                }
                            } else if itemType == "reasoning", accumulatedReasoning.isEmpty {
                                var rParts: [String] = []
                                if let summaries = item["summary"] as? [[String: Any]] {
                                    rParts.append(contentsOf: summaries.compactMap { $0["text"] as? String })
                                }
                                if let contents = item["content"] as? [[String: Any]] {
                                    rParts.append(contentsOf: contents.compactMap { $0["text"] as? String })
                                }
                                let joined = rParts.joined(separator: "\n")
                                if !joined.isEmpty {
                                    accumulatedReasoning = joined
                                    lastFlushedReasoningLength = accumulatedReasoning.count
                                    await onReasoningUpdate?(accumulatedReasoning)
                                }
                            }
                        }
                    }
                default:
                    break
                }
            }

            if let rPiece = reasoningPiece, !rPiece.isEmpty {
                let wasEmpty = (lastFlushedReasoningLength == 0)
                accumulatedReasoning += rPiece
                let now = CFAbsoluteTimeGetCurrent()
                let elapsed = now - lastReasoningYieldTime
                let pendingChars = accumulatedReasoning.count - lastFlushedReasoningLength
                let hasBoundary = Self.containsClauseOrLineBoundary(rPiece)

                if wasEmpty || (hasBoundary && elapsed >= 0.04) || pendingChars >= 14 || elapsed >= 0.07 {
                    lastReasoningYieldTime = now
                    lastFlushedReasoningLength = accumulatedReasoning.count
                    await onReasoningUpdate?(accumulatedReasoning)
                }
            }

            if let piece = contentPiece, !piece.isEmpty {
                let wasEmpty = (lastFlushedLength == 0)
                accumulatedContent += piece
                let now = CFAbsoluteTimeGetCurrent()
                let elapsed = now - lastYieldTime
                let pendingChars = accumulatedContent.count - lastFlushedLength
                let hasSentenceOrLineBreak = Self.containsClauseOrLineBoundary(piece)

                let shouldFlushFirstChunk = wasEmpty
                let shouldFlushBoundary = (hasSentenceOrLineBreak && elapsed >= 0.035)
                let shouldFlushMultiWord = (pendingChars >= 14 && elapsed >= 0.045)
                let shouldFlushTimeWindow = (pendingChars >= 1 && elapsed >= 0.07)

                if shouldFlushFirstChunk || shouldFlushBoundary || shouldFlushMultiWord || shouldFlushTimeWindow {
                    lastYieldTime = now
                    lastFlushedLength = accumulatedContent.count
                    await onPartialUpdate?(accumulatedContent)
                }
            }

            return false
        }

        for try await byte in bytes {
            try Task.checkCancellation()
            if byte == 0x0A {
                if lineBuffer.last == 0x0D {
                    lineBuffer.removeLast()
                }
                let rawLine = String(decoding: lineBuffer, as: UTF8.self)
                lineBuffer.removeAll(keepingCapacity: true)
                let shouldBreak = try await processLine(rawLine)
                if shouldBreak { break }
            } else {
                lineBuffer.append(byte)
            }
        }

        if !lineBuffer.isEmpty {
            if lineBuffer.last == 0x0D {
                lineBuffer.removeLast()
            }
            let rawLine = String(decoding: lineBuffer, as: UTF8.self)
            lineBuffer.removeAll()
            _ = try await processLine(rawLine)
        }

        try Task.checkCancellation()

        if !receivedSSEEvent && !nonSSELines.isEmpty {
            let joined = nonSSELines.joined(separator: "\n")
            if let data = joined.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                let parsed = try parseNonStreamingJSON(json)
                if let r = parsed.reasoning, !r.isEmpty {
                    await onReasoningUpdate?(r)
                }
                if let text = parsed.content, !text.isEmpty {
                    await onPartialUpdate?(text)
                }
                return parsed
            }
        }

        if !accumulatedReasoning.isEmpty && lastFlushedReasoningLength != accumulatedReasoning.count {
            await onReasoningUpdate?(accumulatedReasoning)
        }

        if !accumulatedContent.isEmpty && lastFlushedLength != accumulatedContent.count {
            await onPartialUpdate?(accumulatedContent)
        }

        var finalToolCalls: [ToolCallItem]? = nil
        if !toolCallsByIndex.isEmpty {
            let sortedIndices = toolCallsByIndex.keys.sorted()
            var list: [ToolCallItem] = []
            for idx in sortedIndices {
                guard let item = toolCallsByIndex[idx], !item.name.isEmpty else { continue }
                let callId = item.id.isEmpty ? "call_\(UUID().uuidString.prefix(8))" : item.id
                let args = item.arguments.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "{}" : item.arguments
                list.append(ToolCallItem(id: callId, name: item.name, arguments: args, result: nil, isExecuting: false, error: nil))
            }
            if !list.isEmpty {
                finalToolCalls = list
            }
        }

        let trimmedReasoning = accumulatedReasoning.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalReasoning: String? = trimmedReasoning.isEmpty ? nil : trimmedReasoning
        let finalContent: String? = accumulatedContent.isEmpty ? nil : accumulatedContent
        return (finalContent, finalReasoning, finalToolCalls)
    }

    private static func containsClauseOrLineBoundary(_ piece: String) -> Bool {
        for ch in piece {
            switch ch {
            case "\n", "。", "！", "？", "；", "：", "，", "、", ".", "!", "?", ";", ":", ",", ")", "）", "】", "]":
                return true
            default:
                continue
            }
        }
        return false
    }

    private func buildOpenAIMessages(settings: OpenAISettings, messages: [ChatMessage]) -> [[String: Any]] {
        var openAIMessages: [[String: Any]] = []
        if !settings.systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            openAIMessages.append([
                "role": "system",
                "content": settings.systemPrompt
            ])
        }

        for msg in messages {
            var combinedText = msg.content
            let attachments = msg.attachments ?? []

            for att in attachments {
                switch att.kind {
                case .longText:
                    if let text = att.textContent, !text.isEmpty {
                        if combinedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            combinedText = text
                        } else {
                            combinedText += "\n\n" + text
                        }
                    }
                case .file:
                    if let text = att.textContent, !text.isEmpty {
                        let block = "--- 文件: \(att.fileName) ---\n\(text)\n--- 文件结束 ---"
                        if combinedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            combinedText = block
                        } else {
                            combinedText += "\n\n" + block
                        }
                    }
                case .image:
                    break
                }
            }

            let imageAttachments = attachments.filter { $0.kind == .image && ($0.imageDataBase64?.isEmpty == false) }

            var m: [String: Any] = [
                "role": msg.role.rawValue
            ]

            if !imageAttachments.isEmpty && msg.role == .user {
                var contentParts: [[String: Any]] = []
                let textBody = combinedText.trimmingCharacters(in: .whitespacesAndNewlines)
                contentParts.append([
                    "type": "text",
                    "text": textBody.isEmpty ? "请分析上传的图片内容" : textBody
                ])
                for img in imageAttachments {
                    if let b64 = img.imageDataBase64 {
                        contentParts.append([
                            "type": "image_url",
                            "image_url": [
                                "url": "data:\(img.mimeType);base64,\(b64)"
                            ]
                        ])
                    }
                }
                m["content"] = contentParts
            } else {
                m["content"] = combinedText
            }

            if let toolCalls = msg.toolCalls, !toolCalls.isEmpty {
                m["tool_calls"] = toolCalls.map { tc in
                    [
                        "id": tc.id,
                        "type": "function",
                        "function": [
                            "name": tc.name,
                            "arguments": tc.arguments
                        ]
                    ]
                }
            }
            if let toolCallId = msg.toolCallId {
                m["tool_call_id"] = toolCallId
            }
            openAIMessages.append(m)
        }
        return openAIMessages
    }

    private func parseNonStreamingJSON(_ json: [String: Any]) throws -> (content: String?, reasoning: String?, toolCalls: [ToolCallItem]?) {
        if let errObj = json["error"] as? [String: Any],
           let msg = errObj["message"] as? String {
            throw NSError(domain: "OpenAIService", code: -1, userInfo: [NSLocalizedDescriptionKey: msg])
        }

        if let choices = json["choices"] as? [[String: Any]],
           let firstChoice = choices.first,
           let choiceMsg = firstChoice["message"] as? [String: Any] {
            let content = choiceMsg["content"] as? String
            let reasoning = (choiceMsg["reasoning_content"] as? String)
                ?? (choiceMsg["reasoning"] as? String)
                ?? (choiceMsg["thinking"] as? String)
            var parsedToolCalls: [ToolCallItem]? = nil

            if let rawCalls = choiceMsg["tool_calls"] as? [[String: Any]] {
                var items: [ToolCallItem] = []
                for c in rawCalls {
                    guard let id = c["id"] as? String,
                          let fn = c["function"] as? [String: Any],
                          let name = fn["name"] as? String else { continue }
                    let args = (fn["arguments"] as? String) ?? "{}"
                    items.append(ToolCallItem(id: id, name: name, arguments: args, result: nil, isExecuting: false, error: nil))
                }
                if !items.isEmpty {
                    parsedToolCalls = items
                }
            }

            let trimmedReasoning = reasoning?.trimmingCharacters(in: .whitespacesAndNewlines)
            return (content, (trimmedReasoning?.isEmpty == false) ? trimmedReasoning : nil, parsedToolCalls)
        }

        if let outputs = json["output"] as? [[String: Any]] {
            var contentParts: [String] = []
            var reasoningParts: [String] = []
            var items: [ToolCallItem] = []

            for item in outputs {
                let itemType = item["type"] as? String ?? ""
                if itemType == "message", let contentArr = item["content"] as? [[String: Any]] {
                    contentParts.append(contentsOf: contentArr.compactMap { $0["text"] as? String })
                } else if itemType == "reasoning" {
                    if let summaries = item["summary"] as? [[String: Any]] {
                        reasoningParts.append(contentsOf: summaries.compactMap { $0["text"] as? String })
                    }
                    if let contents = item["content"] as? [[String: Any]] {
                        reasoningParts.append(contentsOf: contents.compactMap { $0["text"] as? String })
                    }
                } else if itemType == "function_call" || itemType == "custom_tool_call" {
                    let id = (item["call_id"] as? String) ?? (item["id"] as? String) ?? "call_\(items.count)"
                    let name = (item["name"] as? String) ?? ""
                    let args = (item["arguments"] as? String) ?? (item["input"] as? String) ?? "{}"
                    if !name.isEmpty {
                        items.append(ToolCallItem(id: id, name: name, arguments: args, result: nil, isExecuting: false, error: nil))
                    }
                }
            }

            let finalContent = contentParts.joined()
            let finalReasoning = reasoningParts.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            return (
                finalContent.isEmpty ? nil : finalContent,
                finalReasoning.isEmpty ? nil : finalReasoning,
                items.isEmpty ? nil : items
            )
        }

        throw NSError(domain: "OpenAIService", code: -1, userInfo: [NSLocalizedDescriptionKey: "无法解析返回内容"])
    }
}
