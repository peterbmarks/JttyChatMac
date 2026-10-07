import SwiftUI

/// A single chat message rendered as a rounded speech bubble, aligned to
/// the right (blue) for sent messages and to the left (grey) for received
/// ones. Ported from JttyChatLinux/src/ChatBubble.{h,cpp}.
struct ChatBubbleView: View {
    let message: ChatMessage

    // Keeps bubbles from growing wider than a sensible fraction of the
    // scroll area as the window is resized - the caller (ContentView)
    // computes this from the current viewport width. Defaults to a
    // reasonable fallback (e.g. for previews) if not overridden.
    var maxBubbleWidth: CGFloat = 320

    private static let sentBackground = Color(red: 0x0b / 255.0, green: 0x93 / 255.0, blue: 0xf6 / 255.0)
    private static let receivedBackground = Color(red: 0xe5 / 255.0, green: 0xe5 / 255.0, blue: 0xea / 255.0)

    var body: some View {
        HStack(spacing: 0) {
            if message.isSent { Spacer(minLength: 40) }

            // Grouping the bubble and its timestamp in one VStack (instead
            // of putting the timestamp directly in the outer HStack) means
            // the timestamp aligns under whichever edge of the bubble is
            // against the side of the window, rather than always under one
            // fixed edge regardless of bubble width.
            VStack(alignment: message.isSent ? .trailing : .leading, spacing: 2) {
                Text(message.text)
                    .font(.system(size: 14))
                    .foregroundColor(message.isSent ? .white : .black)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: maxBubbleWidth, alignment: .leading)
                    // Pins this view to its own ideal size on both axes
                    // (capped by the frame above), rather than accepting
                    // whatever width the enclosing HStack happens to
                    // propose. Without this, the Text competes with the
                    // Spacer for the HStack's slack space instead of
                    // leaving all of it to the Spacer, which is what was
                    // stretching sent bubbles out to maxBubbleWidth
                    // regardless of how short the message actually was.
                    .fixedSize()
                    .padding(.vertical, 8)
                    .padding(.horizontal, 12)
                    .background(message.isSent ? Self.sentBackground : Self.receivedBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .textSelection(.enabled)

                Text(Self.timestampText(for: message.date))
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 4)
            }
            // Same reasoning as the Text's own fixedSize() above, one level
            // up: keeps this whole bubble+timestamp group hugging its own
            // content width instead of being stretched by the HStack.
            .fixedSize()

            if !message.isSent { Spacer(minLength: 40) }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 2)
        .frame(maxWidth: .infinity, alignment: message.isSent ? .trailing : .leading)
    }

    // "4:32 PM" for messages from today, "Oct 7, 4:32 PM" otherwise.
    private static func timestampText(for date: Date) -> String {
        if Calendar.current.isDateInToday(date) {
            return date.formatted(date: .omitted, time: .shortened)
        } else {
            return date.formatted(date: .abbreviated, time: .shortened)
        }
    }
}
