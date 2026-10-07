import SwiftUI

/// A single chat message rendered as a rounded speech bubble, aligned to
/// the right (blue) for sent messages and to the left (grey) for received
/// ones. Ported from JttyChatLinux/src/ChatBubble.{h,cpp}.
struct ChatBubbleView: View {
    let message: ChatMessage

    private static let sentBackground = Color(red: 0x0b / 255.0, green: 0x93 / 255.0, blue: 0xf6 / 255.0)
    private static let receivedBackground = Color(red: 0xe5 / 255.0, green: 0xe5 / 255.0, blue: 0xea / 255.0)

    var body: some View {
        HStack(spacing: 0) {
            if message.isSent { Spacer(minLength: 40) }

            Text(message.text)
                .font(.system(size: 14))
                .foregroundColor(message.isSent ? .white : .black)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: 320, alignment: .leading)
                .padding(.vertical, 8)
                .padding(.horizontal, 12)
                .background(message.isSent ? Self.sentBackground : Self.receivedBackground)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .textSelection(.enabled)

            if !message.isSent { Spacer(minLength: 40) }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 2)
        .frame(maxWidth: .infinity, alignment: message.isSent ? .trailing : .leading)
    }
}
