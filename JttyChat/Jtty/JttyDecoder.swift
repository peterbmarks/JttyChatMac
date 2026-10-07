import Foundation

/// Feeds a continuous stream of 12 kHz mono PCM samples to the JTTY decoder
/// (see ../../../ThirdParty/jtty_codec) and reports each message once it's
/// fully received. Ported from JttyChatLinux/src/JttyDecoder.{h,cpp}.
///
/// The underlying Fortran decoder (rjtty_sub_) scans incrementally from
/// where it left off each call, keyed off the buffer length growing call to
/// call; it only resets its internal sync state when a shorter buffer is
/// passed. So samples are appended to an ever-growing buffer rather than a
/// small rolling window, with a periodic reset once that buffer gets large
/// enough that unbounded growth would matter.
final class JttyDecoder {
    private static let batchSize = 30
    private static let messageLength = 80

    // Audio search band and default listening tone/tolerance, matching
    // WSJT-X's own JTTY defaults so two default-configured stations can
    // hear each other without any frequency UI on our side.
    private static let searchBandLowHz: Int32 = 200
    private static let searchBandHighHz: Int32 = 2800
    private static let listenToleranceHz: Float = 20.0

    // ~10 minutes at 12 kHz; large enough that resets are rare in normal
    // use, small enough to keep memory bounded for a long-running session.
    private static let maxBufferSamples = 10 * 60 * Jtty.rxSampleRate

    /// Called (possibly off the main thread - see poll()'s caller) with the
    /// decoded text and its audio frequency (Hz) once a message completes.
    var onMessageDecoded: ((String, Float) -> Void)?

    private var buffer: [Int16] = []

    func addSamples(_ samples: [Int16]) {
        if buffer.count + samples.count > Self.maxBufferSamples {
            buffer.removeAll()
        }
        buffer.append(contentsOf: samples)
    }

    // Scans whatever's new since the last poll and reports any messages
    // that completed. Call periodically (e.g. after each addSamples) from
    // whatever thread is feeding audio in.
    func poll() {
        guard !buffer.isEmpty else { return }

        var k = Int32(buffer.count)
        var nsps = Int32(Jtty.rxSamplesPerSymbol)
        var nfa = Self.searchBandLowHz
        var nfb = Self.searchBandHighHz
        var f0 = Jtty.defaultToneHz
        var ftol = Self.listenToleranceHz
        buffer.withUnsafeMutableBufferPointer { bufferPtr in
            rjtty_sub_(bufferPtr.baseAddress, &k, &nsps, &nfa, &nfb, &f0, &ftol)
        }

        var count: Int32 = 0
        repeat {
            var textBlocks = [CChar](repeating: 0, count: Self.batchSize * Self.messageLength)
            var messageIds = [Int64](repeating: 0, count: Self.batchSize)
            var frequencies = [Float](repeating: 0, count: Self.batchSize)
            var sequenceStarts = [Float](repeating: 0, count: Self.batchSize)
            var complete = [Bool](repeating: false, count: Self.batchSize)

            jtty_get_updates_(&textBlocks, &messageIds, &frequencies, &sequenceStarts, &complete, &count,
                               textBlocks.count)

            for i in 0..<Int(count) {
                guard messageIds[i] > 0, complete[i] else { continue }
                let start = i * Self.messageLength
                let bytes = textBlocks[start..<(start + Self.messageLength)]
                    .map { UInt8(bitPattern: $0) }
                let text = String(bytes: bytes, encoding: .isoLatin1)?
                    .trimmingCharacters(in: .whitespaces) ?? ""
                if !text.isEmpty {
                    onMessageDecoded?(text, frequencies[i])
                }
            }
        } while count == Self.batchSize
    }

    deinit {
        jtty_release_fft_resources()
    }
}
