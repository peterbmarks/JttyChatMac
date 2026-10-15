import Accelerate
import Foundation
import Synchronization

/// Lets our own transmission show on the waterfall. While we transmit,
/// the rig typically mutes (or simply doesn't pass) receive audio, so the
/// waterfall would otherwise go blank; instead, the transmit audio is
/// mixed into what the waterfall is shown - never into what the decoder
/// hears - as it's played.
///
/// It's paced by the capture stream rather than a clock: each captured
/// chunk takes the same number of transmit samples, so the trace scrolls
/// at exactly the waterfall's own rate. Fed from the main thread, drained
/// on the audio capture thread.
nonisolated final class TransmitMonitor: Sendable {
    // Full-scale transmit audio would sit far above anything received and
    // paint the waterfall solid red; this brings it down to a strong but
    // readable signal (about -45 dB on the waterfall's scale).
    private static let displayGain: Float = 0.02
    private static let decimation = Jtty.txSampleRate / Jtty.rxSampleRate

    private struct State {
        var samples: [Float] = []
        var position = 0
    }

    private let state = Mutex(State())

    /// Starts showing a transmission that's beginning to play now
    /// (48 kHz transmit samples).
    func start(_ txSamples: [Int16]) {
        // Decimating without a filter is fine here: the transmit signal is
        // a narrow tone pattern far below the 12 kHz rate's 6 kHz limit.
        let samples = stride(from: 0, to: txSamples.count, by: Self.decimation).map {
            Float(txSamples[$0]) * Self.displayGain
        }
        state.withLock { $0 = State(samples: samples, position: 0) }
    }

    /// Stops showing whatever's left of the current transmission.
    func stop() {
        state.withLock { $0 = State() }
    }

    /// The captured chunk with the matching stretch of any transmission in
    /// progress added in; unchanged when nothing's being transmitted.
    func mix(into captured: [Int16]) -> [Int16] {
        state.withLock { state in
            guard state.position < state.samples.count else { return captured }
            var mixed = captured
            let count = min(captured.count, state.samples.count - state.position)
            for i in 0..<count {
                mixed[i] = Int16(clamping: Int(Float(mixed[i]) + state.samples[state.position + i]))
            }
            state.position += count
            return mixed
        }
    }
}

/// Computes a short-time magnitude spectrum (in dB) over a frequency band
/// from a rolling window of the most recently fed samples. Ported from
/// JttyChatLinux/src/AudioSpectrum.{h,cpp} (which used FFTW); this uses
/// Accelerate's vDSP FFT instead since there's no need to share an FFT
/// engine with the Fortran decoder.
final class AudioSpectrum {
    // Recompute roughly every 40ms at 12kHz rather than on every single sample.
    private static let updateHopSamples = 480

    private let fftSize: Int
    private let sampleRate: Int
    private let log2n: vDSP_Length

    private var ring: [Float]
    private var ringPos = 0
    private var samplesSinceUpdate = 0
    private let window: [Float]

    private let fftSetup: FFTSetup
    private var realIn: [Float]
    private var imagIn: [Float]

    init(fftSize: Int, sampleRate: Int) {
        self.fftSize = fftSize
        self.sampleRate = sampleRate
        self.log2n = vDSP_Length(log2(Double(fftSize)))
        self.ring = [Float](repeating: 0, count: fftSize)
        self.window = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized,
                                    count: fftSize, isHalfWindow: false)
        self.realIn = [Float](repeating: 0, count: fftSize / 2)
        self.imagIn = [Float](repeating: 0, count: fftSize / 2)
        self.fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
    }

    deinit {
        vDSP_destroy_fftsetup(fftSetup)
    }

    // Appends samples to the rolling window. Once enough new samples have
    // accumulated since the last update, recomputes the FFT and returns one
    // magnitude (dB) value per bin spanning [lowHz, highHz]; otherwise
    // returns nil.
    func addSamples(_ samples: [Int16], lowHz: Int, highHz: Int) -> [Float]? {
        var dueForUpdate = false
        for sample in samples {
            ring[ringPos] = Float(sample) / 32768.0
            ringPos = (ringPos + 1) % fftSize
            samplesSinceUpdate += 1
            if samplesSinceUpdate >= Self.updateHopSamples {
                samplesSinceUpdate = 0
                dueForUpdate = true
            }
        }
        guard dueForUpdate else { return nil }

        var windowed = [Float](repeating: 0, count: fftSize)
        for i in 0..<fftSize {
            windowed[i] = ring[(ringPos + i) % fftSize] * window[i]
        }

        var magnitudes = [Float](repeating: 0, count: fftSize / 2)
        realIn.withUnsafeMutableBufferPointer { realPtr in
            imagIn.withUnsafeMutableBufferPointer { imagPtr in
                var split = DSPSplitComplex(realp: realPtr.baseAddress!, imagp: imagPtr.baseAddress!)
                windowed.withUnsafeBufferPointer { windowedPtr in
                    windowedPtr.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: fftSize / 2) { complexPtr in
                        vDSP_ctoz(complexPtr, 2, &split, 1, vDSP_Length(fftSize / 2))
                    }
                }
                vDSP_fft_zrip(fftSetup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                vDSP_zvabs(&split, 1, &magnitudes, 1, vDSP_Length(fftSize / 2))
            }
        }

        let binHz = Float(sampleRate) / Float(fftSize)
        let maxBin = fftSize / 2 - 1
        let loBin = min(max(Int(Float(lowHz) / binHz), 0), maxBin)
        let hiBin = min(max(Int((Float(highHz) / binHz).rounded(.up)), 0), maxBin)

        var result = [Float]()
        result.reserveCapacity(hiBin - loBin + 1)
        for bin in loBin...hiBin {
            // vDSP's real FFT scales magnitudes by 2x relative to a
            // straightforward DFT; /2 here keeps the same normalization
            // (magnitude/fftSize) as the original FFTW-based code.
            let magnitude = (magnitudes[bin] / 2.0) / Float(fftSize)
            result.append(20.0 * log10(magnitude + 1.0e-9))
        }
        return result
    }
}
