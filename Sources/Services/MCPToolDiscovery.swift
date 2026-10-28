import Foundation

enum MCPToolDiscovery {
    static let functionName = "openmcp_discover_mcp_tools"
    static let maximumSearchRounds = 4
    private static let maximumToolsPerSearch = 12
    private static let maximumSchemaTokensPerSearch = 8_192

    static let definition: [String: Any] = [
        "type": "function",
        "function": [
            "name": functionName,
            "description": "在执行 MCP 操作前，根据用户任务搜索最相关的可用 MCP 工具。请使用简短英文关键词，包含服务、动作和目标对象。普通问答不要调用此工具。搜索到的工具会在下一轮作为可调用工具提供。",
            "parameters": [
                "type": "object",
                "properties": [
                    "query": [
                        "type": "string",
                        "description": "简短英文搜索词，例如 GitHub list open issues 或 Cloudflare list DNS records。"
                    ]
                ],
                "required": ["query"],
                "additionalProperties": false
            ]
        ]
    ]

    static func isDiscoveryCall(name: String) -> Bool {
        name == functionName
    }

    static func query(from arguments: String) -> String {
        guard let data = arguments.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let query = object["query"] as? String else {
            return ""
        }
        return String(query.trimmingCharacters(in: .whitespacesAndNewlines).prefix(240))
    }

    static func selectTools(
        query: String,
        allTools: [[String: Any]],
        settings: OpenAISettings,
        messages: [ChatMessage]
    ) -> [[String: Any]] {
        let queryTerms = terms(in: query)
        guard !queryTerms.isEmpty, !allTools.isEmpty else { return [] }

        let contextLimit = max(4_096, settings.contextWindowTokens)
        let outputReserve = max(512, min(contextLimit / 10, 8_192))
        let inputBudget = max(1, contextLimit - outputReserve)
        let latestUserMessage = messages.last(where: { $0.role == .user })
        let fixedTokens = ContextPruner.estimatedTokenCount(settings.systemPrompt)
            + ContextPruner.estimatedMessageTokens(latestUserMessage.map { [$0] } ?? [])
            + ContextPruner.toolSchemaTokens([definition])
            + 512
        let availableSchemaTokens = min(
            maximumSchemaTokensPerSearch,
            max(0, inputBudget - fixedTokens)
        )
        guard availableSchemaTokens > 0 else { return [] }

        let rankedTools = allTools.enumerated().compactMap { index, tool -> (Int, Int, [String: Any])? in
            let score = relevanceScore(queryTerms: queryTerms, tool: tool)
            guard score > 0 else { return nil }
            return (score, index, tool)
        }.sorted {
            if $0.0 == $1.0 {
                return $0.1 < $1.1
            }
            return $0.0 > $1.0
        }

        var selected: [[String: Any]] = []
        for (_, _, tool) in rankedTools {
            guard selected.count < maximumToolsPerSearch else { break }
            let candidate = selected + [tool]
            guard ContextPruner.toolSchemaTokens(candidate) <= availableSchemaTokens else { continue }
            selected = candidate
        }
        return selected
    }

    static func result(query: String, tools: [[String: Any]]) -> String {
        guard !tools.isEmpty else {
            return "没有找到与该查询匹配且能放入当前上下文预算的 MCP 工具。请用更具体的英文服务名、动作和对象重新搜索；不要猜测或调用未提供的工具。"
        }
        let names = tools.compactMap { tool in
            (tool["function"] as? [String: Any])?["name"] as? String
        }
        return "已按查询加载最相关的 MCP 工具。完整工具定义已出现在本轮可用工具列表中，请从中选择并执行匹配的工具。已加载：\(names.joined(separator: ", "))。"
    }

    private static func relevanceScore(queryTerms: Set<String>, tool: [String: Any]) -> Int {
        guard let function = tool["function"] as? [String: Any] else { return 0 }
        let name = function["name"] as? String ?? ""
        let description = function["description"] as? String ?? ""
        let schema = function["parameters"] as? [String: Any] ?? [:]
        let schemaText: String
        if let data = try? JSONSerialization.data(withJSONObject: schema, options: [.sortedKeys]) {
            schemaText = String(data: data, encoding: .utf8) ?? ""
        } else {
            schemaText = ""
        }

        let nameTerms = terms(in: name)
        let descriptionTerms = terms(in: description)
        let schemaTerms = terms(in: schemaText)
        let nameMatches = queryTerms.intersection(nameTerms).count
        let descriptionMatches = queryTerms.intersection(descriptionTerms).count
        let schemaMatches = queryTerms.intersection(schemaTerms).count
        var score = nameMatches * 8 + descriptionMatches * 4 + schemaMatches

        let normalizedQuery = queryTerms.sorted().joined(separator: " ")
        let normalizedName = name.lowercased().replacingOccurrences(of: "_", with: " ")
        if !normalizedQuery.isEmpty && normalizedName.contains(normalizedQuery) {
            score += 12
        }
        return score
    }

    private static func terms(in text: String) -> Set<String> {
        let ignored: Set<String> = [
            "a", "an", "the", "and", "or", "for", "with", "from", "into", "using", "use",
            "tool", "tools", "mcp", "please", "find", "search", "available", "related", "relevant",
            "that", "this", "which", "what", "when", "where", "how", "can", "could", "would"
        ]
        let parts = text.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted)
        return Set(parts.filter { $0.count > 1 && !ignored.contains($0) })
    }
}
