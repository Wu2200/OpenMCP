import Foundation
import SwiftUI
import Combine

@MainActor
class AgentCoordinator: ObservableObject {
    @Published var isGenerating: Bool = false
    @Published var statusText: String = ""
    @Published var errorMessage: String? = nil

    private var currentTask: Task<Void, Never>? = nil

    func sendMessage(
        conversation: inout Conversation,
        userPrompt: String,
        settings: OpenAISettings,
        servers: [MCPServer]
    ) async {
        guard !userPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        errorMessage = nil
        isGenerating = true
        statusText = "思考中..."

        let userMsg = ChatMessage(role: .user, content: userPrompt)
        conversation.messages.append(userMsg)
        conversation.updatedAt = Date()
        DataStorage.shared.updateConversation(conversation)

        var activeToolsMap: [String: (server: MCPServer, rawName: String)] = [:]
        var openAITools: [[String: Any]] = []

        for server in servers where server.isEnabled {
            for tool in server.tools where tool.isEnabled {
                activeToolsMap[tool.name] = (server, tool.rawName)

                var paramsObj: Any = ["type": "object", "properties": [String: Any]()]
                if let schemaData = tool.inputSchemaJSON.data(using: .utf8),
                   let parsed = try? JSONSerialization.jsonObject(with: schemaData) {
                    paramsObj = parsed
                }

                openAITools.append([
                    "type": "function",
                    "function": [
                        "name": tool.name,
                        "description": "[\(server.name)] \(tool.description)",
                        "parameters": paramsObj
                    ]
                ])
            }
        }

        currentTask = Task {
            var loopCount = 0
            let maxLoops = 8

            while loopCount < maxLoops {
                if Task.isCancelled { break }
                loopCount += 1

                do {
                    statusText = loopCount == 1 ? "思考中..." : "综合工具调用结果思考中..."
                    let result = try await OpenAIService.shared.chatCompletion(
                        settings: settings,
                        messages: conversation.messages,
                        tools: openAITools.isEmpty ? nil : openAITools
                    )

                    if let toolCalls = result.toolCalls, !toolCalls.isEmpty {
                        let assistantMsg = ChatMessage(
                            role: .assistant,
                            content: result.content ?? "",
                            toolCalls: toolCalls
                        )
                        conversation.messages.append(assistantMsg)
                        DataStorage.shared.updateConversation(conversation)

                        let assistantIndex = conversation.messages.count - 1

                        for i in 0..<toolCalls.count {
                            if Task.isCancelled { break }
                            let call = toolCalls[i]
                            statusText = "正在调用工具: \(call.name)..."

                            conversation.messages[assistantIndex].toolCalls?[i].isExecuting = true
                            DataStorage.shared.updateConversation(conversation)

                            var execResult = ""
                            var execError: String? = nil

                            if let target = activeToolsMap[call.name] {
                                do {
                                    execResult = try await MCPService.shared.callTool(
                                        server: target.server,
                                        rawName: target.rawName,
                                        argumentsJSON: call.arguments
                                    )
                                } catch {
                                    execError = error.localizedDescription
                                    execResult = "错误: \(error.localizedDescription)"
                                }
                            } else {
                                execError = "未找到已启用的目标 MCP 工具"
                                execResult = "错误: 未找到该工具对应的 MCP 服务"
                            }

                            conversation.messages[assistantIndex].toolCalls?[i].isExecuting = false
                            conversation.messages[assistantIndex].toolCalls?[i].result = execResult
                            conversation.messages[assistantIndex].toolCalls?[i].error = execError

                            let toolMsg = ChatMessage(
                                role: .tool,
                                content: execResult,
                                toolCalls: nil,
                                toolCallId: call.id
                            )
                            conversation.messages.append(toolMsg)
                            conversation.updatedAt = Date()
                            DataStorage.shared.updateConversation(conversation)
                        }
                    } else {
                        let finalContent = result.content ?? ""
                        let assistantMsg = ChatMessage(
                            role: .assistant,
                            content: finalContent
                        )
                        conversation.messages.append(assistantMsg)
                        conversation.updatedAt = Date()
                        DataStorage.shared.updateConversation(conversation)
                        break
                    }
                } catch {
                    if !Task.isCancelled {
                        self.errorMessage = error.localizedDescription
                    }
                    break
                }
            }

            self.isGenerating = false
            self.statusText = ""
        }

        await currentTask?.value
    }

    func cancel() {
        currentTask?.cancel()
        currentTask = nil
        isGenerating = false
        statusText = ""
    }
}
