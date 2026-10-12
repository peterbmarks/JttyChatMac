import AppKit
import AVFoundation
import AudioToolbox
import CoreAudio
import os

// Ported from JttyChatLinux's use of Qt Multimedia (QAudioSource/QAudioSink
// in MainWindow.cpp): capture mono 12 kHz Int16 PCM for the JTTY decoder,
// and play back mono 48 kHz Int16 PCM (the JTTY encoder's output) through a
// chosen output device, keying PTT for exactly its duration.

/// Continuously captures from a chosen (or default) input device and
/// delivers mono 12 kHz Int16 PCM chunks as they arrive.
final class CaptureEngine {
    // Replaced with a fresh instance on every start(); see there.
    private var engine = AVAudioEngine()
    private let targetFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: Double(Jtty.rxSampleRate),
                                              channels: 1, interleaved: true)!
    private var converter: AVAudioConverter?

    /// Called with each newly captured chunk, on whatever internal thread
    /// AVAudioEngine delivers taps on (not the main thread).
    var onSamples: (([Int16]) -> Void)?

    /// Called on the main queue when the system has torn this engine's
    /// graph down and capture has to be built again from scratch.
    ///
    /// AVAudioEngine drops its node graph - taps included - whenever the
    /// input device reconfigures: a sample-rate renegotiation, an unplug,
    /// or coming back from sleep. It does *not* recover by itself, and the
    /// tap simply never fires again, so without this the app goes
    /// permanently deaf while still looking fine (the waterfall keeps
    /// displaying its last painted frame).
    var onNeedsRestart: (() -> Void)?

    enum CaptureError: LocalizedError {
        case unusableInputFormat(AVAudioFormat, diagnostics: String)
        case startFailed(Error, diagnostics: String)

        var errorDescription: String? {
            switch self {
            case .unusableInputFormat(let format, _):
                return "The audio input reported an unusable format (\(format.sampleRate) Hz, "
                    + "\(format.channelCount) ch)."
            case .startFailed(let error, _):
                return error.localizedDescription
            }
        }

        /// What the device and engine looked like when this failed - worth
        /// including in a bug report.
        var diagnostics: String {
            switch self {
            case .unusableInputFormat(_, let diagnostics), .startFailed(_, let diagnostics):
                return diagnostics
            }
        }
    }

    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "JttyChat", category: "Audio")

    private var isTapInstalled = false
    // The device and hardware format capture was started with, so a
    // configuration-change notification can be checked for whether
    // anything actually changed (see observeInterruptions()).
    private var startedSignature: InputSignature?
    // Cleared on each start; set when the tap delivers its first buffer, so
    // the log shows whether audio is actually arriving.
    private var hasReceivedAudio = false
    private var notificationObservers: [(NotificationCenter, NSObjectProtocol)] = []

    func start(deviceID: AudioDeviceID?) throws {
        stop()

        // Build a new engine for every attempt rather than reusing one. An
        // AVAudioEngine caches its input node's format the first time it's
        // asked, and keeps it after the device changes underneath it (a
        // different device chosen in Settings, a USB interface coming back
        // from sleep, or another app such as WSJT-X switching the device's
        // sample rate). start() then fails with -10868
        // (kAudioUnitErr_FormatNotSupported), and keeps failing on every
        // retry, because the stale format never gets refreshed.
        engine = AVAudioEngine()

        if let deviceID {
            try Self.setDevice(deviceID, on: engine.inputNode.audioUnit)
        }

        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)

        // Straight after a wake or a device change the input node can
        // briefly report a zero-rate/zero-channel format. Building a tap
        // on that yields a tap that never delivers anything - a silent,
        // permanent failure - so refuse it and let the caller retry once
        // the device has settled.
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            let error = CaptureError.unusableInputFormat(inputFormat, diagnostics: diagnostics(error: nil))
            Self.logger.error("Capture start failed: \(error.localizedDescription, privacy: .public) \(error.diagnostics, privacy: .public)")
            throw error
        }

        // format: nil means "whatever this bus is really producing".
        // Handing installTap a format cached up here is what raised
        // "Failed to create tap due to format mismatch" - an uncaught
        // Objective-C exception, so a hard crash - once the device came
        // back from sleep at a different sample rate than it left at.
        hasReceivedAudio = false
        input.installTap(onBus: 0, bufferSize: 2048, format: nil) { [weak self] buffer, _ in
            self?.convertAndEmit(buffer)
        }
        isTapInstalled = true

        engine.prepare()
        do {
            try engine.start()
        } catch {
            let captureError = CaptureError.startFailed(error, diagnostics: diagnostics(error: error))
            Self.logger.error("Capture start failed: \(captureError.localizedDescription, privacy: .public) \(captureError.diagnostics, privacy: .public)")
            throw captureError
        }

        startedSignature = currentSignature()
        Self.logger.notice("Capture started: \(self.diagnostics(error: nil), privacy: .public)")
        observeInterruptions()
    }

    // A one-paragraph snapshot of the input device and the engine's view of
    // it. A sample-rate disagreement between "device" and "engine" here is
    // the signature of a -10868 failure.
    private func diagnostics(error: Error?) -> String {
        var parts: [String] = []

        let audioUnit = engine.inputNode.audioUnit
        if let audioUnit, let deviceID = Self.currentDevice(of: audioUnit) {
            let name = AudioDeviceLister.deviceName(for: deviceID) ?? "unknown"
            let rate = AudioDeviceLister.nominalSampleRate(for: deviceID).map { "\(Int($0)) Hz" } ?? "unknown rate"
            parts.append("Device: \(name) (id \(deviceID)) at \(rate)")
        } else {
            parts.append("Device: none")
        }

        if let audioUnit, let hardware = Self.streamFormat(of: audioUnit, scope: kAudioUnitScope_Input, element: 1) {
            parts.append("hardware stream: \(Int(hardware.mSampleRate)) Hz, \(hardware.mChannelsPerFrame) ch")
        }

        let nodeFormat = engine.inputNode.outputFormat(forBus: 0)
        parts.append("engine input format: \(Int(nodeFormat.sampleRate)) Hz, \(nodeFormat.channelCount) ch")

        if let error {
            let code = (error as NSError).code
            let name = Self.audioUnitErrorName(code).map { " \($0)" } ?? ""
            parts.append("error \((error as NSError).domain) \(code)\(name)")
        }
        return parts.joined(separator: "; ") + "."
    }

    private static func currentDevice(of audioUnit: AudioUnit) -> AudioDeviceID? {
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioUnitGetProperty(audioUnit, kAudioOutputUnitProperty_CurrentDevice,
                                          kAudioUnitScope_Global, 0, &deviceID, &size)
        return status == noErr && deviceID != 0 ? deviceID : nil
    }

    private static func streamFormat(of audioUnit: AudioUnit, scope: AudioUnitScope,
                                     element: AudioUnitElement) -> AudioStreamBasicDescription? {
        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let status = AudioUnitGetProperty(audioUnit, kAudioUnitProperty_StreamFormat, scope, element, &format, &size)
        return status == noErr ? format : nil
    }

    private static func audioUnitErrorName(_ code: Int) -> String? {
        switch OSStatus(truncatingIfNeeded: code) {
        case kAudioUnitErr_FormatNotSupported: "(kAudioUnitErr_FormatNotSupported)"
        case kAudioUnitErr_FailedInitialization: "(kAudioUnitErr_FailedInitialization)"
        case kAudioUnitErr_InvalidPropertyValue: "(kAudioUnitErr_InvalidPropertyValue)"
        case kAudioUnitErr_CannotDoInCurrentContext: "(kAudioUnitErr_CannotDoInCurrentContext)"
        case kAudioUnitErr_Uninitialized: "(kAudioUnitErr_Uninitialized)"
        case kAudioUnitErr_InvalidElement: "(kAudioUnitErr_InvalidElement)"
        case kAudioHardwareNotRunningError: "(kAudioHardwareNotRunningError)"
        case kAudioDevicePermissionsError: "(kAudioDevicePermissionsError: microphone access denied?)"
        default: nil
        }
    }

    func stop() {
        for (center, observer) in notificationObservers {
            center.removeObserver(observer)
        }
        notificationObservers.removeAll()

        // Removing the tap is deliberately not conditional on the engine
        // running: a start() that threw after installing the tap leaves
        // one behind, and installing a second tap on the same bus raises.
        if isTapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            isTapInstalled = false
        }
        if engine.isRunning {
            engine.stop()
        }
        converter = nil
        startedSignature = nil
    }

    private struct InputSignature: Equatable {
        let deviceID: AudioDeviceID
        let sampleRate: Double
        let channelCount: UInt32
    }

    private func currentSignature() -> InputSignature? {
        guard let audioUnit = engine.inputNode.audioUnit,
              let deviceID = Self.currentDevice(of: audioUnit),
              let hardware = Self.streamFormat(of: audioUnit, scope: kAudioUnitScope_Input, element: 1) else {
            return nil
        }
        return InputSignature(deviceID: deviceID, sampleRate: hardware.mSampleRate,
                              channelCount: hardware.mChannelsPerFrame)
    }

    // Handles AVAudioEngineConfigurationChange. Every freshly built engine
    // posts one shortly after start(), triggered by start() itself
    // switching the input node from the system default device to the
    // chosen one. Rebuilding on that would build another engine, which
    // posts another notification, and so on - capture restarting every
    // ~100 ms and never delivering audio. So only rebuild when the device
    // or its format really changed.
    private func handleConfigurationChange() {
        let signature = currentSignature()
        guard let signature, signature == startedSignature else {
            Self.logger.notice("Audio engine configuration changed; restarting capture")
            onNeedsRestart?()
            return
        }

        // Same device and format. The engine may still have stopped itself
        // as part of the change; start it again in place, without the
        // device switch that a full rebuild would do.
        guard !engine.isRunning else { return }
        do {
            try engine.start()
            Self.logger.notice("Audio engine configuration changed but input is unchanged; resumed in place")
        } catch {
            Self.logger.notice("Audio engine couldn't resume in place (\(error.localizedDescription, privacy: .public)); restarting capture")
            onNeedsRestart?()
        }
    }

    private func observeInterruptions() {
        let center = NotificationCenter.default
        let configObserver = center.addObserver(forName: .AVAudioEngineConfigurationChange,
                                                 object: engine, queue: .main) { [weak self] _ in
            self?.handleConfigurationChange()
        }
        notificationObservers.append((center, configObserver))

        // A sleep/wake cycle doesn't reliably produce a configuration
        // change, but can still leave the engine wedged, so rebuild on
        // wake regardless. The delay gives USB audio interfaces time to
        // re-enumerate before the device is looked up again.
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        let wakeObserver = workspaceCenter.addObserver(forName: NSWorkspace.didWakeNotification,
                                                        object: nil, queue: .main) { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                self?.onNeedsRestart?()
            }
        }
        notificationObservers.append((workspaceCenter, wakeObserver))
    }

    private func convertAndEmit(_ buffer: AVAudioPCMBuffer) {
        let inputFormat = buffer.format
        if !hasReceivedAudio {
            hasReceivedAudio = true
            Self.logger.notice("Receiving audio: \(Int(inputFormat.sampleRate)) Hz, \(inputFormat.channelCount) ch")
        }

        // The resampler is derived from the format the buffers actually
        // arrive in, and rebuilt whenever that changes. A converter
        // cached from an earlier format would resample by the wrong
        // ratio, handing the decoder a stream on the wrong timebase -
        // which an FFT-based waterfall still renders quite happily, while
        // the demodulator sees nothing it can lock onto.
        if converter?.inputFormat != inputFormat {
            converter = AVAudioConverter(from: inputFormat, to: targetFormat)
        }
        guard let converter else { return }

        let ratio = targetFormat.sampleRate / inputFormat.sampleRate
        let outCapacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 16
        guard let outBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outCapacity) else { return }

        var error: NSError?
        var consumed = false
        converter.convert(to: outBuffer, error: &error) { _, outStatus in
            if consumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            outStatus.pointee = .haveData
            return buffer
        }
        guard error == nil, let channelData = outBuffer.int16ChannelData else { return }

        let frameCount = Int(outBuffer.frameLength)
        guard frameCount > 0 else { return }
        let samples = Array(UnsafeBufferPointer(start: channelData[0], count: frameCount))
        onSamples?(samples)
    }

    // Points an AUHAL-backed node's underlying AudioUnit at a specific
    // CoreAudio device, instead of the default input device. Mirrors
    // Hamlib-style QAudioDevice selection in the Linux app's settings.
    fileprivate static func setDevice(_ deviceID: AudioDeviceID, on audioUnit: AudioUnit?) throws {
        guard let audioUnit else { return }
        var mutableDeviceID = deviceID
        let status = AudioUnitSetProperty(audioUnit, kAudioOutputUnitProperty_CurrentDevice,
                                            kAudioUnitScope_Global, 0, &mutableDeviceID,
                                            UInt32(MemoryLayout<AudioDeviceID>.size))
        if status != noErr {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
    }
}

/// Plays a single mono 48 kHz Int16 PCM buffer through a chosen (or
/// default) output device, then calls back when playback finishes.
final class PlaybackEngine {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: Double(Jtty.txSampleRate),
                                        channels: 1, interleaved: true)!

    // Tracks which device the engine is currently configured for, so repeat
    // sends to the same device don't tear the engine down and rebuild it
    // every time (see play(), below).
    private var configuredDeviceID: AudioDeviceID?

    init() {
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
    }

    func play(samples: [Int16], deviceID: AudioDeviceID?, completion: @escaping () -> Void) throws {
        guard !samples.isEmpty else {
            completion()
            return
        }

        // AVAudioPlayerNode doesn't reset its own play/pause state just
        // because the engine was stopped - without this, scheduling and
        // playing a new buffer on a node left over from a previous send
        // silently does nothing (the first transmission plays fine, every
        // one after it is silent).
        player.stop()

        if deviceID != configuredDeviceID {
            if engine.isRunning {
                engine.stop()
            }
            if let deviceID {
                try CaptureEngine.setDevice(deviceID, on: engine.outputNode.audioUnit)
            }
            configuredDeviceID = deviceID
        }

        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)) else {
            completion()
            return
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { samplesPtr in
            buffer.int16ChannelData![0].update(from: samplesPtr.baseAddress!, count: samples.count)
        }

        if !engine.isRunning {
            engine.prepare()
            try engine.start()
        }

        player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { _ in
            DispatchQueue.main.async(execute: completion)
        }
        player.play()
    }
}
