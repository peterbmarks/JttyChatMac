import SwiftUI

/// Top-level chat window: a live spectrum strip above a scrolling column
/// of speech-bubble messages, above a text field + Send button, in the
/// style of a simple iMessage-like client. Ported from
/// JttyChatLinux/src/MainWindow.{h,cpp} (the Qt widget tree there becomes
/// plain SwiftUI layout here).
struct ContentView: View {
    @EnvironmentObject private var viewModel: ChatViewModel

    private static let spectrumLowHz = 1400
    private static let spectrumHighHz = 1700

    // Keeps bubbles from growing wider than a sensible fraction of the
    // viewport width, matching JttyChatLinux's MainWindow::updateBubbleWidths
    // (kMaxBubbleWidthFraction = 70%); recomputed as the window resizes.
    private static let maxBubbleWidthFraction: CGFloat = 0.7
    private static let minBubbleWidth: CGFloat = 100

    private static func maxBubbleWidth(forViewportWidth viewportWidth: CGFloat) -> CGFloat {
        max(minBubbleWidth, viewportWidth * maxBubbleWidthFraction)
    }

    var body: some View {
        VStack(spacing: 0) {
            SpectrumView(bitmap: viewModel.waterfall, lowHz: Self.spectrumLowHz, highHz: Self.spectrumHighHz)

            statusLine

            GeometryReader { geometry in
                let maxBubbleWidth = Self.maxBubbleWidth(forViewportWidth: geometry.size.width)
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 4) {
                            ForEach(viewModel.messages) { message in
                                ChatBubbleView(message: message, maxBubbleWidth: maxBubbleWidth)
                            }
                            Color.clear.frame(height: 1).id("bottom")
                        }
                        .padding(.vertical, 8)
                        .padding(.horizontal, 4)
                    }
                    .background(Color.white)
                    // Watches the messages themselves, not just how many
                    // there are: a received bubble grows in place as it
                    // decodes, and the view should stay pinned to the
                    // bottom while it does.
                    .onChange(of: viewModel.messages) { _, _ in
                        withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
                    }
                }
            }

            if viewModel.isAtMessageLengthLimit {
                lengthLimitWarning
            }

            inputBar
        }
        .frame(minWidth: 380, idealWidth: 420, minHeight: 480, idealHeight: 640)
        .alert("JTTY", isPresented: Binding(
            get: { viewModel.alertMessage != nil },
            set: { if !$0 { viewModel.alertMessage = nil } }
        )) {
            Button("OK") { viewModel.alertMessage = nil }
        } message: {
            Text(viewModel.alertMessage ?? "")
        }
    }

    // Signal quality of the last decoded frame: SNR, and how many symbols
    // arrived wrong (and were corrected by the FEC) over the message so far.
    private var statusLine: some View {
        HStack(spacing: 16) {
            if let quality = viewModel.receiveQuality {
                Text("SNR \(quality.snrDb) dB")
                Text("Errors \(quality.symbolErrors)/\(quality.symbolsChecked) symbols")
            } else {
                Text("No signal decoded")
            }
            Spacer()
        }
        .font(.system(size: 11).monospacedDigit())
        .foregroundStyle(.secondary)
        .padding(.vertical, 3)
        .padding(.horizontal, 8)
        .background(Color(white: 0.95))
        // The strip always has a light background, so keep its text dark in dark mode too.
        .environment(\.colorScheme, .light)
    }

    private var lengthLimitWarning: some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
            Text("Messages are limited to \(Jtty.maxMessageLength) characters")
            Spacer()
        }
        .font(.system(size: 11))
        // A dark orange, readable against the light grey strip in either appearance.
        .foregroundStyle(Color(red: 0.7, green: 0.35, blue: 0.0))
        .padding(.top, 6)
        .padding(.horizontal, 12)
        .background(Color(white: 0.95))
    }

    private var inputBar: some View {
        HStack(spacing: 8) {
            TextField("Text Message", text: $viewModel.inputText, prompt: Text("Text Message"))
                .textFieldStyle(.plain)
                .padding(.vertical, 8)
                .padding(.horizontal, 14)
                .background(Color.white)
                .clipShape(Capsule())
                .overlay(Capsule().stroke(Color(white: 0.78), lineWidth: 1))
                // The field always has a white background, so render it in light mode
                // to keep the text, placeholder and caret dark when the system is in dark mode.
                .environment(\.colorScheme, .light)
                .onSubmit { viewModel.sendMessage() }
                .onKeyPress(.upArrow) {
                    viewModel.recallLastSentMessage() ? .handled : .ignored
                }
                .disabled(viewModel.isSending)

            Button("Send") { viewModel.sendMessage() }
                .buttonStyle(.plain)
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.white)
                .padding(.vertical, 8)
                .padding(.horizontal, 18)
                .background(sendButtonBackground)
                .clipShape(Capsule())
                .disabled(viewModel.isSending || viewModel.inputText.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(8)
        .background(Color(white: 0.95))
    }

    private var sendButtonBackground: Color {
        let trimmedEmpty = viewModel.inputText.trimmingCharacters(in: .whitespaces).isEmpty
        return (viewModel.isSending || trimmedEmpty)
            ? Color(red: 0xa8 / 255.0, green: 0xd4 / 255.0, blue: 0xfb / 255.0)
            : Color(red: 0x0b / 255.0, green: 0x93 / 255.0, blue: 0xf6 / 255.0)
    }
}

#Preview {
    ContentView()
        .environmentObject(ChatViewModel(settings: AppSettings.shared))
}
