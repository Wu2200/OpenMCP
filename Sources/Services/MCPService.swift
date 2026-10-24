import Foundation

class MCPService {
    static let shared = MCPService()

    func fetchTools(from server: MCPServer) async throws -> [MCPTool] {
        guard let url = URL(string: server.url.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw URLError(.badURL)
        }

        var headers: [String: String] = [
            "Content-Type": "application/json",
            "Accept": "application/json, text/event-stream",
            "User-Agent": "OpenMCP-iOS/1.0"
        ]

        if !server.token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let token = server.token.trimmingCharacters(in: .whitespacesAndNewlines)
            headers["Authorization"] = token.hasPrefix("Bearer ") ? token : "Bearer \(token)"
        }

        let initBody: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 1,
            "method": "initialize",
            "params": [
                "protocolVersion": "2024-11-05",
                "capabilities": [String: Any](),
                "clientInfo": [
                    "name": "OpenMCP-iOS",
                    "version": "1.0.0"
                ]
            ]
        ]

        var initReq = URLRequest(url: url)
        initReq.httpMethod = "POST"
        for (k, v) in headers {
            initReq.setValue(v, forHTTPHeaderField: k)
        }
        initReq.httpBody = try? JSONSerialization.data(withJSONObject: initBody)
        initReq.timeoutInterval = 15

        _ = try? await URLSession.shared.data(for: initReq)

        let notifBody: [String: Any] = [
            "jsonrpc": "2.0",
            "method": "notifications/initialized"
        ]
        var notifReq = URLRequest(url: url)
        notifReq.httpMethod = "POST"
        for (k, v) in headers {
            notifReq.setValue(v, forHTTPHeaderField: k)
        }
        notifReq.httpBody = try? JSONSerialization.data(withJSONObject: notifBody)
        notifReq.timeoutInterval = 10
        _ = try? await URLSession.shared.data(for: notifReq)

        let listBody: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 2,
            "method": "tools/list",
            "params": [String: Any]()
        ]

        var listReq = URLRequest(url: url)
        listReq.httpMethod = "POST"
        for (k, v) in headers {
            listReq.setValue(v, forHTTPHeaderField: k)
        }
        listReq.httpBody = try JSONSerialization.data(withJSONObject: listBody)
        listReq.timeoutInterval = 25

        let (data, response) = try await URLSession.shared.data(for: listReq)
        guard let httpRes = response as? HTTPURLResponse, (200...299).contains(httpRes.statusCode) else {
            let resText = String(data: data, encoding: .utf8) ?? ""
            throw NSError(domain: "MCPService", code: (response as? HTTPURLResponse)?.statusCode ?? 500, userInfo: [NSLocalizedDescriptionKey: "MCP 请求失败: \(resText.prefix(200))"])
        }

        let parsedJSON = try parseResponse(data: data)
        guard let dict = parsedJSON as? [String: Any] else {
            throw NSError(domain: "MCPService", code: -1, userInfo: [NSLocalizedDescriptionKey: "MCP 返回数据格式无效"])
        }

        if let error = dict["error"] as? [String: Any], let msg = error["message"] as? String {
            throw NSError(domain: "MCPService", code: -1, userInfo: [NSLocalizedDescriptionKey: msg])
        }

        guard let result = dict["result"] as? [String: Any],
              let toolsArray = result["tools"] as? [[String: Any]] else {
            return []
        }

        let prefix = server.name.lowercased().filter { $0.isLetter || $0.isNumber || $0 == "_" }
        var tools: [MCPTool] = []

        for raw in toolsArray {
            guard let rawName = raw["name"] as? String else { continue }
            let desc = (raw["description"] as? String) ?? rawName
            let sanitizedRaw = rawName.filter { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }
            let toolKey = sanitizedRaw.hasPrefix("\(prefix)_") ? sanitizedRaw : "\(prefix)_\(sanitizedRaw)"

            var schemaStr = "{}"
            if let schema = raw["inputSchema"],
               let schemaData = try? JSONSerialization.data(withJSONObject: schema),
               let str = String(data: schemaData, encoding: .utf8) {
                schemaStr = str
            }

            tools.append(MCPTool(name: toolKey, rawName: rawName, description: desc, inputSchemaJSON: schemaStr, isEnabled: true))
        }

        return tools
    }

    func callTool(server: MCPServer, rawName: String, argumentsJSON: String) async throws -> String {
        guard let url = URL(string: server.url.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw URLError(.badURL)
        }

        var headers: [String: String] = [
            "Content-Type": "application/json",
            "Accept": "application/json, text/event-stream",
            "User-Agent": "OpenMCP-iOS/1.0"
        ]

        if !server.token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let token = server.token.trimmingCharacters(in: .whitespacesAndNewlines)
            headers["Authorization"] = token.hasPrefix("Bearer ") ? token : "Bearer \(token)"
        }

        var parsedArgs: Any = [String: Any]()
        if let argsData = argumentsJSON.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: argsData) {
            parsedArgs = obj
        }

        let callPayload: [String: Any] = [
            "jsonrpc": "2.0",
            "id": Int(Date().timeIntervalSince1970),
            "method": "tools/call",
            "params": [
                "name": rawName,
                "arguments": parsedArgs
            ]
        ]

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        for (k, v) in headers {
            req.setValue(v, forHTTPHeaderField: k)
        }
        req.httpBody = try JSONSerialization.data(withJSONObject: callPayload)
        req.timeoutInterval = 60

        let (data, response) = try await URLSession.shared.data(for: req)
        guard let httpRes = response as? HTTPURLResponse, (200...299).contains(httpRes.statusCode) else {
            let errText = String(data: data, encoding: .utf8) ?? ""
            throw NSError(domain: "MCPService", code: (response as? HTTPURLResponse)?.statusCode ?? 500, userInfo: [NSLocalizedDescriptionKey: "HTTP \(httpRes.statusCode): \(errText.prefix(200))"])
        }

        let parsedJSON = try parseResponse(data: data)
        guard let dict = parsedJSON as? [String: Any] else {
            return String(data: data, encoding: .utf8) ?? "{}"
        }

        if let error = dict["error"] as? [String: Any], let msg = error["message"] as? String {
            throw NSError(domain: "MCPService", code: -1, userInfo: [NSLocalizedDescriptionKey: msg])
        }

        let resultObj = dict["result"] ?? dict
        return extractContent(from: resultObj)
    }

    private func parseResponse(data: Data) throws -> Any {
        if let json = try? JSONSerialization.jsonObject(with: data) {
            return json
        }
        if let text = String(data: data, encoding: .utf8) {
            let lines = text.components(separatedBy: "\n")
            for line in lines {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("data:") {
                    let payload = String(trimmed.dropFirst(5)).trimmingCharacters(in: .whitespaces)
                    if let payloadData = payload.data(using: .utf8),
                       let obj = try? JSONSerialization.jsonObject(with: payloadData) {
                        return obj
                    }
                }
            }
        }
        throw NSError(domain: "MCPService", code: -1, userInfo: [NSLocalizedDescriptionKey: "无法解析 MCP 响应"])
    }

    private func extractContent(from object: Any) -> String {
        if let dict = object as? [String: Any] {
            if let contentArray = dict["content"] as? [[String: Any]] {
                var pieces: [String] = []
                for item in contentArray {
                    if let text = item["text"] as? String {
                        pieces.append(text)
                    } else if let resource = item["resource"] as? [String: Any] {
                        if let resText = resource["text"] as? String {
                            pieces.append(resText)
                        } else if let blob = resource["blob"] as? String,
                                  let data = Data(base64Encoded: blob),
                                  let decoded = String(data: data, encoding: .utf8) {
                            pieces.append(decoded)
                        }
                    }
                }
                if !pieces.isEmpty {
                    return pieces.joined(separator: "\n\n")
                }
            }
            if let isError = dict["isError"] as? Bool, isError {
                if let msg = dict["message"] as? String {
                    return "执行失败: \(msg)"
                }
            }
            if let data = try? JSONSerialization.data(withJSONObject: dict, options: .prettyPrinted),
               let str = String(data: data, encoding: .utf8) {
                return str
            }
        }
        if let str = object as? String {
            return str
        }
        return String(describing: object)
    }
}
