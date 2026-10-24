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
                    LazyVStack(spacing: 14) {
                        ForEach(currentConversation.messages) { msg in
                            if msg.role != .tool {
                                MessageBubbleView(message: msg)
                                    .id(msg.id)
                            }
                        }

                        if coordinator.isGenerating {
                            HStack(spacing: 8) {
                                ProgressView()
                                    .scaleEffect(0.8)
                                Text(coordinator.statusText.isEmpty ? "思考中..." : coordinator.statusText)
                                    .font(.footnote)
                                    .foregroundColor(.secondary)
                                Spacer()
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .background(Color(.systemGray6))
                            .cornerRadius(10)
                            .padding(.horizontal)
                            .id("generating_indicator")
                        }

                        if let err = coordinator.errorMessage {
                            HStack {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundColor(.red)
                                Text(err)
                                    .font(.footnote)
                                    .foregroundColor(.red)
                                Spacer()
                            }
                            .padding(10)
                            .background(Color.red.opacity(0.1))
                            .cornerRadius(8)
                            .padding(.horizontal)
                            .id("error_indicator")
                        }
                    }
                    .padding(.vertical, 14)
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

            Divider()

            HStack(alignment: .bottom, spacing: 10) {
                TextField("输入消息...", text: $inputText, axis: .vertical)
                    .lineLimit(1...5)
                    .padding(10)
                    .background(Color(.systemGray6))
                    .cornerRadius(18)

                if coordinator.isGenerating {
                    Button(action: {
                        coordinator.cancel()
                    }) {
                        Image(systemName: "stop.circle.fill")
                            .font(.system(size: 32))
                            .foregroundColor(.red)
                    }
                } else {
                    Button(action: {
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
                    }) {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 32))
                            .foregroundColor(inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .secondary : Color(red: 0.15, green: 0.45, blue: 0.95))
                    }
                    .disabled(inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Color(.systemBackground))
        }
        .navigationTitle(currentConversation.title)
        .navigationBarTitleDisplayMode(.inline)
    }
}
