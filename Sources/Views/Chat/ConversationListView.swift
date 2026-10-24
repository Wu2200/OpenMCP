import SwiftUI

struct ConversationListView: View {
    @EnvironmentObject var storage: DataStorage
    @State private var selectedConversation: Conversation? = nil

    var body: some View {
        NavigationStack {
            List {
                if storage.conversations.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "bubble.left.and.exclamationmark")
                            .font(.system(size: 40))
                            .foregroundColor(.secondary)
                        Text("暂无对话历史")
                            .font(.headline)
                            .foregroundColor(.secondary)
                        Text("点击右上角加号创建新对话")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 40)
                    .listRowBackground(Color.clear)
                } else {
                    ForEach(storage.conversations) { conv in
                        NavigationLink(value: conv) {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(conv.title)
                                    .font(.headline)
                                    .lineLimit(1)
                                HStack {
                                    Text("\(conv.messages.count) 条消息")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                    Spacer()
                                    Text(conv.updatedAt, style: .time)
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    }
                    .onDelete(perform: storage.deleteConversation)
                }
            }
            .navigationTitle("AI 对话")
            .navigationDestination(for: Conversation.self) { conv in
                ChatDetailView(conversationId: conv.id)
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: {
                        let newConv = storage.addConversation()
                        selectedConversation = newConv
                    }) {
                        Image(systemName: "plus.circle.fill")
                            .font(.system(size: 20))
                    }
                }
            }
        }
    }
}
