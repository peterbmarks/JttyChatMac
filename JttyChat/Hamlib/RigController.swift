import Foundation

/// One Hamlib rig backend: a model id (as used by rig_init()) paired with a
/// human-readable "Manufacturer Model" label.
struct RigInfo: Identifiable, Hashable {
    let model: Int
    let label: String
    var id: Int { model }
}

struct RigConnectionResult {
    var success = false
    var message = "" // "<freq> MHz  <mode>" on success, an error description otherwise
}

/// Swift-facing wrapper around HamlibBridge.{h,c}. Ported from
/// JttyChatLinux/src/HamlibRigs.{h,cpp}; all the Hamlib struct/type
/// plumbing lives in the C shim, so this just marshals strings and runs
/// the blocking calls off the main thread.
enum RigController {
    private static let messageBufferSize = 256

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
    static func connectAndQuery(model: Int, port: String, baudRate: String) -> RigConnectionResult {
        var buffer = [CChar](repeating: 0, count: messageBufferSize)
        let success = jttyrig_connect_and_query(Int32(model), port, baudRate, &buffer, Int32(messageBufferSize))
        return RigConnectionResult(success: success, message: String(cString: buffer))
    }

    // Opens the rig just long enough to key or unkey PTT, then closes it
    // again. Call this off the main thread. Returns an error message, or
    // nil on success.
    static func setPTT(model: Int, port: String, baudRate: String, on: Bool) -> String? {
        var buffer = [CChar](repeating: 0, count: messageBufferSize)
        let success = jttyrig_set_ptt(Int32(model), port, baudRate, on, &buffer, Int32(messageBufferSize))
        return success ? nil : String(cString: buffer)
    }

    // Opens the rig just long enough to set its current VFO frequency (in
    // Hz), then closes it again. Call this off the main thread. Returns an
    // error message, or nil on success.
    static func setFrequency(model: Int, port: String, baudRate: String, freqHz: Double) -> String? {
        var buffer = [CChar](repeating: 0, count: messageBufferSize)
        let success = jttyrig_set_frequency(Int32(model), port, baudRate, freqHz, &buffer, Int32(messageBufferSize))
        return success ? nil : String(cString: buffer)
    }
}
