import Combine
import Foundation
import SwiftUI

/// Orchestrates sending/receiving JTTY messages, the live spectrum, and rig
/// PTT/frequency control. Ported from JttyChatLinux/src/MainWindow.{h,cpp},
/// swapping Qt's signals/threads/QTimer for Swift concurrency.
@MainActor
final class ChatViewModel: ObservableObject {
    // Band buttons for the Frequency menu, matching MainWindow.cpp's
    // kBandFrequenciesMHz.
    static let bandFrequenciesMHz: [Double] = [1.838, 3.575, 7.090, 10.140, 14.090, 18.100, 21.090, 24.920, 28.090]

    private static let spectrumLowHz = 1400
    private static let spectrumHighHz = 1700
    private static let spectrumFftSize = 8192 // ~1.5 Hz/bin at the 12 kHz Rx rate
    private static let pttLeadMs = 150 // brief key-up lead before audio starts, for real radios
    private static let txTailMs = 200 // margin after audio ends before unkeying/re-enabling Send

    @Published var messages: [ChatMessage] = []
    @Published var inputText = ""
    @Published var isSending = false
    @Published var alertMessage: String?

    let waterfall = WaterfallBitmap()

    private let settings: AppSettings
    private let decoder = JttyDecoder()
    private let spectrum = AudioSpectrum(fftSize: spectrumFftSize, sampleRate: Jtty.rxSampleRate)
    private let captureEngine = CaptureEngine()
    private let playbackEngine = PlaybackEngine()

    // Bubbles for messages still arriving, keyed by the decoder's message
    // id, so each update rewrites the bubble it belongs to instead of
    // appending a new one. Entries are dropped as messages complete.
    private var liveBubbleIDs: [Int64: ChatMessage.ID] = [:]

    init(settings: AppSettings) {
        self.settings = settings
        decoder.onMessageUpdated = { [weak self] update in
            // Hops off the audio thread via the main *queue* rather than a
            // Task: updates to one message supersede each other, and
            // unstructured Tasks aren't guaranteed to run in the order
            // they were created, which could leave a stale partial decode
            // overwriting the finished text.
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.apply(update) }
            }
        }
        startReceiver()
    }

    // Shows a message as it decodes. The decoder reports a growing (and
    // occasionally revised) text for each message id, so the matching
    // bubble is rewritten in place until the message completes.
    private func apply(_ update: JttyDecoder.Update) {
        defer {
            if update.isComplete { liveBubbleIDs.removeValue(forKey: update.messageId) }
        }

        let text = displayText(for: update.text)
        guard !text.isEmpty else { return }

        if let bubbleID = liveBubbleIDs[update.messageId],
           let index = messages.firstIndex(where: { $0.id == bubbleID }) {
            messages[index].text = text
            messages[index].isComplete = update.isComplete
        } else {
            let message = ChatMessage(text: text, isSent: false, isComplete: update.isComplete)
            messages.append(message)
            liveBubbleIDs[update.messageId] = message.id
        }
    }

    // JTTY is an uppercase-only mode, so every message - sent or received -
    // is all caps by the time it reaches a bubble. The "Capitalise
    // messages" setting re-cases it for readability without wrecking
    // callsigns and Q-codes (see MessageCase). Display only: what's
    // actually transmitted is the codec's own canonical text.
    private func displayText(for text: String) -> String {
        settings.capitalizeMessages ? MessageCase.sentenceCased(text) : text
    }

    // MARK: - Receive

    func startReceiver() {
        captureEngine.onSamples = { [weak self] samples in
            guard let self else { return }
            if let magnitudes = self.spectrum.addSamples(samples, lowHz: Self.spectrumLowHz, highHz: Self.spectrumHighHz) {
                Task { @MainActor in self.waterfall.setMagnitudesDb(magnitudes) }
            }
            self.decoder.addSamples(samples)
            self.decoder.poll()
        }
        try? captureEngine.start(deviceID: settings.resolvedInputDevice()?.id)
    }

    // Audio device choices may have changed in Settings; restart capture
    // against whatever is now configured.
    func restartReceiver() {
        captureEngine.stop()
        startReceiver()
    }

    // MARK: - Send

    func sendMessage() {
        let text = inputText.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, !isSending else { return }

        let encoded = Jtty.encodeMessage(text, toneFrequencyHz: Jtty.defaultToneHz)
        guard encoded.ok else {
            alertMessage = "This message couldn't be encoded for JTTY (it may need more than "
                + "16 frames' worth of compact atoms to send)."
            return
        }

        messages.append(ChatMessage(text: displayText(for: encoded.canonicalText), isSent: true))
        inputText = ""
        transmit(samples: encoded.samples)
    }

    private func transmit(samples: [Int16]) {
        guard !samples.isEmpty else { return }

        isSending = true
        let rig = settings.loadRigTxSettings()
        let outputDeviceID = settings.resolvedOutputDevice()?.id

        if let rig {
            Task.detached { _ = RigController.setPTT(model: rig.model, port: rig.port, baudRate: rig.baudRate, on: true) }
        }

        let leadMs = rig != nil ? Self.pttLeadMs : 0
        let durationMs = samples.count * 1000 / Jtty.txSampleRate
        let totalMs = leadMs + durationMs + Self.txTailMs

        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(leadMs)) { [weak self] in
            do {
                try self?.playbackEngine.play(samples: samples, deviceID: outputDeviceID) {}
            } catch {
                self?.alertMessage = "Couldn't play the transmit audio: \(error.localizedDescription)"
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(totalMs)) { [weak self] in
            if let rig {
                Task.detached { _ = RigController.setPTT(model: rig.model, port: rig.port, baudRate: rig.baudRate, on: false) }
            }
            self?.isSending = false
        }
    }

    // MARK: - Frequency menu

    func tuneRig(toMHz freqMHz: Double) {
        guard let rig = settings.loadRigTxSettings() else {
            alertMessage = "Configure a rig model and port in Settings first."
            return
        }
        Task.detached {
            if let error = RigController.setFrequency(model: rig.model, port: rig.port, baudRate: rig.baudRate,
                                                         freqHz: freqMHz * 1.0e6) {
                await MainActor.run { self.alertMessage = error }
            }
        }
    }
}
