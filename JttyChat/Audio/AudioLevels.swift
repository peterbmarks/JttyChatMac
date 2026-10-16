import Foundation
import Observation

/// Live peak levels of the audio coming in and going out, in dBFS, for the
/// level meters in Settings.
///
/// Levels are reported *before* the user's gain is applied, so Settings can
/// show the effect of a gain setting that hasn't been saved yet by adding
/// it on itself. Kept apart from ChatViewModel's @Published state so that
/// updates arriving many times a second only redraw the meters, not the
/// whole chat window.
@MainActor @Observable
final class AudioLevels {
    static let floorDb: Float = -60
    // How far the meter falls back per update after a peak, so it reads
    // steadily rather than flickering with every chunk.
    private static let decayDb: Float = 1.5

    private(set) var inputDb: Float = floorDb
    private(set) var outputDb: Float = floorDb

    func reportInput(peakDb: Float) {
        inputDb = Self.smoothed(from: inputDb, to: peakDb)
    }

    func reportOutput(peakDb: Float) {
        outputDb = Self.smoothed(from: outputDb, to: peakDb)
    }

    func resetOutput() {
        outputDb = Self.floorDb
    }

    // Rises instantly to a new peak, falls back gradually.
    private static func smoothed(from current: Float, to peak: Float) -> Float {
        max(peak, current - decayDb, floorDb)
    }

    /// The peak level of a chunk of samples, in dBFS.
    nonisolated static func peakDb<S: Sequence<Int16>>(of samples: S) -> Float {
        let peak = samples.reduce(UInt16(0)) { max($0, $1.magnitude) }
        guard peak > 0 else { return floorDb }
        return 20 * log10(Float(peak) / 32768)
    }
}

/// Software gain, set in Settings, for the audio input and output.
enum AudioGain {
    static let inputRangeDb: ClosedRange<Double> = -20...20
    // Attenuation only: the encoder already produces audio close to full
    // scale, so any boost would just clip.
    static let outputRangeDb: ClosedRange<Double> = -40...0

    static func linear(db: Double) -> Float {
        Float(pow(10, db / 20))
    }

    /// The samples scaled by gain, clamped to Int16 rather than wrapping.
    static func apply(_ gain: Float, to samples: [Int16]) -> [Int16] {
        guard gain != 1 else { return samples }
        return samples.map { Int16(clamping: Int((Float($0) * gain).rounded())) }
    }
}
