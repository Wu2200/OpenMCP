import Foundation
import SwiftUI
import Combine

@MainActor
class AgentCoordinator: ObservableObject {
    @Published var isGenerating: Bool = false
    @Published var statusText: String = ""
    @Published var errorMessage: String? = nil
    @Published var thinkingStartTime: Date? = nil

    func sendMessage(
        conversationId: String,
        userPrompt: String,
        attachments: [ChatAttachment] = [],
        settings: OpenAISettings,
        servers: [MCPServer]
    ) async {
        let trimmed = userPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !attachments.isEmpty else { return }
        guard var conversation = DataStorage.shared.conversations.first(where: { $0.id == conversationId }) else { return }

        var finalContent = trimmed
        var finalAttachments = attachments

        if ChatAttachment.shouldPackageAsLongText(trimmed) {
            let packaged = ChatAttachment.makeLongTextAttachment(from: trimmed)
            finalAttachments.append(packaged)
            finalContent = ""
        }

        let userMsg = ChatMessage(
            role: .user,
            content: finalContent,
            attachments: finalAttachments.isEmpty ? nil : finalAttachments
        )
        conversation.messages.append(userMsg)
        conversation.updatedAt = Date()

        if conversation.messages.filter({ $0.role == .user }).count == 1 && conversation.title == "新对话" {
            if !trimmed.isEmpty {
                let firstLine = trimmed.components(separatedBy: .newlines).first ?? trimmed
                conversation.title = String(firstLine.prefix(18))
            } else if let firstAtt = finalAttachments.first {
                conversation.title = String(firstAtt.fileName.prefix(18))
            }
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
                let nonLongAttachments = (conversation.messages[idx].attachments ?? []).filter { $0.kind != .longText }
                if ChatAttachment.shouldPackageAsLongText(updated) {
                    var newAtts = nonLongAttachments
                    newAtts.append(ChatAttachment.makeLongTextAttachment(from: updated))
                    conversation.messages[idx].content = ""
                    conversation.messages[idx].attachments = newAtts
                } else {
                    conversation.messages[idx].content = updated
                    conversation.messages[idx].attachments = nonLongAttachments.isEmpty ? nil : nonLongAttachments
                }
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
        thinkingStartTime = Date()
        statusText = "思考中"

        var openAITools: [[String: Any]] = []
        var toolServerMap: [String: (server: MCPServer, originalToolName: String)] = [:]

        for server in servers where server.isEnabled {
            for tool in server.tools where tool.isEnabled {
                let safeName = "\(server.id.prefix(6))_\(tool.name)".replacingOccurrences(of: "-", with: "_")
                toolServerMap[safeName] = (server, tool.rawName)
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
            let contextMessages = conversation.messages

            let placeholderMsg = ChatMessage(
                role: .assistant,
                content: "",
                toolCalls: nil
            )
            conversation.messages.append(placeholderMsg)
            let msgIndex = conversation.messages.count - 1
            DataStorage.shared.updateConversation(conversation, persistImmediately: false)

            do {
                let (content, toolCalls) = try await OpenAIService.shared.streamChatCompletion(
                    settings: settings,
                    messages: contextMessages,
                    tools: openAITools.isEmpty ? nil : openAITools,
                    onPartialUpdate: { [weak self] partialText in
                        guard let self = self else { return }
                        self.statusText = "思考中"
                        if msgIndex < conversation.messages.count {
                            conversation.messages[msgIndex].content = partialText
                            DataStorage.shared.updateConversation(conversation, persistImmediately: false)
                        }
                    }
                )

                conversation.messages[msgIndex].content = content ?? ""

                if let calls = toolCalls, !calls.isEmpty {
                    var executingCalls = calls.map { c -> ToolCallItem in
                        var item = c
                        item.isExecuting = true
                        return item
                    }
                    conversation.messages[msgIndex].toolCalls = executingCalls
                    DataStorage.shared.updateConversation(conversation)

                    for i in executingCalls.indices {
                        let call = executingCalls[i]
                        statusText = "调用工具中"

                        var toolOutput = ""
                        if let mapping = toolServerMap[call.name] {
                            do {
                                toolOutput = try await MCPService.shared.callTool(
                                    server: mapping.server,
                                    rawName: mapping.originalToolName,
                                    argumentsJSON: call.arguments
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

                    statusText = "思考中"
                } else {
                    conversation.updatedAt = Date()
                    DataStorage.shared.updateConversation(conversation, persistImmediately: true)
                    break
                }
            } catch {
                if msgIndex < conversation.messages.count,
                   conversation.messages[msgIndex].content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                   (conversation.messages[msgIndex].toolCalls ?? []).isEmpty {
                    conversation.messages.remove(at: msgIndex)
                }
                DataStorage.shared.updateConversation(conversation, persistImmediately: true)
                errorMessage = error.localizedDescription
                break
            }
        }

        isGenerating = false
        thinkingStartTime = nil
        statusText = ""
    }
}
