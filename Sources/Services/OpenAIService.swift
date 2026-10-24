import Foundation

class OpenAIService {
    static let shared = OpenAIService()

    func chatCompletion(
        settings: OpenAISettings,
        messages: [ChatMessage],
        tools: [[String: Any]]? = nil
    ) async throws -> (content: String?, toolCalls: [ToolCallItem]?) {
        var base = settings.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if base.hasSuffix("/") {
            base = String(base.dropLast())
        }
        let fullEndpoint = base.hasSuffix("/chat/completions") ? base : "\(base)/chat/completions"
        guard let url = URL(string: fullEndpoint) else {
            throw URLError(.badURL)
        }

        var openAIMessages: [[String: Any]] = []
        if !settings.systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            openAIMessages.append([
                "role": "system",
                "content": settings.systemPrompt
            ])
        }

        for msg in messages {
            var m: [String: Any] = [
                "role": msg.role.rawValue,
                "content": msg.content
            ]
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

        var payload: [String: Any] = [
            "model": settings.modelName,
            "temperature": settings.temperature,
            "messages": openAIMessages
        ]

        if let tools = tools, !tools.isEmpty {
            payload["tools"] = tools
        }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !settings.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let key = settings.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
            req.setValue(key.hasPrefix("Bearer ") ? key : "Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        req.httpBody = try JSONSerialization.data(withJSONObject: payload)
        req.timeoutInterval = 90

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
            throw NSError(domain: "OpenAIService", code: httpRes.statusCode, userInfo: [NSLocalizedDescriptionKey: "API 响应错误 (\(httpRes.statusCode)): \(errString.prefix(200))"])
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
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
