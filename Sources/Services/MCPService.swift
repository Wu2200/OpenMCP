import Foundation

actor MCPService {
    static let shared = MCPService()

    private struct Session {
        var protocolVersion: String
        var sessionId: String?
        var url: URL
        var token: String
    }

    private let supportedProtocolVersion = "2024-11-05"
    private var sessions: [String: Session] = [:]

    private func session(for server: MCPServer, url: URL) async throws -> Session {
        let token = server.token.trimmingCharacters(in: .whitespacesAndNewlines)
        if let existing = sessions[server.id], existing.url == url, existing.token == token {
            return existing
        }
        sessions.removeValue(forKey: server.id)

        let requestId = UUID().uuidString
        let initBody: [String: Any] = [
            "jsonrpc": "2.0",
            "id": requestId,
            "method": "initialize",
            "params": [
                "protocolVersion": supportedProtocolVersion,
                "capabilities": [String: Any](),
                "clientInfo": [
                    "name": "OpenMCP-iOS",
                    "version": "1.0.0"
                ]
            ]
        ]
        let initRequest = try makeRequest(server: server, url: url, body: initBody, session: nil, timeout: 15)
        let (initData, initResponse) = try await send(initRequest)
        let parsedInit = try parseResponse(data: initData, expectedID: requestId)
        guard let initObject = parsedInit as? [String: Any] else {
            throw NSError(domain: "MCPService", code: -1, userInfo: [NSLocalizedDescriptionKey: "MCP 初始化响应格式无效"])
        }
        if let error = initObject["error"] as? [String: Any], let message = error["message"] as? String {
            throw NSError(domain: "MCPService", code: -1, userInfo: [NSLocalizedDescriptionKey: message])
        }
        guard let result = initObject["result"] as? [String: Any] else {
            throw NSError(domain: "MCPService", code: -1, userInfo: [NSLocalizedDescriptionKey: "MCP 初始化响应缺少 result"])
        }

        guard let negotiatedVersion = result["protocolVersion"] as? String,
              negotiatedVersion == supportedProtocolVersion else {
            let serverVersion = result["protocolVersion"] as? String ?? "缺失"
            throw NSError(
                domain: "MCPService",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "MCP 协议版本不兼容，客户端支持 \(supportedProtocolVersion)，服务端返回 \(serverVersion)"]
            )
        }

        let newSession = Session(
            protocolVersion: negotiatedVersion,
            sessionId: initResponse.value(forHTTPHeaderField: "Mcp-Session-Id"),
            url: url,
            token: token
        )
        let notification: [String: Any] = [
            "jsonrpc": "2.0",
            "method": "notifications/initialized"
        ]
        let notificationRequest = try makeRequest(server: server, url: url, body: notification, session: newSession, timeout: 10)
        _ = try await send(notificationRequest, serverId: server.id)
        sessions[server.id] = newSession
        return newSession
    }

    private func makeRequest(
        server: MCPServer,
        url: URL,
        body: [String: Any],
        session: Session?,
        timeout: TimeInterval
    ) throws -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("OpenMCP-iOS/1.0", forHTTPHeaderField: "User-Agent")
        let token = server.token.trimmingCharacters(in: .whitespacesAndNewlines)
        if !token.isEmpty {
            request.setValue(token.hasPrefix("Bearer ") ? token : "Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if let session = session {
            request.setValue(session.protocolVersion, forHTTPHeaderField: "MCP-Protocol-Version")
            if let sessionId = session.sessionId {
                request.setValue(sessionId, forHTTPHeaderField: "Mcp-Session-Id")
            }
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = timeout
        return request
    }

    private func send(_ request: URLRequest, serverId: String? = nil) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            if httpResponse.statusCode == 404, let serverId = serverId {
                sessions.removeValue(forKey: serverId)
            }
            let responseText = String(data: data, encoding: .utf8) ?? ""
            throw NSError(
                domain: "MCPService",
                code: httpResponse.statusCode,
                userInfo: [NSLocalizedDescriptionKey: "MCP 请求失败 (HTTP \(httpResponse.statusCode)): \(responseText.prefix(200))"]
            )
        }
        return (data, httpResponse)
    }

    func fetchTools(from server: MCPServer) async throws -> [MCPTool] {
        guard let url = URL(string: server.url.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw URLError(.badURL)
        }

        let activeSession = try await session(for: server, url: url)
        var toolsArray: [[String: Any]] = []
        var cursor: String? = nil
        var seenCursors: Set<String> = []

        while true {
            let requestId = UUID().uuidString
            var params: [String: Any] = [:]
            if let cursor = cursor {
                params["cursor"] = cursor
            }
            let listBody: [String: Any] = [
                "jsonrpc": "2.0",
                "id": requestId,
                "method": "tools/list",
                "params": params
            ]
            let listRequest = try makeRequest(server: server, url: url, body: listBody, session: activeSession, timeout: 25)
            let (data, _) = try await send(listRequest, serverId: server.id)
            let parsedJSON = try parseResponse(data: data, expectedID: requestId)
            guard let dict = parsedJSON as? [String: Any] else {
                throw NSError(domain: "MCPService", code: -1, userInfo: [NSLocalizedDescriptionKey: "MCP 返回数据格式无效"])
            }

            if let error = dict["error"] as? [String: Any] {
                let message = error["message"] as? String ?? "未知 JSON-RPC 错误"
                throw NSError(domain: "MCPService", code: -1, userInfo: [NSLocalizedDescriptionKey: message])
            }

            guard let result = dict["result"] as? [String: Any],
                  let pageTools = result["tools"] as? [[String: Any]] else {
                throw NSError(domain: "MCPService", code: -1, userInfo: [NSLocalizedDescriptionKey: "MCP 工具列表响应缺少 tools"])
            }
            toolsArray.append(contentsOf: pageTools)

            guard let nextCursor = result["nextCursor"] as? String, !nextCursor.isEmpty else {
                break
            }
            guard seenCursors.insert(nextCursor).inserted else {
                throw NSError(domain: "MCPService", code: -1, userInfo: [NSLocalizedDescriptionKey: "MCP 工具列表返回了重复分页游标"])
            }
            cursor = nextCursor
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

        let activeSession = try await session(for: server, url: url)
        var parsedArgs: Any = [String: Any]()
        if let argsData = argumentsJSON.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: argsData) {
            parsedArgs = obj
        }

        let requestId = UUID().uuidString
        let callPayload: [String: Any] = [
            "jsonrpc": "2.0",
            "id": requestId,
            "method": "tools/call",
            "params": [
                "name": rawName,
                "arguments": parsedArgs
            ]
        ]
        let request = try makeRequest(server: server, url: url, body: callPayload, session: activeSession, timeout: 60)
        let (data, _) = try await send(request, serverId: server.id)
        let parsedJSON = try parseResponse(data: data, expectedID: requestId)
        guard let dict = parsedJSON as? [String: Any] else {
            return String(data: data, encoding: .utf8) ?? "{}"
        }

        if let error = dict["error"] as? [String: Any], let msg = error["message"] as? String {
            throw NSError(domain: "MCPService", code: -1, userInfo: [NSLocalizedDescriptionKey: msg])
        }

        let resultObj = dict["result"] ?? dict
        return extractContent(from: resultObj)
    }

    private func parseResponse(data: Data, expectedID: String? = nil) throws -> Any {
        if let json = try? JSONSerialization.jsonObject(with: data), responseMatches(json, expectedID: expectedID) {
            return json
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw NSError(domain: "MCPService", code: -1, userInfo: [NSLocalizedDescriptionKey: "无法解析 MCP 响应"])
        }

        var dataLines: [String] = []
        var matchedResponse: Any? = nil
        func flushEvent() {
            guard !dataLines.isEmpty else { return }
            let payload = dataLines.joined(separator: "\n")
            dataLines.removeAll(keepingCapacity: true)
            guard payload != "[DONE]",
                  let payloadData = payload.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: payloadData),
                  responseMatches(object, expectedID: expectedID) else { return }
            matchedResponse = object
        }

        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
            if line.isEmpty {
                flushEvent()
                continue
            }
            if line.hasPrefix(":") { continue }
            if line.hasPrefix("data:") {
                var value = String(line.dropFirst(5))
                if value.first == " " {
                    value.removeFirst()
                }
                dataLines.append(value)
            }
        }
        flushEvent()

        if let matchedResponse = matchedResponse {
            return matchedResponse
        }
        let description = expectedID == nil ? "无法解析 MCP 响应" : "未找到与请求 ID 匹配的 MCP 响应"
        throw NSError(domain: "MCPService", code: -1, userInfo: [NSLocalizedDescriptionKey: description])
    }

    private func responseMatches(_ object: Any, expectedID: String?) -> Bool {
        guard let expectedID = expectedID else { return true }
        guard let dictionary = object as? [String: Any],
              let responseID = dictionary["id"] as? String else { return false }
        return responseID == expectedID
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
