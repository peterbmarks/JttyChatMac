import Accelerate
import Foundation

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
