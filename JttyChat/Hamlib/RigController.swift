import Foundation

/// One Hamlib rig backend: a model id (as used by rig_init()) paired with a
/// human-readable "Manufacturer Model" label.
nonisolated struct RigInfo: Identifiable, Hashable {
    let model: Int
    let label: String
    var id: Int { model }
}

/// One of the serial line settings offered in the Settings window's
/// Transceiver section, each mapped onto the Hamlib configuration setting
/// it controls. "Default" (RigSerialConfig.defaultValue) leaves the
/// setting at whatever the rig backend uses.
nonisolated enum RigSerialSetting: String, CaseIterable, Identifiable {
    case baudRate, dataBits, stopBits, parity, handshake, dtrState, rtsState

    var id: String { rawValue }

    /// The Hamlib configuration setting name, as used by rig_set_conf().
    var hamlibName: String {
        switch self {
        case .baudRate: "serial_speed"
        case .dataBits: "data_bits"
        case .stopBits: "stop_bits"
        case .parity: "serial_parity"
        case .handshake: "serial_handshake"
        case .dtrState: "dtr_state"
        case .rtsState: "rts_state"
        }
    }

    var label: String {
        switch self {
        case .baudRate: "Rig Baud Rate:"
        case .dataBits: "Data Bits:"
        case .stopBits: "Stop Bits:"
        case .parity: "Parity:"
        case .handshake: "Handshake:"
        case .dtrState: "DTR:"
        case .rtsState: "RTS:"
        }
    }

    /// The values the user can pick besides "Default", spelled as Hamlib
    /// expects them.
    var options: [String] {
        switch self {
        case .baudRate: ["1200", "2400", "4800", "9600", "19200", "38400", "57600", "115200"]
        case .dataBits: ["5", "6", "7", "8"]
        case .stopBits: ["1", "2"]
        case .parity: ["None", "Odd", "Even", "Mark", "Space"]
        case .handshake: ["None", "XONXOFF", "Hardware"]
        case .dtrState, .rtsState: ["ON", "OFF"]
        }
    }

    /// How a Hamlib value is shown in the menus.
    func displayName(for value: String) -> String {
        switch value {
        case "XONXOFF": "XON/XOFF"
        case "ON": "On"
        case "OFF": "Off"
        default: value
        }
    }
}

/// The serial line settings applied whenever the rig is opened.
nonisolated struct RigSerialConfig: Equatable {
    static let defaultValue = "Default"

    private var values: [RigSerialSetting: String] = [:]

    subscript(setting: RigSerialSetting) -> String {
        get { values[setting] ?? Self.defaultValue }
        set { values[setting] = newValue.isEmpty ? Self.defaultValue : newValue }
    }

    /// The non-default settings as HamlibBridge's "name=value" lines.
    var hamlibConfig: String {
        RigSerialSetting.allCases
            .filter { self[$0] != Self.defaultValue }
            .map { "\($0.hamlibName)=\(self[$0])" }
            .joined(separator: "\n")
    }
}

nonisolated struct RigConnectionResult {
    var success = false
    var message = "" // "<freq> MHz  <mode>" on success, an error description otherwise
}

/// Swift-facing wrapper around HamlibBridge.{h,c}. Ported from
/// JttyChatLinux/src/HamlibRigs.{h,cpp}; all the Hamlib struct/type
/// plumbing lives in the C shim, so this just marshals strings and runs
/// the blocking calls off the main thread. Nonisolated, since every call
/// that talks to the rig blocks and is meant to run off the main actor.
nonisolated enum RigController {
    private static let messageBufferSize = 256

    // Full version string of the loaded Hamlib library (the newest of the
    // embedded and any externally installed copies).
    static var hamlibVersion: String {
        jttyrig_hamlib_version().map { String(cString: $0) } ?? "Not found"
    }

    // Path of the Hamlib dynamic library that was actually loaded.
    static var hamlibLibraryPath: String {
        jttyrig_hamlib_path().map { String(cString: $0) } ?? "Not found"
    }

    // All transceiver models Hamlib knows how to talk to, sorted by label.
    // Loads and queries Hamlib's backend registry on first call; slow the
    // first time, so call this off the main thread.
    static func availableRigs() -> [RigInfo] {
        var count: Int32 = 0
        guard let list = jttyrig_list_models(&count) else { return [] }
        defer { jttyrig_free_list(list, count) }

        var rigs: [RigInfo] = []
        rigs.reserveCapacity(Int(count))
        for i in 0..<Int(count) {
            let entry = list[i]
            let label = entry.label.map { String(cString: $0) } ?? ""
            rigs.append(RigInfo(model: Int(entry.model), label: label))
        }
        return rigs
    }

    // Opens the given rig model on the given port, reads its current
    // frequency and mode, then closes it again. Blocks for as long as
    // Hamlib takes to open the port and respond (or time out) - call this
    // off the main thread.
    static func connectAndQuery(model: Int, port: String, serial: RigSerialConfig) -> RigConnectionResult {
        var buffer = [CChar](repeating: 0, count: messageBufferSize)
        let success = jttyrig_connect_and_query(Int32(model), port, serial.hamlibConfig, &buffer,
                                                Int32(messageBufferSize))
        return RigConnectionResult(success: success, message: String(cString: buffer))
    }

    // Opens the rig just long enough to key or unkey PTT, then closes it
    // again. Call this off the main thread. Returns an error message, or
    // nil on success.
    static func setPTT(model: Int, port: String, serial: RigSerialConfig, on: Bool) -> String? {
        var buffer = [CChar](repeating: 0, count: messageBufferSize)
        let success = jttyrig_set_ptt(Int32(model), port, serial.hamlibConfig, on, &buffer, Int32(messageBufferSize))
        return success ? nil : String(cString: buffer)
    }

    // Opens the rig just long enough to set its current VFO frequency (in
    // Hz), then closes it again. Call this off the main thread. Returns an
    // error message, or nil on success.
    static func setFrequency(model: Int, port: String, serial: RigSerialConfig, freqHz: Double) -> String? {
        var buffer = [CChar](repeating: 0, count: messageBufferSize)
        let success = jttyrig_set_frequency(Int32(model), port, serial.hamlibConfig, freqHz, &buffer,
                                            Int32(messageBufferSize))
        return success ? nil : String(cString: buffer)
    }

    // The rig backend's own default for each serial setting (e.g. 8 data
    // bits, Hardware handshake), for showing next to "Default" in the
    // menus. Settings the model doesn't define (network rigs, the dummy
    // rig) are left out. Loads Hamlib on first use; call off the main
    // thread.
    static func serialDefaults(model: Int) -> [RigSerialSetting: String] {
        let settings = RigSerialSetting.allCases
        let names = settings.map(\.hamlibName).joined(separator: "\n")
        var buffer = [CChar](repeating: 0, count: 1024)
        guard jttyrig_get_default_conf(Int32(model), names, &buffer, Int32(buffer.count)) else { return [:] }

        let values = String(cString: buffer).components(separatedBy: "\n")
        var defaults: [RigSerialSetting: String] = [:]
        for (setting, value) in zip(settings, values) where !value.isEmpty {
            defaults[setting] = value
        }
        return defaults
    }
}
