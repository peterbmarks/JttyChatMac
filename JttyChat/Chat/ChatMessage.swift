import Foundation

/// One chat message, rendered as a speech bubble. Ported from
/// JttyChatLinux/src/ChatBubble.h (there, the "model" was just the two
/// constructor arguments to ChatBubble; this gives it an explicit type for
/// SwiftUI's ForEach/Identifiable).
struct ChatMessage: Identifiable, Equatable {
    let id = UUID()
    /// Mutable because a received message is shown as it decodes: the
    /// decoder extends and sometimes revises the text frame by frame, and
    /// each update rewrites this in place so the same bubble grows rather
    /// than a new one appearing per update (see ChatViewModel).
    var text: String
    let isSent: Bool
    /// False while a received message is still arriving, so the bubble can
    /// show that there's more to come. Sent messages are complete the
    /// moment they're created.
    var isComplete: Bool = true
    /// When the bubble first appeared - i.e. when the message *started*
    /// arriving, not when it finished - so a live bubble's timestamp
    /// doesn't jump around while it fills in.
    let date: Date = Date()
}
