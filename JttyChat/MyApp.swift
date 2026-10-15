import SwiftUI

/// App scenes: the main chat window plus a Settings... window (in the
/// standard app-menu location), a Hamlib Log window (in the Window menu),
/// and a Frequency menu for quick-tuning the rig. Ported from JttyChatLinux/src/main.cpp + MainWindow.cpp's
/// createMenuBar().
@main
struct MyApp: App {
    @StateObject private var settings = AppSettings.shared
    @StateObject private var viewModel: ChatViewModel
    @StateObject private var hamlibLog = HamlibLog.shared
    @Environment(\.openWindow) private var openWindow

    /// Held for the app's lifetime to keep the Mac from idle-sleeping (and
    /// the app from being App Napped) while it's listening and decoding.
    /// The system releases the assertion automatically when the app quits.
    private let sleepActivity: NSObjectProtocol = ProcessInfo.processInfo.beginActivity(
        options: [.userInitiated, .idleSystemSleepDisabled],
        reason: "JttyChat is monitoring the radio and must stay awake"
    )

    init() {
        // Before anything touches Hamlib, so the whole session is logged.
        HamlibLog.shared.start()
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
                Button("Export...") { viewModel.exportMessages() }
                    .keyboardShortcut("e", modifiers: [.command, .shift])
                    .disabled(viewModel.messages.isEmpty)
            }
            CommandGroup(replacing: .appSettings) {
                Button("Settings...") { openWindow(id: "settings") }
                    .keyboardShortcut(",", modifiers: .command)
            }
            CommandGroup(before: .windowList) {
                Button("Hamlib Log") { openWindow(id: "hamlib-log") }
                    .keyboardShortcut("l", modifiers: [.command, .option])
                Divider()
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

        Window("Hamlib Log", id: "hamlib-log") {
            HamlibLogView()
                .environmentObject(hamlibLog)
        }
        .defaultSize(width: 900, height: 500)
    }
}
