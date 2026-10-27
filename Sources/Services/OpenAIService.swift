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
        conversationId: String? = nil,
        conversationTitle: String? = nil,
        turnId: String? = nil,
        turnPrompt: String? = nil,
        stepIndex: Int? = nil,
        onPartialUpdate: (@MainActor (String) -> Void)? = nil,
        onReasoningUpdate: (@MainActor (String) -> Void)? = nil,
        onPromptTokenCount: (@MainActor (Int, Bool) -> Void)? = nil
    ) async throws -> (content: String?, reasoning: String?, toolCalls: [ToolCallItem]?) {
        let startTime = CFAbsoluteTimeGetCurrent()
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
        payload["stream_options"] = ["include_usage": true]
        await onPromptTokenCount?(estimatePromptTokens(settings: settings, messages: messages, tools: tools), true)

        let payloadData = try JSONSerialization.data(withJSONObject: payload)
        let profileName = settings.activeProfile?.name ?? "默认配置"
        let toolCount = tools?.count ?? 0
        let stepPrefix = stepIndex.map { "第 \($0) 步 · " } ?? ""
        let requestHeaderDetails = "Endpoint: \(fullEndpoint)\nProfile: \(profileName)\nModel: \(settings.modelName)\nTemperature: \(settings.temperature)\nMessages Count: \(openAIMessages.count)\nTools Enabled: \(toolCount)\nPayload Bytes: \(payloadData.count)"

        let requestLogId = await MainActor.run {
            AppLogManager.shared.log(
                category: .aiRequest,
                level: .info,
                title: "\(stepPrefix)发起 AI 请求 [\(settings.modelName)]",
                summary: "配置: \(profileName) · 消息数: \(openAIMessages.count) · 工具数: \(toolCount) · 请求体: \(payloadData.count) B",
                details: requestHeaderDetails,
                conversationId: conversationId,
                conversationTitle: conversationTitle,
                turnId: turnId,
                turnPrompt: turnPrompt,
                stepIndex: stepIndex
            )
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
        req.httpBody = payloadData
        req.timeoutInterval = 300

        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (bytes, response) = try await URLSession.shared.bytes(for: req)
        } catch {
            let nsErr = error as NSError
            await MainActor.run {
                AppLogManager.shared.updateLog(
                    id: requestLogId,
                    category: .error,
                    level: .error,
                    title: "\(stepPrefix)AI 请求连接失败 [\(settings.modelName)]",
                    summary: "\(nsErr.localizedDescription) (Code: \(nsErr.code))",
                    details: "\(requestHeaderDetails)\n\nError Domain: \(nsErr.domain)\nCode: \(nsErr.code)\nDescription: \(nsErr.localizedDescription)"
                )
            }
            throw error
        }

        try Task.checkCancellation()

        guard let httpRes = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }

        let contentType = (httpRes.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()

        guard (200...299).contains(httpRes.statusCode) else {
            var errorData = Data()
            for try await byte in bytes {
                try Task.checkCancellation()
                errorData.append(byte)
                if errorData.count > 8192 { break }
            }
            let errString = String(data: errorData, encoding: .utf8) ?? ""
            await MainActor.run {
                AppLogManager.shared.updateLog(
                    id: requestLogId,
                    category: .error,
                    level: .error,
                    title: "\(stepPrefix)上游返回 HTTP \(httpRes.statusCode) [\(settings.modelName)]",
                    summary: "状态码: \(httpRes.statusCode) · 响应前 200 字符: \(errString.prefix(200))",
                    details: "\(requestHeaderDetails)\n\nHTTP Status: \(httpRes.statusCode)\nContent-Type: \(contentType)\nBody:\n\(errString)"
                )
            }
            if let json = try? JSONSerialization.jsonObject(with: errorData) as? [String: Any],
               let errObj = json["error"] as? [String: Any],
               let msg = errObj["message"] as? String {
                throw NSError(domain: "OpenAIService", code: httpRes.statusCode, userInfo: [NSLocalizedDescriptionKey: msg])
            }
            throw NSError(domain: "OpenAIService", code: httpRes.statusCode, userInfo: [NSLocalizedDescriptionKey: "API 响应错误 (\(httpRes.statusCode)): \(errString.prefix(200))"])
        }

        if !contentType.contains("event-stream") && contentType.contains("application/json") {
            var rawData = Data()
            for try await byte in bytes {
                try Task.checkCancellation()
                rawData.append(byte)
            }
            if let json = try? JSONSerialization.jsonObject(with: rawData) as? [String: Any] {
                if let usage = json["usage"] as? [String: Any],
                   let count = contextTokenTotal(from: usage) {
                    await onPromptTokenCount?(count, false)
                }
                let parsed = try parseNonStreamingJSON(json)
                let finishReason = ((json["choices"] as? [[String: Any]])?.first?["finish_reason"] as? String) ?? "non_stream_json"
                if let r = parsed.reasoning, !r.isEmpty {
                    await onReasoningUpdate?(r)
                }
                if let text = parsed.content, !text.isEmpty {
                    await onPartialUpdate?(text)
                }
                let elapsed = String(format: "%.2fs", CFAbsoluteTimeGetCurrent() - startTime)
                let isTruncatedNonStream = (finishReason == "length" || finishReason == "max_tokens" || finishReason.contains("incomplete") || ((parsed.content ?? "").isEmpty && (parsed.toolCalls ?? []).isEmpty))
                await MainActor.run {
                    AppLogManager.shared.updateLog(
                        id: requestLogId,
                        category: isTruncatedNonStream ? .aiTruncated : .aiStop,
                        level: isTruncatedNonStream ? .warning : .info,
                        title: isTruncatedNonStream ? "\(stepPrefix)非流式响应截断 [\(settings.modelName)]" : "\(stepPrefix)非流式响应完成 [\(settings.modelName)]",
                        summary: "耗时: \(elapsed) · finish_reason: \(finishReason) · 正文: \(parsed.content?.count ?? 0) 字 · 工具调用: \(parsed.toolCalls?.count ?? 0)",
                        details: "\(requestHeaderDetails)\n\nHTTP Status: \(httpRes.statusCode)\nContent-Type: \(contentType)\nFinish Reason: \(finishReason)\nRaw Bytes: \(rawData.count)"
                    )
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
        var receivedDoneMarker = false
        var sseChunkCount = 0
        var lastFinishReason: String? = nil
        var usageSummary: String = ""
        var lastRawDataLine: String = ""
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
                receivedDoneMarker = true
                return true
            }
            lastRawDataLine = String(dataStr.prefix(500))
            sseChunkCount += 1

            guard let data = dataStr.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return false
            }

            if let errObj = json["error"] as? [String: Any],
               let msg = errObj["message"] as? String {
                await MainActor.run {
                    AppLogManager.shared.updateLog(
                        id: requestLogId,
                        category: .error,
                        level: .error,
                        title: "\(stepPrefix)SSE 流内返回错误 [\(settings.modelName)]",
                        summary: msg,
                        details: "\(requestHeaderDetails)\n\nSSE Frame #\(sseChunkCount)\nRaw Data: \(dataStr)"
                    )
                }
                throw NSError(domain: "OpenAIService", code: -1, userInfo: [NSLocalizedDescriptionKey: msg])
            }

            let usageObject = (json["usage"] as? [String: Any]) ?? ((json["response"] as? [String: Any])?["usage"] as? [String: Any])
            if let usage = usageObject {
                if let count = contextTokenTotal(from: usage) {
                    await onPromptTokenCount?(count, false)
                }
                let p = usage["prompt_tokens"] ?? usage["input_tokens"] ?? 0
                let c = usage["completion_tokens"] ?? usage["output_tokens"] ?? 0
                let t = usage["total_tokens"] ?? 0
                usageSummary = "prompt: \(p), completion: \(c), total: \(t)"
            }

            let eventType = json["type"] as? String ?? ""
            var contentPiece: String? = nil
            var reasoningPiece: String? = nil

            if let choices = json["choices"] as? [[String: Any]],
               let firstChoice = choices.first {
                if let fr = firstChoice["finish_reason"] as? String, !fr.isEmpty {
                    lastFinishReason = fr
                }
                if let stopReason = firstChoice["stop_reason"] as? String, !stopReason.isEmpty, lastFinishReason == nil {
                    lastFinishReason = stopReason
                }
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
                case "response.completed", "response.done", "response.incomplete":
                    if eventType == "response.incomplete" {
                        lastFinishReason = "incomplete"
                    } else if lastFinishReason == nil {
                        lastFinishReason = "completed"
                    }
                    if let respObj = json["response"] as? [String: Any] {
                        if let status = respObj["status"] as? String {
                            lastFinishReason = status
                        }
                        if let incompleteDetails = respObj["incomplete_details"] as? [String: Any],
                           let reason = incompleteDetails["reason"] as? String {
                            lastFinishReason = "incomplete(\(reason))"
                        }
                        if let outputs = respObj["output"] as? [[String: Any]] {
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
                if wasEmpty || elapsed >= 0.03 {
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
                if wasEmpty || elapsed >= 0.016 {
                    lastYieldTime = now
                    lastFlushedLength = accumulatedContent.count
                    await onPartialUpdate?(accumulatedContent)
                }
            }

            return false
        }

        do {
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
        } catch {
            if !(error is CancellationError) && (error as NSError).code != NSURLErrorCancelled {
                let elapsed = String(format: "%.2fs", CFAbsoluteTimeGetCurrent() - startTime)
                await MainActor.run {
                    AppLogManager.shared.updateLog(
                        id: requestLogId,
                        category: .aiTruncated,
                        level: .error,
                        title: "\(stepPrefix)流式读取中途异常断开 [\(settings.modelName)]",
                        summary: "耗时: \(elapsed) · 已收帧: \(sseChunkCount) · 已生成: \(accumulatedContent.count) 字 · 错误: \(error.localizedDescription)",
                        details: "\(requestHeaderDetails)\n\nError: \(error.localizedDescription)\nReceived [DONE]: \(receivedDoneMarker)\nLast Finish Reason: \(lastFinishReason ?? "nil")\nContent Chars: \(accumulatedContent.count)\nReasoning Chars: \(accumulatedReasoning.count)\nLast Raw SSE Line:\n\(lastRawDataLine)"
                    )
                }
            }
            throw error
        }

        try Task.checkCancellation()

        if !receivedSSEEvent && !nonSSELines.isEmpty {
            let joined = nonSSELines.joined(separator: "\n")
            if let data = joined.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                if let usage = json["usage"] as? [String: Any],
                   let count = contextTokenTotal(from: usage) {
                    await onPromptTokenCount?(count, false)
                }
                let parsed = try parseNonStreamingJSON(json)
                if let r = parsed.reasoning, !r.isEmpty {
                    await onReasoningUpdate?(r)
                }
                if let text = parsed.content, !text.isEmpty {
                    await onPartialUpdate?(text)
                }
                let elapsed = String(format: "%.2fs", CFAbsoluteTimeGetCurrent() - startTime)
                await MainActor.run {
                    AppLogManager.shared.updateLog(
                        id: requestLogId,
                        category: .aiStop,
                        level: .info,
                        title: "\(stepPrefix)AI 响应完成 [\(settings.modelName)]",
                        summary: "耗时: \(elapsed) · 正文: \(parsed.content?.count ?? 0) 字 · 工具调用: \(parsed.toolCalls?.count ?? 0)",
                        details: "\(requestHeaderDetails)\n\nMode: Non-SSE JSON fallback"
                    )
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

        let elapsedStr = String(format: "%.2fs", CFAbsoluteTimeGetCurrent() - startTime)
        let fr = lastFinishReason ?? (receivedDoneMarker ? "stop(无显式finish_reason)" : "未收到finish_reason且未收到[DONE]")
        let toolCallCountResult = finalToolCalls?.count ?? 0
        let hasTextContent = !accumulatedContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let isLengthTruncated = (lastFinishReason == "length" || lastFinishReason == "max_tokens" || (lastFinishReason?.contains("incomplete") == true))
        let isPrematureEOF = (!receivedDoneMarker && lastFinishReason == nil)
        let isEmptyResponseTruncated = (!hasTextContent && toolCallCountResult == 0)
        let isAbnormalTruncation = (isLengthTruncated || isPrematureEOF || isEmptyResponseTruncated)

        let diagnosisNote: String
        if isLengthTruncated {
            diagnosisNote = "⚠️ 诊断结论：上游接口因达到最大输出 Token 限制 (finish_reason=\(fr)) 主动截断了输出。"
        } else if isPrematureEOF {
            diagnosisNote = "⚠️ 诊断结论：上游 HTTP 流在未发送 [DONE] 且未发送 finish_reason 的情况下提前关闭了连接（通常是反代超时或上游流中断）。"
        } else if isEmptyResponseTruncated {
            diagnosisNote = "⚠️ 诊断结论：上游流已结束 (finish_reason=\(fr), [DONE]=\(receivedDoneMarker))，但既未返回正文内容也未返回工具调用（思考长度: \(accumulatedReasoning.count) 字），属于空正文截断。"
        } else if toolCallCountResult > 0 && !hasTextContent {
            diagnosisNote = "✅ 诊断结论：上游正常结束本步流式传输并触发工具调用 (finish_reason=\(fr), 触发工具: \(toolCallCountResult) 个；工具调用中间步通常不输出正文，待工具执行完成后进入下一步继续生成)。"
        } else {
            diagnosisNote = "✅ 诊断结论：上游正常结束流式传输 (finish_reason=\(fr), [DONE]=\(receivedDoneMarker))。"
        }

        let logTitle: String
        if isAbnormalTruncation {
            logTitle = isEmptyResponseTruncated
                ? "\(stepPrefix)流式响应无正文截断 [\(settings.modelName)]"
                : "\(stepPrefix)流式输出异常截断 [\(settings.modelName)]"
        } else if toolCallCountResult > 0 && !hasTextContent {
            logTitle = "\(stepPrefix)AI 触发工具调用 [\(settings.modelName)]"
        } else {
            logTitle = "\(stepPrefix)AI 响应完成 [\(settings.modelName)]"
        }

        let tailPreview = String(accumulatedContent.suffix(160))
        let summarySuffix = toolCallCountResult > 0 ? " · 触发工具: \(toolCallCountResult) 个" : ""
        await MainActor.run {
            AppLogManager.shared.updateLog(
                id: requestLogId,
                category: isAbnormalTruncation ? .aiTruncated : .aiStop,
                level: isAbnormalTruncation ? .warning : .info,
                title: logTitle,
                summary: "耗时: \(elapsedStr) · 原因: \(fr) · [DONE]: \(receivedDoneMarker ? "是" : "否") · 正文: \(accumulatedContent.count) 字 · 帧数: \(sseChunkCount)\(summarySuffix)",
                details: "\(diagnosisNote)\n\n--- 请求参数 ---\n\(requestHeaderDetails)\n\n--- 流式响应统计 ---\nSSE Frames: \(sseChunkCount)\nFinish Reason: \(fr)\nReceived [DONE]: \(receivedDoneMarker)\nUsage: \(usageSummary.isEmpty ? "未返回" : usageSummary)\nContent Length: \(accumulatedContent.count) chars\nReasoning Length: \(accumulatedReasoning.count) chars\nTool Calls: \(toolCallCountResult)\nContent Tail (最后160字):\n\(tailPreview)\n\nLast SSE Data Frame:\n\(lastRawDataLine)"
            )
        }

        let trimmedReasoning = accumulatedReasoning.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalReasoning: String? = trimmedReasoning.isEmpty ? nil : trimmedReasoning
        let finalContent: String? = accumulatedContent.isEmpty ? nil : accumulatedContent
        return (finalContent, finalReasoning, finalToolCalls)
    }

    func prepareTools(servers: [MCPServer]) -> (definitions: [[String: Any]], serverMap: [String: (server: MCPServer, originalToolName: String)]) {
        var definitions: [[String: Any]] = []
        var serverMap: [String: (server: MCPServer, originalToolName: String)] = [:]

        for server in servers where server.isEnabled {
            for tool in server.tools where tool.isEnabled {
                let safeName = "\(server.id.prefix(6))_\(tool.name)".replacingOccurrences(of: "-", with: "_")
                serverMap[safeName] = (server, tool.rawName)
                let schemaObj = (try? JSONSerialization.jsonObject(with: Data(tool.inputSchemaJSON.utf8))) as? [String: Any] ?? ["type": "object", "properties": [:]]
                definitions.append([
                    "type": "function",
                    "function": [
                        "name": safeName,
                        "description": "[\(server.name)] \(tool.description)",
                        "parameters": schemaObj
                    ]
                ])
            }
        }

        return (definitions, serverMap)
    }

    func estimatePromptTokens(settings: OpenAISettings, messages: [ChatMessage], tools: [[String: Any]]? = nil) -> Int {
        let openAIMessages = buildOpenAIMessages(settings: settings, messages: messages)
        let messageTokens = estimatedTokenCount(in: openAIMessages) + openAIMessages.count * 3 + 3
        let toolTokens = tools.map { estimatedTokenCount(in: $0) } ?? 0
        return max(1, messageTokens + toolTokens)
    }

    private func contextTokenTotal(from usage: [String: Any]) -> Int? {
        guard let promptValue = usage["prompt_tokens"] ?? usage["input_tokens"],
              let prompt = tokenCount(from: promptValue),
              prompt > 0 else { return nil }
        var completion = (usage["completion_tokens"] ?? usage["output_tokens"]).flatMap { tokenCount(from: $0) } ?? 0
        let details = (usage["completion_tokens_details"] as? [String: Any]) ?? (usage["output_tokens_details"] as? [String: Any])
        if let reasoningValue = details?["reasoning_tokens"], let reasoning = tokenCount(from: reasoningValue) {
            completion = max(0, completion - reasoning)
        }
        return prompt + completion
    }

    private func tokenCount(from value: Any) -> Int? {
        guard let number = value as? NSNumber else { return nil }
        let count = number.intValue
        return count >= 0 ? count : nil
    }

    private func estimatedTokenCount(in value: Any) -> Int {
        if let text = value as? String {
            if text.hasPrefix("data:") && text.contains(";base64,") {
                return 85
            }
            return estimatedTokenCount(in: text)
        }
        if let dictionary = value as? [String: Any] {
            return dictionary.reduce(1) { total, entry in
                total + estimatedTokenCount(in: entry.key) + estimatedTokenCount(in: entry.value) + 1
            }
        }
        if let array = value as? [Any] {
            return array.reduce(1) { $0 + estimatedTokenCount(in: $1) }
        }
        return 1
    }

    private func estimatedTokenCount(in text: String) -> Int {
        var tokens = 0
        var asciiWordLength = 0
        var asciiPunctuationCount = 0

        for scalar in text.unicodeScalars {
            let value = scalar.value
            let isAsciiAlphaNumeric = (48...57).contains(value) || (65...90).contains(value) || (97...122).contains(value)
            if isAsciiAlphaNumeric {
                asciiWordLength += 1
                continue
            }

            if asciiWordLength > 0 {
                tokens += (asciiWordLength + 3) / 4
                asciiWordLength = 0
            }

            if value == 32 || (9...13).contains(value) {
                continue
            }
            if value < 128 {
                asciiPunctuationCount += 1
            } else {
                tokens += 1
            }
        }

        if asciiWordLength > 0 {
            tokens += (asciiWordLength + 3) / 4
        }
        tokens += (asciiPunctuationCount + 3) / 4
        return tokens
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
