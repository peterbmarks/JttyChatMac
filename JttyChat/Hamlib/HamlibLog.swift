import Combine
import Foundation
import SwiftUI

/// Hamlib's debug levels (rig_debug_level_e), as used by the Hamlib Log
/// window's level picker and to tag each log entry.
enum HamlibLogLevel: Int, CaseIterable, Identifiable {
    case none = 0, bug, error, warning, verbose, trace, cache

    var id: Int { rawValue }

    var name: String {
        switch self {
        case .none: "None"
        case .bug: "Bug"
        case .error: "Error"
        case .warning: "Warning"
        case .verbose: "Verbose"
        case .trace: "Trace"
        case .cache: "Cache"
        }
    }

    var color: Color {
        switch self {
        case .bug, .error: .red
        case .warning: .orange
        case .none, .verbose: .primary
        case .trace, .cache: .secondary
        }
    }
}

struct HamlibLogEntry: Identifiable {
    let id: Int
    let date: Date
    let level: HamlibLogLevel
    let fromApp: Bool // JttyChat's own note, rather than a Hamlib message
    let text: String
}

/// Collects Hamlib's debug output (and JttyChat's notes about each rig
/// operation) from HamlibBridge.c for the Hamlib Log window. Logging runs
/// from startup whether or not the window is open, so the history leading
/// up to a problem is there when the window is opened afterwards.
final class HamlibLog: ObservableObject {
    static let shared = HamlibLog()

    // Oldest entries are dropped beyond this, keeping memory bounded at
    // Trace level, which logs dozens of lines per rig command.
    private static let maxEntries = 5000
    private static let levelKey = "hamlibLogLevel"

    @Published private(set) var entries: [HamlibLogEntry] = []
    @Published var level: HamlibLogLevel {
        didSet {
            UserDefaults.standard.set(level.rawValue, forKey: Self.levelKey)
            let level = level
            Task.detached { Self.applyLevel(level) }
        }
    }

    private var nextID = 0

    private init() {
        let stored = UserDefaults.standard.object(forKey: Self.levelKey) as? Int
        level = stored.flatMap(HamlibLogLevel.init(rawValue:)) ?? .trace
    }

    /// Routes HamlibBridge's log output here. Call once at startup, before
    /// anything else touches Hamlib, so the library search is captured too.
    func start() {
        jttyrig_set_log_handler { rawLevel, message, fromApp in
            // Runs on whichever thread is talking to Hamlib; copy the
            // message now, since it's only valid during this call.
            guard let message else { return }
            let text = String(cString: message).trimmingCharacters(in: .newlines)
            guard !text.isEmpty else { return }
            let level = HamlibLogLevel(rawValue: Int(rawLevel)) ?? .verbose
            let date = Date()
            Task { @MainActor in
                HamlibLog.shared.append(date: date, level: level, fromApp: fromApp, text: text)
            }
        }
        // Loading Hamlib can be slow; don't hold up launch.
        let level = level
        Task.detached { Self.applyLevel(level) }
    }

    func clear() {
        entries.removeAll()
    }

    /// The whole log as plain text, for copying or saving.
    var plainText: String {
        entries.map { Self.format($0) }.joined(separator: "\n")
    }

    static func format(_ entry: HamlibLogEntry) -> String {
        let time = entry.date.formatted(.dateTime.hour().minute().second().secondFraction(.fractional(3)))
        let source = entry.fromApp ? "JttyChat" : "Hamlib"
        return "\(time) [\(entry.level.name)] \(source): \(entry.text)"
    }

    private func append(date: Date, level: HamlibLogLevel, fromApp: Bool, text: String) {
        entries.append(HamlibLogEntry(id: nextID, date: date, level: level, fromApp: fromApp, text: text))
        nextID += 1
        if entries.count > Self.maxEntries {
            entries.removeFirst(entries.count - Self.maxEntries)
        }
    }

    // Loads Hamlib on first use, which can block; call off the main thread.
    nonisolated private static func applyLevel(_ level: HamlibLogLevel) {
        jttyrig_set_debug_level(Int32(level.rawValue))
    }
}
