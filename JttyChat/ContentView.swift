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

    var body: some View {
        VStack(spacing: 0) {
            SpectrumView(bitmap: viewModel.waterfall, lowHz: Self.spectrumLowHz, highHz: Self.spectrumHighHz)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(viewModel.messages) { message in
                            ChatBubbleView(message: message)
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .padding(.vertical, 8)
                    .padding(.horizontal, 4)
                }
                .background(Color.white)
                .onChange(of: viewModel.messages.count) { _, _ in
                    withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
                }
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
