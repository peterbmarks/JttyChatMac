import Foundation

/// One chat message, rendered as a speech bubble. Ported from
/// JttyChatLinux/src/ChatBubble.h (there, the "model" was just the two
/// constructor arguments to ChatBubble; this gives it an explicit type for
/// SwiftUI's ForEach/Identifiable).
struct ChatMessage: Identifiable, Equatable {
    let id = UUID()
    let text: String
    let isSent: Bool
}
