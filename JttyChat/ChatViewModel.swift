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
    // A USB interface can take several seconds to re-enumerate after a
    // wake, so keep trying for ~30s before bothering the user.
    private static let captureStartRetries = 15
    private static let captureRetryDelay: TimeInterval = 2

    // One JTTY frame of audio. The decoder reports progress on a message
    // once per frame, so this is also the normal spacing between updates
    // to an in-progress bubble (measured against a real transmission:
    // 1.89s, very regular).
    private static let frameDuration =
        Double(Jtty.symbolsPerFrame * Jtty.rxSamplesPerSymbol) / Double(Jtty.rxSampleRate)
    // How long an in-progress bubble may go without further progress
    // before it's written off as a false start - the decoder beginning to
    // assemble a message out of noise and then abandoning it, which
    // otherwise leaves a half-decoded bubble on screen forever.
    //
    // Eight frames is deliberately generous against the ~1.9s normal
    // cadence, so a weak signal that stalls for a few frames isn't thrown
    // away; it's still only half the ~30s a maximum-length 16-frame
    // message takes end to end.
    private static let partialDecodeTimeout = 8 * frameDuration
    private static let partialDecodeSweepInterval: TimeInterval = 2
    // A stalled partial this short is the decoder having briefly latched
    // onto noise, and is thrown away; anything longer is most likely a
    // real transmission that faded out, so it's kept and marked as
    // incomplete rather than discarded.
    private static let minimumKeptPartialLength = 6

    @Published var messages: [ChatMessage] = []
    // Capped at what one transmission can carry (16 frames of five
    // characters), so the user sees the limit as they type or paste
    // rather than the encoder silently cutting the message short.
    @Published var inputText = "" {
        didSet {
            if inputText.count > Jtty.maxMessageLength {
                inputText = String(inputText.prefix(Jtty.maxMessageLength))
            }
        }
    }

    var isAtMessageLengthLimit: Bool {
        inputText.count >= Jtty.maxMessageLength
    }
    @Published var isSending = false
    @Published var alertMessage: String?

    /// Signal quality of the most recently decoded frame, for the status
    /// line under the waterfall. Nil until something has been decoded.
    struct ReceiveQuality: Equatable {
        let snrDb: Int
        let symbolErrors: Int
        let symbolsChecked: Int
    }

    @Published var receiveQuality: ReceiveQuality?

    // The text of the most recently sent message, as typed, so it can be recalled with the up arrow.
    private var lastSentText: String?

    let waterfall = WaterfallBitmap()

    private let settings: AppSettings
    private let decoder = JttyDecoder()
    private let spectrum = AudioSpectrum(fftSize: spectrumFftSize, sampleRate: Jtty.rxSampleRate)
    private let captureEngine = CaptureEngine()
    private let playbackEngine = PlaybackEngine()

    // Bubbles for messages still arriving, keyed by the decoder's message
    // id, so each update rewrites the bubble it belongs to instead of
    // appending a new one. Entries are dropped as messages complete, or
    // when they go quiet for too long (see dropStalePartialDecodes).
    private struct LiveBubble {
        let bubbleID: ChatMessage.ID
        var lastProgress: Date
    }

    private var liveBubbles: [Int64: LiveBubble] = [:]
    private var partialDecodeSweep: Timer?

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
            if update.isComplete {
                liveBubbles.removeValue(forKey: update.messageId)
                stopSweepIfIdle()
            }
        }

        let text = displayText(for: update.text)
        guard !text.isEmpty else { return }

        receiveQuality = ReceiveQuality(snrDb: update.snrDb, symbolErrors: update.symbolErrors,
                                        symbolsChecked: update.symbolsChecked)

        if let live = liveBubbles[update.messageId],
           let index = messages.firstIndex(where: { $0.id == live.bubbleID }) {
            // Only a change in the text counts as progress. The decoder
            // keeps re-reporting a stalled message verbatim as it scans
            // on, and taking those at face value would push the deadline
            // out forever - the bubble would never time out at all.
            if messages[index].text != text {
                liveBubbles[update.messageId]?.lastProgress = Date()
            }
            messages[index].text = text
            messages[index].decodeState = update.isComplete ? .complete : .inProgress
        } else {
            let message = ChatMessage(text: text, isSent: false,
                                      decodeState: update.isComplete ? .complete : .inProgress)
            messages.append(message)
            // A message that arrived already complete needs no tracking;
            // one still in progress has to be watched in case it stalls.
            if !update.isComplete {
                liveBubbles[update.messageId] = LiveBubble(bubbleID: message.id, lastProgress: Date())
                startSweepIfNeeded()
            }
        }
    }

    // MARK: - Abandoned partial decodes

    // The decoder will happily start assembling a message out of band
    // noise and then never finish it, which leaves a half-decoded bubble
    // sitting on screen indefinitely. Nothing tells us a message has been
    // abandoned - updates simply stop - so bubbles that stop making
    // progress are swept away after partialDecodeTimeout.
    //
    // The timer only runs while something is actually in progress, so an
    // idle receiver isn't waking up every couple of seconds for nothing.
    private func startSweepIfNeeded() {
        guard partialDecodeSweep == nil else { return }
        partialDecodeSweep = Timer.scheduledTimer(withTimeInterval: Self.partialDecodeSweepInterval,
                                                   repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.dropStalePartialDecodes() }
        }
    }

    private func stopSweepIfIdle() {
        guard liveBubbles.isEmpty else { return }
        partialDecodeSweep?.invalidate()
        partialDecodeSweep = nil
    }

    private func dropStalePartialDecodes() {
        let cutoff = Date().addingTimeInterval(-Self.partialDecodeTimeout)
        let stale = liveBubbles.filter { $0.value.lastProgress < cutoff }
        guard !stale.isEmpty else { return }

        for (messageId, live) in stale {
            retire(live)
            liveBubbles.removeValue(forKey: messageId)
        }
        stopSweepIfIdle()
    }

    // A bubble that will never make progress again: keep what was
    // decoded if there's enough of it to be worth reading, otherwise
    // remove it as a false start.
    private func retire(_ live: LiveBubble) {
        guard let index = messages.firstIndex(where: { $0.id == live.bubbleID }) else { return }
        if messages[index].text.count > Self.minimumKeptPartialLength {
            messages[index].decodeState = .incomplete
        } else {
            messages.remove(at: index)
        }
    }

    // Capture was interrupted, so the decoder's in-flight messages are
    // gone with it and their bubbles will never complete. Drop them now
    // rather than leaving them to time out.
    private func dropAllPartialDecodes() {
        guard !liveBubbles.isEmpty else { return }
        for live in liveBubbles.values {
            retire(live)
        }
        liveBubbles.removeAll()
        stopSweepIfIdle()
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
        // The audio device reconfigured or the machine woke; AVAudioEngine
        // has dropped the tap and won't restore it on its own.
        captureEngine.onNeedsRestart = { [weak self] in
            self?.restartReceiver()
        }
        startCapture(retriesRemaining: Self.captureStartRetries)
    }

    // Audio device choices may have changed in Settings, or capture was
    // interrupted; restart against whatever is now configured. The device
    // is re-resolved from its saved UID each time, so an interface that
    // comes back with a different AudioDeviceID after a wake or a replug
    // is still found.
    func restartReceiver() {
        captureEngine.stop()
        // Samples from before and after the break aren't contiguous, so
        // don't let the decoder try to read a frame across the gap.
        decoder.reset()
        dropAllPartialDecodes()
        startReceiver()
    }

    private func startCapture(retriesRemaining: Int) {
        do {
            try captureEngine.start(deviceID: settings.resolvedInputDevice()?.id)
        } catch {
            // Straight after a wake the input device may not be back yet,
            // so retry for a while before giving up. Failing silently here
            // is what used to leave the app permanently deaf with no hint
            // that anything was wrong.
            guard retriesRemaining > 0 else {
                alertMessage = "Couldn't start listening on the audio input: "
                    + "\(error.localizedDescription) Check the input device in Settings."
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.captureRetryDelay) { [weak self] in
                self?.startCapture(retriesRemaining: retriesRemaining - 1)
            }
        }
    }

    // MARK: - Send

    func sendMessage() {
        let text = inputText.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, !isSending else { return }

        var encoded = Jtty.encodeMessage(text, toneFrequencyHz: Jtty.defaultToneHz)
        // Sign the message with the callsign if asked to and there's room.
        // Even within 80 characters the longer text can fail to encode (it
        // can need more than 16 frames), so then the message goes unsigned.
        if let signed = signedWithCallsign(text) {
            let encodedSigned = Jtty.encodeMessage(signed, toneFrequencyHz: Jtty.defaultToneHz)
            if encodedSigned.ok {
                encoded = encodedSigned
            }
        }
        guard encoded.ok else {
            alertMessage = "This message couldn't be encoded for JTTY (it may need more than "
                + "16 frames' worth of compact atoms to send)."
            return
        }

        messages.append(ChatMessage(text: displayText(for: encoded.canonicalText), isSent: true))
        lastSentText = text
        inputText = ""
        transmit(samples: encoded.samples)
    }

    // The message with "-CALLSIGN" appended, or nil if the setting is off,
    // there's no callsign, or the result wouldn't fit in one transmission.
    private func signedWithCallsign(_ text: String) -> String? {
        let callsign = settings.callsign.trimmingCharacters(in: .whitespaces)
        guard settings.appendCallsign, !callsign.isEmpty else { return nil }
        let signed = text + "-" + callsign
        return signed.count <= Jtty.maxMessageLength ? signed : nil
    }

    /// Puts the last sent message back in the input field. Returns false if nothing has been sent yet.
    @discardableResult
    func recallLastSentMessage() -> Bool {
        guard let lastSentText else { return false }
        inputText = lastSentText
        return true
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
