import SwiftUI

/// App scenes: the main chat window plus a File > Settings... window and a
/// Frequency menu for quick-tuning the rig. Ported from
/// JttyChatLinux/src/main.cpp + MainWindow.cpp's createMenuBar().
@main
struct MyApp: App {
    @StateObject private var settings = AppSettings.shared
    @StateObject private var viewModel: ChatViewModel
    @Environment(\.openWindow) private var openWindow

    init() {
        _viewModel = StateObject(wrappedValue: ChatViewModel(settings: AppSettings.shared))
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(viewModel)
                .environmentObject(settings)
        }
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(after: .newItem) {
                Divider()
                Button("Settings...") { openWindow(id: "settings") }
                    .keyboardShortcut(",", modifiers: .command)
            }
            CommandMenu("Frequency") {
                ForEach(ChatViewModel.bandFrequenciesMHz, id: \.self) { freqMHz in
                    Button(String(format: "%.3f MHz", freqMHz)) { viewModel.tuneRig(toMHz: freqMHz) }
                }
            }
        }

        Window("Settings", id: "settings") {
            SettingsView()
                .environmentObject(settings)
                .environmentObject(viewModel)
        }
        .windowResizability(.contentSize)
    }
}
