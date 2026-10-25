import Foundation
import SwiftUI
import Combine

@MainActor
class AgentCoordinator: ObservableObject {
    @Published var isGenerating: Bool = false
    @Published var statusText: String = ""
    @Published var errorMessage: String? = nil

    func sendMessage(
        conversationId: String,
        userPrompt: String,
        settings: OpenAISettings,
        servers: [MCPServer]
    ) async {
        let trimmed = userPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard var conversation = DataStorage.shared.conversations.first(where: { $0.id == conversationId }) else { return }

        let userMsg = ChatMessage(role: .user, content: trimmed)
        conversation.messages.append(userMsg)
        conversation.updatedAt = Date()
        if conversation.messages.filter({ $0.role == .user }).count == 1 && conversation.title == "新对话" {
            conversation.title = String(trimmed.prefix(18))
        }
        DataStorage.shared.updateConversation(conversation)

        await runGenerationLoop(conversationId: conversationId, settings: settings, servers: servers)
    }

    func retryFromMessage(
        conversationId: String,
        messageId: String,
        newPrompt: String? = nil,
        settings: OpenAISettings,
        servers: [MCPServer]
    ) async {
        guard var conversation = DataStorage.shared.conversations.first(where: { $0.id == conversationId }) else { return }
        guard let idx = conversation.messages.firstIndex(where: { $0.id == messageId }) else { return }

        if conversation.messages[idx].role == .user {
            if let updated = newPrompt?.trimmingCharacters(in: .whitespacesAndNewlines), !updated.isEmpty {
                conversation.messages[idx].content = updated
            }
            if idx + 1 < conversation.messages.count {
                conversation.messages.removeSubrange((idx + 1)..<conversation.messages.count)
            }
        } else {
            if let userIdx = conversation.messages[0...idx].lastIndex(where: { $0.role == .user }) {
                if userIdx + 1 < conversation.messages.count {
                    conversation.messages.removeSubrange((userIdx + 1)..<conversation.messages.count)
                }
            } else {
                conversation.messages.removeSubrange(idx..<conversation.messages.count)
            }
        }

        conversation.updatedAt = Date()
        DataStorage.shared.updateConversation(conversation)

        await runGenerationLoop(conversationId: conversationId, settings: settings, servers: servers)
    }

    private func runGenerationLoop(
        conversationId: String,
        settings: OpenAISettings,
        servers: [MCPServer]
    ) async {
        guard var conversation = DataStorage.shared.conversations.first(where: { $0.id == conversationId }) else { return }

        errorMessage = nil
        isGenerating = true
        statusText = "思考中..."

        var openAITools: [[String: Any]] = []
        var toolServerMap: [String: (server: MCPServer, originalToolName: String)] = [:]

        for server in servers where server.isEnabled {
            for tool in server.tools where tool.isEnabled {
                let safeName = "\(server.id.prefix(6))_\(tool.name)".replacingOccurrences(of: "-", with: "_")
                toolServerMap[safeName] = (server, tool.name)
                let schemaObj = (try? JSONSerialization.jsonObject(with: Data(tool.inputSchemaJSON.utf8))) as? [String: Any] ?? ["type": "object", "properties": [:]]
                openAITools.append([
                    "type": "function",
                    "function": [
                        "name": safeName,
                        "description": "[\(server.name)] \(tool.description)",
                        "parameters": schemaObj
                    ]
                ])
            }
        }

        var maxIterations = 8
        while maxIterations > 0 {
            maxIterations -= 1
            do {
                let (content, toolCalls) = try await OpenAIService.shared.chatCompletion(
                    settings: settings,
                    messages: conversation.messages,
                    tools: openAITools.isEmpty ? nil : openAITools
                )

                var assistantMsg = ChatMessage(
                    role: .assistant,
                    content: content ?? "",
                    toolCalls: toolCalls
                )

                if let calls = toolCalls, !calls.isEmpty {
                    var executingCalls = calls.map { c -> ToolCallItem in
                        var item = c
                        item.isExecuting = true
                        return item
                    }
                    assistantMsg.toolCalls = executingCalls
                    conversation.messages.append(assistantMsg)
                    DataStorage.shared.updateConversation(conversation)

                    let msgIndex = conversation.messages.count - 1

                    for i in executingCalls.indices {
                        let call = executingCalls[i]
                        statusText = "正在调用工具: \(call.name)..."

                        var toolOutput = ""
                        if let mapping = toolServerMap[call.name] {
                            let argsDict = (try? JSONSerialization.jsonObject(with: Data(call.arguments.utf8))) as? [String: Any] ?? [:]
                            do {
                                toolOutput = try await MCPService.shared.callTool(
                                    on: mapping.server,
                                    toolName: mapping.originalToolName,
                                    arguments: argsDict
                                )
                                executingCalls[i].result = toolOutput
                            } catch {
                                let errStr = "Error: \(error.localizedDescription)"
                                toolOutput = errStr
                                executingCalls[i].error = error.localizedDescription
                                executingCalls[i].result = errStr
                            }
                        } else {
                            toolOutput = "Error: 未找到对应的 MCP 工具映射 (\(call.name))"
                            executingCalls[i].error = "未找到工具"
                            executingCalls[i].result = toolOutput
                        }

                        executingCalls[i].isExecuting = false
                        conversation.messages[msgIndex].toolCalls = executingCalls

                        let toolMsg = ChatMessage(
                            role: .tool,
                            content: toolOutput,
                            toolCallId: call.id
                        )
                        conversation.messages.append(toolMsg)
                        DataStorage.shared.updateConversation(conversation)
                    }

                    statusText = "整理工具结果..."
                } else {
                    conversation.messages.append(assistantMsg)
                    conversation.updatedAt = Date()
                    DataStorage.shared.updateConversation(conversation)
                    break
                }
            } catch {
                errorMessage = error.localizedDescription
                break
            }
        }

        isGenerating = false
        statusText = ""
    }
}
