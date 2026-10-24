import SwiftUI

struct ChatDetailView: View {
    @EnvironmentObject var storage: DataStorage
    let conversationId: String
    @StateObject private var coordinator = AgentCoordinator()
    @State private var inputText: String = ""

    private var currentConversation: Conversation {
        storage.conversations.first(where: { $0.id == conversationId }) ?? Conversation(title: "对话", messages: [])
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 16) {
                        if currentConversation.messages.isEmpty {
                            VStack(spacing: 12) {
                                Image(systemName: "bubble.left.and.text.bubble.right")
                                    .font(.system(size: 36))
                                    .foregroundColor(.secondary)
                                Text("与 \(storage.settings.modelName) 开始对话")
                                    .font(.subheadline)
                                    .foregroundColor(.secondary)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.top, 40)
                        } else {
                            ForEach(currentConversation.messages) { msg in
                                if msg.role != .tool {
                                    MessageBubbleView(message: msg)
                                        .id(msg.id)
                                }
                            }
                        }

                        if coordinator.isGenerating {
                            HStack(spacing: 10) {
                                ProgressView()
                                    .scaleEffect(0.8)
                                Text(coordinator.statusText.isEmpty ? "思考中..." : coordinator.statusText)
                                    .font(.footnote)
                                    .foregroundColor(.secondary)
                                Spacer()
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                            .background(Color(.secondarySystemBackground))
                            .cornerRadius(12)
                            .padding(.horizontal, 16)
                            .id("generating_indicator")
                        }

                        if let err = coordinator.errorMessage {
                            HStack(spacing: 8) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundColor(.red)
                                Text(err)
                                    .font(.footnote)
                                    .foregroundColor(.red)
                                Spacer()
                            }
                            .padding(12)
                            .background(Color.red.opacity(0.08))
                            .cornerRadius(10)
                            .padding(.horizontal, 16)
                            .id("error_indicator")
                        }
                    }
                    .padding(.vertical, 16)
                }
                .onChange(of: currentConversation.messages.count) { _ in
                    if let last = currentConversation.messages.last {
                        withAnimation {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }
                .onChange(of: coordinator.statusText) { _ in
                    withAnimation {
                        proxy.scrollTo("generating_indicator", anchor: .bottom)
                    }
                }
            }

            VStack(spacing: 0) {
                Divider()

                HStack(alignment: .bottom, spacing: 10) {
                    TextField("向 \(storage.settings.modelName) 发送消息...", text: $inputText, axis: .vertical)
                        .lineLimit(1...5)
                        .font(.system(size: 15))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(Color(.secondarySystemBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))

                    if coordinator.isGenerating {
                        Button(action: {
                            coordinator.cancel()
                        }) {
                            Image(systemName: "stop.circle.fill")
                                .font(.system(size: 32))
                                .foregroundColor(.red)
                        }
                    } else {
                        Button(action: sendMessage) {
                            Image(systemName: "arrow.up.circle.fill")
                                .font(.system(size: 32))
                                .foregroundColor(inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? Color(.systemGray4) : Color.blue)
                        }
                        .disabled(inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Color(.systemBackground))
            }
        }
        .navigationTitle(currentConversation.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                HStack(spacing: 4) {
                    Image(systemName: "cpu")
                        .font(.caption2)
                    Text(storage.settings.modelName)
                        .font(.caption.weight(.medium))
                }
                .foregroundColor(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color(.systemGray6))
                .cornerRadius(12)
            }
        }
    }

    private func sendMessage() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        inputText = ""
        if currentConversation.messages.isEmpty {
            var updated = currentConversation
            updated.title = String(text.prefix(18))
            storage.updateConversation(updated)
        }
        Task {
            await coordinator.sendMessage(
                conversationId: conversationId,
                userPrompt: text,
                settings: storage.settings,
                servers: storage.servers
            )
        }
    }
}
