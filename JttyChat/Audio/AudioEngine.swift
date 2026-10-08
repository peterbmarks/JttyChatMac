import AppKit
import AVFoundation
import AudioToolbox
import CoreAudio

// Ported from JttyChatLinux's use of Qt Multimedia (QAudioSource/QAudioSink
// in MainWindow.cpp): capture mono 12 kHz Int16 PCM for the JTTY decoder,
// and play back mono 48 kHz Int16 PCM (the JTTY encoder's output) through a
// chosen output device, keying PTT for exactly its duration.

/// Continuously captures from a chosen (or default) input device and
/// delivers mono 12 kHz Int16 PCM chunks as they arrive.
final class CaptureEngine {
    private let engine = AVAudioEngine()
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
        case unusableInputFormat(AVAudioFormat)

        var errorDescription: String? {
            switch self {
            case .unusableInputFormat(let format):
                return "The audio input reported an unusable format (\(format.sampleRate) Hz, "
                    + "\(format.channelCount) ch)."
            }
        }
    }

    private var isTapInstalled = false
    private var notificationObservers: [(NotificationCenter, NSObjectProtocol)] = []

    func start(deviceID: AudioDeviceID?) throws {
        stop()

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
            throw CaptureError.unusableInputFormat(inputFormat)
        }

        // format: nil means "whatever this bus is really producing".
        // Handing installTap a format cached up here is what raised
        // "Failed to create tap due to format mismatch" - an uncaught
        // Objective-C exception, so a hard crash - once the device came
        // back from sleep at a different sample rate than it left at.
        input.installTap(onBus: 0, bufferSize: 2048, format: nil) { [weak self] buffer, _ in
            self?.convertAndEmit(buffer)
        }
        isTapInstalled = true

        engine.prepare()
        try engine.start()

        observeInterruptions()
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
    }

    private func observeInterruptions() {
        let center = NotificationCenter.default
        let configObserver = center.addObserver(forName: .AVAudioEngineConfigurationChange,
                                                 object: engine, queue: .main) { [weak self] _ in
            self?.onNeedsRestart?()
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
