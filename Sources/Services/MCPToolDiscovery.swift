import Foundation

enum MCPToolDiscovery {
    static let functionName = "openmcp_discover_mcp_tools"
    static let maximumSearchRounds = 8
    static let definition: [String: Any] = [
        "type": "function",
        "function": [
            "name": functionName,
            "description": "当用户请求需要访问或修改已启用 MCP 服务中的实时数据时，必须先调用此工具搜索相关操作。普通知识问答、闲聊和纯文本处理不要调用。使用简短英文关键词，包含服务、动作和目标对象；搜索本身不执行操作，匹配到的真实工具会在下一轮提供。",
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
        existingTools: [[String: Any]],
        settings: OpenAISettings,
        messages: [ChatMessage]
    ) -> [[String: Any]] {
        let queryTerms = terms(in: query)
        guard !queryTerms.isEmpty, !allTools.isEmpty else { return [] }

        var selected: [[String: Any]] = []
        var selectedNames = Set<String>()
        for tool in existingTools {
            guard let name = (tool["function"] as? [String: Any])?["name"] as? String,
                  selectedNames.insert(name).inserted else { continue }
            selected.append(tool)
        }

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

        for (_, _, tool) in rankedTools {
            guard let name = (tool["function"] as? [String: Any])?["name"] as? String,
                  selectedNames.insert(name).inserted else { continue }
            selected.append(tool)
        }
        return selected
    }

    static func result(query: String, tools: [[String: Any]]) -> String {
        guard !tools.isEmpty else {
            return "没有找到与该查询匹配的已启用 MCP 工具。请用更具体的英文服务名、动作和对象重新搜索；不要猜测或调用未提供的工具。"
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
        let separatedCamelCase = text
            .replacingOccurrences(of: "([a-z0-9])([A-Z])", with: "$1 $2", options: .regularExpression)
            .replacingOccurrences(of: "([A-Z])([A-Z][a-z])", with: "$1 $2", options: .regularExpression)
        let parts = separatedCamelCase.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted)
        return Set(parts.filter { $0.count > 1 && !ignored.contains($0) })
    }
}
