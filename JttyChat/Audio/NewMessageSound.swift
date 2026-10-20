import AVFoundation
import os

/// Plays the new-message alert through the computer's own audio output -
/// never through the transceiver's audio interface, where it would end up
/// on the air if the rig is on VOX.
final class NewMessageSound {
    private static let soundURL = URL(fileURLWithPath: "/System/Library/Sounds/Glass.aiff")
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "JttyChat", category: "Audio")

    // Held for as long as the sound plays; a player that's only a local
    // is deallocated, and falls silent, as soon as play() returns.
    private var player: AVAudioPlayer?

    /// Plays the sound on the system default output device, unless that's
    /// the device transmit audio goes to, in which case it uses the Mac's
    /// built-in output instead (or stays silent if there isn't one).
    ///
    /// Returns a short description of what happened - which device it
    /// played on, or why it didn't - for the Test button in Settings.
    @discardableResult
    func play(avoidingDeviceUID transmitDeviceUID: String?) -> String {
        var device = AudioDeviceLister.defaultOutputDevice()
        if let current = device, current.uid == transmitDeviceUID {
            device = AudioDeviceLister.builtInOutputDevice()
            if device?.uid == transmitDeviceUID {
                device = nil
            }
        }
        guard let device else {
            let outcome = "Not played: no output device other than the transmit device."
            Self.logger.notice("New message sound: \(outcome, privacy: .public)")
            return outcome
        }

        let outcome: String
        do {
            let player = try AVAudioPlayer(contentsOf: Self.soundURL)
            player.currentDevice = device.uid
            if player.play() {
                self.player = player
                outcome = "Played on \(device.name)."
            } else {
                outcome = "Couldn't play on \(device.name)."
            }
        } catch {
            outcome = "Couldn't load the sound: \(error.localizedDescription)"
        }
        Self.logger.notice("New message sound: \(outcome, privacy: .public)")
        return outcome
    }
}
