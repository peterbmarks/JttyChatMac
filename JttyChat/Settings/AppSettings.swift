import Combine
import CoreAudio
import Foundation

/// UserDefaults keys, grouped to mirror JttyChatLinux/src/AppSettingsKeys.h
/// (there, a QSettings "Transceiver" group).
private enum SettingsKey {
    static let callsign = "callsign"
    static let audioInputDeviceUID = "Transceiver.audioInputDeviceUID"
    static let audioOutputDeviceUID = "Transceiver.audioOutputDeviceUID"
    static let rigModel = "Transceiver.rigModel"
    static let rigPort = "Transceiver.rigPort"
    static let rigBaudRate = "Transceiver.rigBaudRate"
    static let capitalizeMessages = "capitalizeMessages"
    static let appendCallsign = "appendCallsign"
    static let macros = "macros"
}

/// A canned message the user can drop into the input field with one click.
struct Macro: Codable, Equatable {
    var title: String
    var message: String
}

/// The transceiver configuration needed to transmit: rig model/port/baud
/// for PTT and frequency control. Ported from MainWindow.cpp's
/// loadRigTxSettings() free function - reloaded fresh from disk at
/// transmit/tune time rather than cached, so Settings changes apply
/// immediately without restarting anything rig-related.
struct RigTxSettings {
    let model: Int
    let port: String
    let baudRate: String
}

/// Persisted application settings (callsign + transceiver config). Ported
/// from JttyChatLinux's QSettings-backed SettingsDialog/AppSettingsKeys.
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    static let defaultBaudRate = "Default"
    static let baudRates = [defaultBaudRate, "1200", "2400", "4800", "9600", "19200", "38400", "57600", "115200"]

    @Published var callsign: String
    @Published var audioInputDeviceUID: String?
    @Published var audioOutputDeviceUID: String?
    @Published var rigModel: Int?
    @Published var rigPort: String
    @Published var rigBaudRate: String
    @Published var capitalizeMessages: Bool
    @Published var appendCallsign: Bool

    static let macroCount = 8

    // The macro buttons above the input field. Edited one at a time from
    // the chat window and saved straight away (see saveMacros), rather
    // than going through the Settings window's save().
    @Published var macros: [Macro]

    private let defaults = UserDefaults.standard

    private init() {
        callsign = defaults.string(forKey: SettingsKey.callsign) ?? ""
        audioInputDeviceUID = defaults.string(forKey: SettingsKey.audioInputDeviceUID)
        audioOutputDeviceUID = defaults.string(forKey: SettingsKey.audioOutputDeviceUID)
        rigModel = defaults.object(forKey: SettingsKey.rigModel) as? Int
        rigPort = defaults.string(forKey: SettingsKey.rigPort) ?? ""
        rigBaudRate = defaults.string(forKey: SettingsKey.rigBaudRate) ?? Self.defaultBaudRate
        capitalizeMessages = defaults.bool(forKey: SettingsKey.capitalizeMessages)
        appendCallsign = defaults.bool(forKey: SettingsKey.appendCallsign)
        macros = Self.loadMacros(from: defaults)
    }

    // Always returns exactly macroCount macros, filling any missing slots
    // with the defaults M1...M8 and an empty message.
    private static func loadMacros(from defaults: UserDefaults) -> [Macro] {
        var saved: [Macro] = []
        if let data = defaults.data(forKey: SettingsKey.macros),
           let decoded = try? JSONDecoder().decode([Macro].self, from: data) {
            saved = decoded
        }
        return (0..<macroCount).map { index in
            index < saved.count ? saved[index] : Macro(title: "M\(index + 1)", message: "")
        }
    }

    func saveMacros() {
        if let data = try? JSONEncoder().encode(macros) {
            defaults.set(data, forKey: SettingsKey.macros)
        }
    }

    func save() {
        defaults.set(callsign.trimmingCharacters(in: .whitespaces), forKey: SettingsKey.callsign)
        defaults.set(audioInputDeviceUID, forKey: SettingsKey.audioInputDeviceUID)
        defaults.set(audioOutputDeviceUID, forKey: SettingsKey.audioOutputDeviceUID)
        if let rigModel {
            defaults.set(rigModel, forKey: SettingsKey.rigModel)
        } else {
            defaults.removeObject(forKey: SettingsKey.rigModel)
        }
        defaults.set(rigPort.trimmingCharacters(in: .whitespaces), forKey: SettingsKey.rigPort)
        defaults.set(rigBaudRate, forKey: SettingsKey.rigBaudRate)
        defaults.set(capitalizeMessages, forKey: SettingsKey.capitalizeMessages)
        defaults.set(appendCallsign, forKey: SettingsKey.appendCallsign)
    }

    // Resolves the saved input/output device UID to a live CoreAudio
    // device, falling back to the system default if there's no saved
    // device (or it's no longer present).
    func resolvedInputDevice() -> AudioDeviceInfo? {
        AudioDeviceLister.resolve(uid: audioInputDeviceUID, fallback: AudioDeviceLister.defaultInputDevice())
    }

    func resolvedOutputDevice() -> AudioDeviceInfo? {
        AudioDeviceLister.resolve(uid: audioOutputDeviceUID, fallback: AudioDeviceLister.defaultOutputDevice())
    }

    // Rereads the transceiver config directly from disk - mirrors
    // MainWindow.cpp's loadRigTxSettings(), always used right before
    // transmitting/tuning rather than relying on possibly-stale @Published
    // state.
    func loadRigTxSettings() -> RigTxSettings? {
        guard let model = defaults.object(forKey: SettingsKey.rigModel) as? Int else { return nil }
        let port = (defaults.string(forKey: SettingsKey.rigPort) ?? "").trimmingCharacters(in: .whitespaces)
        guard !port.isEmpty else { return nil }
        let baudRate = defaults.string(forKey: SettingsKey.rigBaudRate) ?? Self.defaultBaudRate
        return RigTxSettings(model: model, port: port, baudRate: baudRate)
    }
}
