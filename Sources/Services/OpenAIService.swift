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
            req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }

        let (data, response) = try await URLSession.shared.data(for: req)
        guard let httpResp = response as? HTTPURLResponse, (200...299).contains(httpResp.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            let errText = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw NSError(domain: "OpenAIService", code: status, userInfo: [
                NSLocalizedDescriptionKey: "获取模型失败 (HTTP \(status)): \(errText)"
            ])
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dataArray = json["data"] as? [[String: Any]] else {
            throw NSError(domain: "OpenAIService", code: -2, userInfo: [
                NSLocalizedDescriptionKey: "返回数据格式不符合 OpenAI /models 规范"
            ])
        }

        let models = dataArray.compactMap { $0["id"] as? String }.sorted()
        return models
    }

    private func buildRequestMessages(messages: [ChatMessage], systemPrompt: String) -> [[String: Any]] {
        var reqMessages: [[String: Any]] = []

        if !systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            reqMessages.append([
                "role": "system",
                "content": systemPrompt
            ])
        }

        for msg in messages {
            var dict: [String: Any] = ["role": msg.role.rawValue]

            let attachments = msg.attachments ?? []
            let imageAttachments = attachments.filter { $0.kind == .image && ($0.imageDataBase64?.isEmpty == false) }
            let textAttachments = attachments.filter { $0.kind != .image && ($0.textContent?.isEmpty == false) }

            var combinedText = msg.content
            if !textAttachments.isEmpty {
                let attachmentBlocks = textAttachments.map { att -> String in
                    let body = att.textContent ?? ""
                    return "【附件文件: \(att.fileName)】\n\(body)"
                }.joined(separator: "\n\n")

                if combinedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    combinedText = attachmentBlocks
                } else {
                    combinedText = combinedText + "\n\n" + attachmentBlocks
                }
            }

            if let toolCalls = msg.toolCalls, !toolCalls.isEmpty {
                dict["content"] = combinedText.isEmpty ? NSNull() : combinedText
                dict["tool_calls"] = toolCalls.map { tc in
                    [
                        "id": tc.id,
                        "type": "function",
                        "function": [
                            "name": tc.name,
                            "arguments": tc.arguments
                        ]
                    ]
                }
            } else if msg.role == .user && !imageAttachments.isEmpty {
                var contentParts: [[String: Any]] = []
                let promptText = combinedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? "请结合上传的图片进行分析回答。"
                    : combinedText
                contentParts.append([
                    "type": "text",
                    "text": promptText
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
                dict["content"] = contentParts
            } else {
                dict["content"] = combinedText
            }

            if let toolCallId = msg.toolCallId {
                dict["tool_call_id"] = toolCallId
            }

            reqMessages.append(dict)
        }

        return reqMessages
    }

    private func buildOpenAITools(tools: [(serverName: String, tool: MCPTool)]) -> [[String: Any]] {
        var openAITools: [[String: Any]] = []
        for item in tools {
            var fnDict: [String: Any] = [
                "name": item.tool.name,
                "description": "[\(item.serverName)] \(item.tool.description)"
            ]
            if let schemaData = item.tool.inputSchemaJSON.data(using: .utf8),
               let schemaObj = try? JSONSerialization.jsonObject(with: schemaData) {
                fnDict["parameters"] = schemaObj
            } else {
                fnDict["parameters"] = ["type": "object", "properties": [String: Any]()]
            }
            openAITools.append([
                "type": "function",
                "function": fnDict
            ])
        }
        return openAITools
    }

    private func buildEndpointURL(baseURL: String) throws -> URL {
        var base = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if base.hasSuffix("/") {
            base = String(base.dropLast())
        }
        let fullEndpoint = base.hasSuffix("/chat/completions") ? base : "\(base)/chat/completions"
        guard let url = URL(string: fullEndpoint) else {
            throw URLError(.badURL)
        }
        return url
    }

    func createChatCompletionStream(
        messages: [ChatMessage],
        settings: OpenAISettings,
        tools: [(serverName: String, tool: MCPTool)],
        onDelta: @escaping @Sendable (String) async -> Void,
        onReasoningDelta: (@Sendable (String) async -> Void)? = nil
    ) async throws -> ChatMessage {
        let url = try buildEndpointURL(baseURL: settings.baseURL)
        let reqMessages = buildRequestMessages(messages: messages, systemPrompt: settings.systemPrompt)
        let openAITools = buildOpenAITools(tools: tools)

        var body: [String: Any] = [
            "model": settings.modelName,
            "messages": reqMessages,
            "temperature": settings.temperature,
            "stream": true
        ]

        if !openAITools.isEmpty {
            body["tools"] = openAITools
            body["tool_choice"] = "auto"
        }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 300
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        req.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        if !settings.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let key = settings.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
            req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (bytes, response) = try await URLSession.shared.bytes(for: req)
        guard let httpResp = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }

        if !(200...299).contains(httpResp.statusCode) {
            var errorData = Data()
            for try await byte in bytes {
                errorData.append(byte)
                if errorData.count > 16384 { break }
            }
            let errText = String(data: errorData, encoding: .utf8) ?? "Unknown error"
            throw NSError(domain: "OpenAIService", code: httpResp.statusCode, userInfo: [
                NSLocalizedDescriptionKey: "HTTP \(httpResp.statusCode): \(errText)"
            ])
        }

        let contentType = (httpResp.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
        if !contentType.contains("text/event-stream") && contentType.contains("application/json") {
            var fullData = Data()
            for try await byte in bytes {
                try Task.checkCancellation()
                fullData.append(byte)
            }
            let msg = try parseNonStreamingResponse(data: fullData)
            if let reasoning = msg.reasoningContent, !reasoning.isEmpty {
                await onReasoningDelta?(reasoning)
            }
            if !msg.content.isEmpty {
                await onDelta(msg.content)
            }
            return msg
        }

        struct PartialToolCall {
            var id: String = ""
            var name: String = ""
            var arguments: String = ""
        }

        var accumulatedContent = ""
        var accumulatedReasoning = ""
        var partialToolCalls: [Int: PartialToolCall] = [:]
        var nonSSELines: [String] = []
        var sawSSEData = false
        var lastEmitTime = CFAbsoluteTimeGetCurrent()
        var lastReasoningEmitTime = CFAbsoluteTimeGetCurrent()
        var pendingSentenceChars = 0

        func isNaturalBreakSymbol(_ text: String) -> Bool {
            guard let last = text.last else { return false }
            switch last {
            case "\n", "。", "！", "？", "；", "：", "，", "、", ".", "!", "?", ";", ":", ",", ")", "）", "】", "]":
                return true
            default:
                return false
            }
        }

        var lineBuffer = Data()

        func processRawLine(_ rawLine: String) async throws -> Bool {
            let trimmed = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { return false }
            if trimmed.hasPrefix(":") || trimmed.hasPrefix("event:") || trimmed.hasPrefix("id:") || trimmed.hasPrefix("retry:") {
                return false
            }

            let payload: String
            if trimmed.hasPrefix("data:") {
                sawSSEData = true
                payload = String(trimmed.dropFirst(5)).trimmingCharacters(in: .whitespaces)
            } else {
                if !sawSSEData {
                    nonSSELines.append(trimmed)
                }
                return false
            }

            if payload == "[DONE]" {
                return true
            }

            guard let data = payload.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return false
            }

            let eventType = json["type"] as? String ?? ""

            var contentDeltaPiece: String? = nil
            var reasoningDeltaPiece: String? = nil

            if let choices = json["choices"] as? [[String: Any]], let firstChoice = choices.first {
                if let delta = firstChoice["delta"] as? [String: Any] {
                    if let c = delta["content"] as? String, !c.isEmpty {
                        contentDeltaPiece = c
                    }
                    if let r = delta["reasoning_content"] as? String, !r.isEmpty {
                        reasoningDeltaPiece = r
                    } else if let r = delta["reasoning"] as? String, !r.isEmpty {
                        reasoningDeltaPiece = r
                    } else if let r = delta["thinking"] as? String, !r.isEmpty {
                        reasoningDeltaPiece = r
                    }

                    if let tcs = delta["tool_calls"] as? [[String: Any]] {
                        for (fallbackIdx, tc) in tcs.enumerated() {
                            let idx = (tc["index"] as? Int) ?? fallbackIdx
                            var current = partialToolCalls[idx] ?? PartialToolCall()
                            if let id = tc["id"] as? String, !id.isEmpty {
                                current.id = id
                            }
                            if let fn = tc["function"] as? [String: Any] {
                                if let name = fn["name"] as? String, !name.isEmpty {
                                    current.name += name
                                }
                                if let args = fn["arguments"] as? String, !args.isEmpty {
                                    current.arguments += args
                                }
                            }
                            partialToolCalls[idx] = current
                        }
                    }
                } else if let message = firstChoice["message"] as? [String: Any] {
                    if let c = message["content"] as? String, !c.isEmpty {
                        accumulatedContent = c
                        await onDelta(accumulatedContent)
                    }
                    if let r = message["reasoning_content"] as? String, !r.isEmpty {
                        accumulatedReasoning = r
                        await onReasoningDelta?(accumulatedReasoning)
                    } else if let r = message["reasoning"] as? String, !r.isEmpty {
                        accumulatedReasoning = r
                        await onReasoningDelta?(accumulatedReasoning)
                    }
                    if let tcs = message["tool_calls"] as? [[String: Any]] {
                        for (idx, tc) in tcs.enumerated() {
                            var current = PartialToolCall()
                            current.id = (tc["id"] as? String) ?? UUID().uuidString
                            if let fn = tc["function"] as? [String: Any] {
                                current.name = (fn["name"] as? String) ?? ""
                                current.arguments = (fn["arguments"] as? String) ?? "{}"
                            }
                            partialToolCalls[idx] = current
                        }
                    }
                }
            } else if !eventType.isEmpty {
                switch eventType {
                case "response.output_text.delta":
                    if let d = json["delta"] as? String, !d.isEmpty {
                        contentDeltaPiece = d
                    }
                case "response.reasoning_summary_text.delta", "response.reasoning_text.delta":
                    if let d = json["delta"] as? String, !d.isEmpty {
                        reasoningDeltaPiece = d
                    }
                case "response.reasoning_summary_text.done", "response.reasoning_text.done":
                    if !accumulatedReasoning.hasSuffix("\n\n") && !accumulatedReasoning.isEmpty {
                        reasoningDeltaPiece = "\n\n"
                    }
                case "response.output_item.added":
                    if let item = json["item"] as? [String: Any],
                       let itemType = item["type"] as? String,
                       (itemType == "function_call" || itemType == "custom_tool_call") {
                        let idx = (json["output_index"] as? Int) ?? partialToolCalls.count
                        var current = partialToolCalls[idx] ?? PartialToolCall()
                        if let callId = item["call_id"] as? String, !callId.isEmpty {
                            current.id = callId
                        } else if let id = item["id"] as? String, !id.isEmpty {
                            current.id = id
                        }
                        if let name = item["name"] as? String, !name.isEmpty {
                            current.name = name
                        }
                        partialToolCalls[idx] = current
                    }
                case "response.function_call_arguments.delta", "response.custom_tool_call_input.delta":
                    if let d = json["delta"] as? String, !d.isEmpty {
                        let idx = (json["output_index"] as? Int) ?? max(0, partialToolCalls.count - 1)
                        var current = partialToolCalls[idx] ?? PartialToolCall()
                        current.arguments += d
                        partialToolCalls[idx] = current
                    }
                case "response.output_item.done":
                    if let item = json["item"] as? [String: Any],
                       let itemType = item["type"] as? String,
                       (itemType == "function_call" || itemType == "custom_tool_call") {
                        let idx = (json["output_index"] as? Int) ?? max(0, partialToolCalls.count - 1)
                        var current = partialToolCalls[idx] ?? PartialToolCall()
                        if current.id.isEmpty {
                            current.id = (item["call_id"] as? String) ?? (item["id"] as? String) ?? UUID().uuidString
                        }
                        if current.name.isEmpty, let name = item["name"] as? String {
                            current.name = name
                        }
                        if current.arguments.isEmpty {
                            if let args = item["arguments"] as? String, !args.isEmpty {
                                current.arguments = args
                            } else if let input = item["input"] as? String, !input.isEmpty {
                                current.arguments = input
                            }
                        }
                        partialToolCalls[idx] = current
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
                                    await onDelta(accumulatedContent)
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
                                    await onReasoningDelta?(accumulatedReasoning)
                                }
                            }
                        }
                    }
                default:
                    break
                }
            }

            if let rPiece = reasoningDeltaPiece, !rPiece.isEmpty {
                accumulatedReasoning += rPiece
                let now = CFAbsoluteTimeGetCurrent()
                if now - lastReasoningEmitTime >= 0.05 || isNaturalBreakSymbol(rPiece) {
                    lastReasoningEmitTime = now
                    await onReasoningDelta?(accumulatedReasoning)
                }
            }

            if let cPiece = contentDeltaPiece, !cPiece.isEmpty {
                let wasEmpty = accumulatedContent.isEmpty
                accumulatedContent += cPiece
                pendingSentenceChars += cPiece.count
                let now = CFAbsoluteTimeGetCurrent()
                let elapsed = now - lastEmitTime
                let hitSentenceBreak = isNaturalBreakSymbol(cPiece)

                if wasEmpty || (hitSentenceBreak && elapsed >= 0.03) || pendingSentenceChars >= 14 || elapsed >= 0.06 {
                    lastEmitTime = now
                    pendingSentenceChars = 0
                    await onDelta(accumulatedContent)
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
                let shouldStop = try await processRawLine(rawLine)
                if shouldStop { break }
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
            _ = try await processRawLine(rawLine)
        }

        if !sawSSEData && !nonSSELines.isEmpty {
            let joined = nonSSELines.joined(separator: "\n")
            if let fallbackData = joined.data(using: .utf8),
               let fallbackMsg = try? parseNonStreamingResponse(data: fallbackData) {
                if let reasoning = fallbackMsg.reasoningContent, !reasoning.isEmpty {
                    await onReasoningDelta?(reasoning)
                }
                if !fallbackMsg.content.isEmpty {
                    await onDelta(fallbackMsg.content)
                }
                return fallbackMsg
            }
        }

        if !accumulatedReasoning.isEmpty {
            await onReasoningDelta?(accumulatedReasoning)
        }

        if !accumulatedContent.isEmpty {
            await onDelta(accumulatedContent)
        }

        let sortedKeys = partialToolCalls.keys.sorted()
        let finalToolCalls: [ToolCallItem] = sortedKeys.compactMap { key in
            guard let item = partialToolCalls[key],
                  !item.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return nil
            }
            return ToolCallItem(
                id: item.id.isEmpty ? UUID().uuidString : item.id,
                name: item.name,
                arguments: item.arguments.isEmpty ? "{}" : item.arguments,
                isExecuting: true
            )
        }

        let finalReasoning = accumulatedReasoning.trimmingCharacters(in: .whitespacesAndNewlines)

        return ChatMessage(
            role: .assistant,
            content: accumulatedContent,
            reasoningContent: finalReasoning.isEmpty ? nil : finalReasoning,
            toolCalls: finalToolCalls.isEmpty ? nil : finalToolCalls
        )
    }

    private func parseNonStreamingResponse(data: Data) throws -> ChatMessage {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NSError(domain: "OpenAIService", code: -2, userInfo: [
                NSLocalizedDescriptionKey: "无法解析响应 JSON"
            ])
        }

        if let choices = json["choices"] as? [[String: Any]],
           let firstChoice = choices.first,
           let message = firstChoice["message"] as? [String: Any] {
            let content = (message["content"] as? String) ?? ""
            let reasoning = (message["reasoning_content"] as? String)
                ?? (message["reasoning"] as? String)
                ?? (message["thinking"] as? String)
            var parsedToolCalls: [ToolCallItem] = []

            if let toolCalls = message["tool_calls"] as? [[String: Any]] {
                for tc in toolCalls {
                    if let id = tc["id"] as? String,
                       let fn = tc["function"] as? [String: Any],
                       let name = fn["name"] as? String {
                        let args = (fn["arguments"] as? String) ?? "{}"
                        parsedToolCalls.append(ToolCallItem(id: id, name: name, arguments: args, isExecuting: true))
                    }
                }
            }

            let trimmedReasoning = reasoning?.trimmingCharacters(in: .whitespacesAndNewlines)
            return ChatMessage(
                role: .assistant,
                content: content,
                reasoningContent: (trimmedReasoning?.isEmpty == false) ? trimmedReasoning : nil,
                toolCalls: parsedToolCalls.isEmpty ? nil : parsedToolCalls
            )
        }

        if let outputs = json["output"] as? [[String: Any]] {
            var contentParts: [String] = []
            var reasoningParts: [String] = []
            var parsedToolCalls: [ToolCallItem] = []

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
                    let id = (item["call_id"] as? String) ?? (item["id"] as? String) ?? UUID().uuidString
                    let name = (item["name"] as? String) ?? ""
                    let args = (item["arguments"] as? String) ?? (item["input"] as? String) ?? "{}"
                    if !name.isEmpty {
                        parsedToolCalls.append(ToolCallItem(id: id, name: name, arguments: args, isExecuting: true))
                    }
                }
            }

            let finalReasoning = reasoningParts.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            return ChatMessage(
                role: .assistant,
                content: contentParts.joined(),
                reasoningContent: finalReasoning.isEmpty ? nil : finalReasoning,
                toolCalls: parsedToolCalls.isEmpty ? nil : parsedToolCalls
            )
        }

        throw NSError(domain: "OpenAIService", code: -2, userInfo: [
            NSLocalizedDescriptionKey: "未找到有效的模型输出内容"
        ])
    }
}
