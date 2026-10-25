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
        onPartialUpdate: (@MainActor (String) -> Void)? = nil
    ) async throws -> (content: String?, toolCalls: [ToolCallItem]?) {
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
        if !settings.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let key = settings.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
            req.setValue(key.hasPrefix("Bearer ") ? key : "Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        req.httpBody = try JSONSerialization.data(withJSONObject: payload)
        req.timeoutInterval = 120

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
                if errorData.count > 4096 { break }
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
        if !contentType.contains("event-stream") {
            var rawData = Data()
            for try await byte in bytes {
                try Task.checkCancellation()
                rawData.append(byte)
            }
            if let json = try? JSONSerialization.jsonObject(with: rawData) as? [String: Any],
               json["choices"] != nil {
                let parsed = try parseNonStreamingJSON(json)
                if let text = parsed.content, !text.isEmpty {
                    await onPartialUpdate?(text)
                }
                return parsed
            }
        }

        var accumulatedContent = ""
        struct PartialToolCall {
            var id: String = ""
            var name: String = ""
            var arguments: String = ""
        }
        var toolCallsByIndex: [Int: PartialToolCall] = [:]
        var nonSSELines: [String] = []
        var receivedSSEEvent = false
        var lastYieldTime = CFAbsoluteTimeGetCurrent()

        for try await rawLine in bytes.lines {
            try Task.checkCancellation()
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty { continue }

            if line.hasPrefix("data:") {
                receivedSSEEvent = true
                let dataStr = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
                if dataStr == "[DONE]" {
                    break
                }
                guard let data = dataStr.data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    continue
                }

                if let errObj = json["error"] as? [String: Any],
                   let msg = errObj["message"] as? String {
                    throw NSError(domain: "OpenAIService", code: -1, userInfo: [NSLocalizedDescriptionKey: msg])
                }

                guard let choices = json["choices"] as? [[String: Any]],
                      let firstChoice = choices.first else {
                    continue
                }

                if let delta = firstChoice["delta"] as? [String: Any] {
                    if let piece = delta["content"] as? String, !piece.isEmpty {
                        accumulatedContent += piece
                        let now = CFAbsoluteTimeGetCurrent()
                        if now - lastYieldTime >= 0.032 {
                            lastYieldTime = now
                            await onPartialUpdate?(accumulatedContent)
                        }
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
                    if let fullText = messageObj["content"] as? String, !fullText.isEmpty {
                        accumulatedContent = fullText
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
            } else if !receivedSSEEvent {
                nonSSELines.append(rawLine)
            }
        }

        try Task.checkCancellation()

        if !receivedSSEEvent && !nonSSELines.isEmpty {
            let joined = nonSSELines.joined(separator: "\n")
            if let data = joined.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                let parsed = try parseNonStreamingJSON(json)
                if let text = parsed.content, !text.isEmpty {
                    await onPartialUpdate?(text)
                }
                return parsed
            }
        }

        if !accumulatedContent.isEmpty {
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

        let finalContent: String? = accumulatedContent.isEmpty ? nil : accumulatedContent
        return (finalContent, finalToolCalls)
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

    private func parseNonStreamingJSON(_ json: [String: Any]) throws -> (content: String?, toolCalls: [ToolCallItem]?) {
        if let errObj = json["error"] as? [String: Any],
           let msg = errObj["message"] as? String {
            throw NSError(domain: "OpenAIService", code: -1, userInfo: [NSLocalizedDescriptionKey: msg])
        }

        guard let choices = json["choices"] as? [[String: Any]],
              let firstChoice = choices.first,
              let choiceMsg = firstChoice["message"] as? [String: Any] else {
            throw NSError(domain: "OpenAIService", code: -1, userInfo: [NSLocalizedDescriptionKey: "无法解析返回内容"])
        }

        let content = choiceMsg["content"] as? String
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

        return (content, parsedToolCalls)
    }
}
