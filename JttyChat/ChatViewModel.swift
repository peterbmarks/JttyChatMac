import AppKit
import Combine
import Foundation
import UniformTypeIdentifiers
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

    /// The rig's current frequency and mode ("14.090000 MHz  USB"), for the
    /// right of the status line. Nil when no rig is configured.
    @Published var rigStatus: String?
    private static let rigStatusInterval: Duration = .seconds(5)
    // Every Hamlib call opens the serial port, does its thing and closes it
    // again, so two at once (a status poll landing on a PTT key-up) would
    // contend for the port. All rig calls go through this one queue, which
    // also keeps PTT on and off in the order they were issued.
    private let rigQueue = DispatchQueue(label: "JttyChat.rig")
    private var rigStatusPolling: Task<Void, Never>?
    // The configured mode is set on the rig when first connecting to it -
    // at launch, and again after Settings change - but not on every status
    // poll, which would undo any mode change made at the radio.
    private var needsRigModeSet = true

    // The text of the most recently sent message, as typed, so it can be recalled with the up arrow.
    private var lastSentText: String?

    let waterfall = WaterfallBitmap()
    let levels = AudioLevels()
    private let inputGain = LiveGain()
    // Steps the output meter through a transmission as it plays.
    private var outputMeterTimer: Timer?
    private static let outputMeterInterval: TimeInterval = 0.05

    private let settings: AppSettings
    private let decoder = JttyDecoder()
    private let spectrum = AudioSpectrum(fftSize: spectrumFftSize, sampleRate: Jtty.rxSampleRate)
    private let captureEngine = CaptureEngine()
    private let playbackEngine = PlaybackEngine()
    private let transmitMonitor = TransmitMonitor()
    private let deviceMonitor = AudioDeviceMonitor()

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
        deviceMonitor.onChange = { [weak self] in
            MainActor.assumeIsolated { self?.audioDevicesChanged() }
        }
        deviceMonitor.start()
        rigStatusPolling = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshRigStatus()
                try? await Task.sleep(for: Self.rigStatusInterval)
            }
        }
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
            // Each update carries only the latest frame's SNR; keep the best.
            messages[index].bestSnrDb = max(messages[index].bestSnrDb ?? update.snrDb, update.snrDb)
        } else {
            let message = ChatMessage(text: text, isSent: false,
                                      decodeState: update.isComplete ? .complete : .inProgress,
                                      bestSnrDb: update.snrDb)
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
        inputGain.set(db: settings.audioInputGainDb)
        let inputGain = inputGain
        captureEngine.onSamples = { [weak self] rawSamples in
            guard let self else { return }
            // Metered before the gain, so Settings can preview an unsaved one.
            let peakDb = AudioLevels.peakDb(of: rawSamples)
            Task { @MainActor in self.levels.reportInput(peakDb: peakDb) }
            // Gain goes on before the waterfall and decoder, read fresh for
            // every chunk so the slider in Settings takes effect live.
            let samples = AudioGain.apply(inputGain.value, to: rawSamples)
            // Our own transmission is added to the waterfall only; the
            // decoder hears just what was actually received.
            let displayed = self.transmitMonitor.mix(into: samples)
            if let magnitudes = self.spectrum.addSamples(displayed, lowHz: Self.spectrumLowHz, highHz: Self.spectrumHighHz) {
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

    /// Applies an input gain straight away, without saving it, so the
    /// waterfall follows the Settings slider as it moves. Settings puts the
    /// saved gain back when it closes, which undoes this after a Cancel.
    func previewInputGain(db: Double) {
        inputGain.set(db: db)
    }

    // A device was connected or disconnected, or the system default input
    // or output changed (connecting AirPods does all three). That can
    // knock capture off the chosen input, or stop it outright, without
    // AVAudioEngine reporting anything we'd otherwise act on. So rebuild
    // both directions: restartReceiver() re-resolves the saved input
    // device (falling back to the default if it's gone), and playback
    // re-resolves its device on the next transmission.
    private func audioDevicesChanged() {
        playbackEngine.invalidate()
        restartReceiver()
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
                var message = "Couldn't start listening on the audio input: "
                    + "\(error.localizedDescription) Check the input device in Settings."
                if let captureError = error as? CaptureEngine.CaptureError {
                    message += "\n\nDetails: " + captureError.diagnostics
                }
                alertMessage = message
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
        let signed = text + " de " + callsign
        return signed.count <= Jtty.maxMessageLength ? signed : nil
    }

    /// Puts the last sent message back in the input field. Returns false if nothing has been sent yet.
    @discardableResult
    func recallLastSentMessage() -> Bool {
        guard let lastSentText else { return false }
        inputText = lastSentText
        return true
    }

    private func transmit(samples rawSamples: [Int16]) {
        guard !rawSamples.isEmpty else { return }
        let samples = AudioGain.apply(AudioGain.linear(db: settings.audioOutputGainDb), to: rawSamples)

        isSending = true
        let rig = settings.loadRigTxSettings()
        let outputDeviceID = settings.resolvedOutputDevice()?.id

        if let rig {
            rigQueue.async { _ = RigController.setPTT(model: rig.model, port: rig.port, serial: rig.serial, on: true) }
        }

        let leadMs = rig != nil ? Self.pttLeadMs : 0
        let durationMs = samples.count * 1000 / Jtty.txSampleRate
        let totalMs = leadMs + durationMs + Self.txTailMs

        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(leadMs)) { [weak self] in
            do {
                try self?.playbackEngine.play(samples: samples, deviceID: outputDeviceID) {}
                self?.transmitMonitor.start(samples)
                self?.startOutputMeter(rawSamples)
            } catch {
                self?.alertMessage = "Couldn't play the transmit audio: \(error.localizedDescription)"
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(totalMs)) { [weak self] in
            if let rig {
                self?.rigQueue.async {
                    _ = RigController.setPTT(model: rig.model, port: rig.port, serial: rig.serial, on: false)
                }
            }
            // Normally already used up by now; this just guarantees the
            // trace can't outlast the transmission (e.g. if capture stalled).
            self?.transmitMonitor.stop()
            self?.stopOutputMeter()
            self?.isSending = false
        }
    }

    // There's no tap on the playback engine, so the output meter is driven
    // from the samples themselves: their peak level is worked out up front
    // for each meter interval, then stepped through in time with playback.
    // Like the input meter, it's metered before the gain.
    private func startOutputMeter(_ rawSamples: [Int16]) {
        let blockSize = Int(Double(Jtty.txSampleRate) * Self.outputMeterInterval)
        let peaks = stride(from: 0, to: rawSamples.count, by: blockSize).map { start in
            AudioLevels.peakDb(of: rawSamples[start..<min(start + blockSize, rawSamples.count)])
        }
        var index = 0
        outputMeterTimer?.invalidate()
        outputMeterTimer = Timer.scheduledTimer(withTimeInterval: Self.outputMeterInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                guard index < peaks.count else {
                    self.stopOutputMeter()
                    return
                }
                self.levels.reportOutput(peakDb: peaks[index])
                index += 1
            }
        }
    }

    private func stopOutputMeter() {
        outputMeterTimer?.invalidate()
        outputMeterTimer = nil
        levels.resetOutput()
    }

    // MARK: - Export

    /// Asks where to save, then writes every message in the conversation
    /// to a plain-text file, one per line, tab-separated: TX or RX, the
    /// text, the local time, and (for received messages) the best SNR.
    func exportMessages() {
        let panel = NSSavePanel()
        panel.title = "Export Messages"
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = "JttyChat " + Date().formatted(.iso8601.year().month().day()) + ".txt"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            try exportText().write(to: url, atomically: true, encoding: .utf8)
        } catch {
            alertMessage = "Couldn't export the messages: \(error.localizedDescription)"
        }
    }

    private func exportText() -> String {
        // Fixed, locale-independent local time so the file sorts and parses
        // the same everywhere.
        let timeFormatter = DateFormatter()
        timeFormatter.locale = Locale(identifier: "en_US_POSIX")
        timeFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return messages.map { message in
            var fields = [message.isSent ? "TX" : "RX", message.text, timeFormatter.string(from: message.date)]
            if let snr = message.bestSnrDb {
                fields.append("\(snr > 0 ? "+" : "")\(snr) dB")
            }
            return fields.joined(separator: "\t")
        }
        .joined(separator: "\n") + "\n"
    }

    // MARK: - Frequency menu

    func tuneRig(toMHz freqMHz: Double) {
        guard let rig = settings.loadRigTxSettings() else {
            alertMessage = "Configure a rig model and port in Settings first."
            return
        }
        Task {
            let error = await onRigQueue {
                RigController.setFrequency(model: rig.model, port: rig.port, serial: rig.serial,
                                           freqHz: freqMHz * 1.0e6, mode: rig.mode)
            }
            if let error {
                alertMessage = error
            } else {
                // Show the new frequency now rather than at the next poll.
                await refreshRigStatus()
            }
        }
    }

    // MARK: - Rig status

    // Reads the rig's frequency and mode for the status line. Skipped while
    // transmitting, so the poll doesn't hold the port up between PTT on
    // and off (and some rigs won't answer a query while keyed anyway).
    private func refreshRigStatus() async {
        guard let rig = settings.loadRigTxSettings() else {
            rigStatus = nil
            return
        }
        guard !isSending else { return }
        let mode = needsRigModeSet ? rig.mode : nil
        let result = await onRigQueue {
            RigController.connectAndQuery(model: rig.model, port: rig.port, serial: rig.serial, setMode: mode)
        }
        // Keep trying to set the mode until a connection succeeds.
        if result.success {
            needsRigModeSet = false
        }
        rigStatus = result.success ? result.message : "Rig not responding"
    }

    /// The rig settings may have changed: connect again now, setting the
    /// configured mode.
    func reconnectRig() {
        needsRigModeSet = true
        Task { await refreshRigStatus() }
    }

    // Runs a blocking Hamlib call on rigQueue and waits for its result.
    private func onRigQueue<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            rigQueue.async { continuation.resume(returning: work()) }
        }
    }
}
