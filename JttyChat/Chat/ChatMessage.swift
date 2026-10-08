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

    /// How far a received message got. Sent messages are always
    /// `.complete` - there's nothing to wait for.
    enum DecodeState {
        /// Still arriving; more text is expected.
        case inProgress
        /// The decoder reported the message as finished.
        case complete
        /// Stopped arriving without ever finishing - a signal that faded
        /// out mid-message - but enough text had resolved to be worth
        /// keeping. Shown as a normal bubble, marked so it isn't mistaken
        /// for the whole message.
        case incomplete
    }

    var decodeState: DecodeState = .complete
    /// When the bubble first appeared - i.e. when the message *started*
    /// arriving, not when it finished - so a live bubble's timestamp
    /// doesn't jump around while it fills in.
    let date: Date = Date()
}
