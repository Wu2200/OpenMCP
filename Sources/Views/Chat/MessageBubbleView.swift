import SwiftUI

struct MessageBubbleView: View {
    let message: ChatMessage

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            if message.role == .user {
                Spacer(minLength: 40)
            } else {
                Image(systemName: "sparkles")
                    .font(.system(size: 14))
                    .foregroundColor(.white)
                    .frame(width: 28, height: 28)
                    .background(LinearGradient(colors: [Color.blue, Color.purple], startPoint: .topLeading, endPoint: .bottomTrailing))
                    .clipShape(Circle())
            }

            VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 8) {
                if !message.content.isEmpty {
                    Text(message.content)
                        .font(.body)
                        .foregroundColor(message.role == .user ? .white : .primary)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(message.role == .user ? Color(red: 0.15, green: 0.45, blue: 0.95) : Color(.systemGray6))
                        .cornerRadius(16)
                }

                if let toolCalls = message.toolCalls, !toolCalls.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(toolCalls) { call in
                            ToolCallCardView(toolCall: call)
                        }
                    }
                }
            }

            if message.role == .user {
                Image(systemName: "person.fill")
                    .font(.system(size: 14))
                    .foregroundColor(.white)
                    .frame(width: 28, height: 28)
                    .background(Color.gray)
                    .clipShape(Circle())
            } else {
                Spacer(minLength: 40)
            }
        }
        .padding(.horizontal, 14)
    }
}
