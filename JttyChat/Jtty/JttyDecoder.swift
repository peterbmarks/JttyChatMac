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

    /// One report from the decoder about a message it's assembling.
    ///
    /// The Fortran decoder emits these as a transmission arrives, not just
    /// at the end of one: text grows frame by frame ("TEST" -> "TEST
    /// 12345" -> "TEST 12345 THIS"), and the trellis decoder can also
    /// *revise* what it already reported as later frames resolve an
    /// earlier ambiguity. So each update carries the full text so far
    /// rather than just the new characters, and should replace whatever
    /// was last shown for this messageId.
    struct Update {
        /// Identifies one message assembly across its updates. Several can
        /// be in flight at once when more than one station is audible.
        let messageId: Int64
        /// The whole message as decoded so far, not only the new part.
        let text: String
        let frequencyHz: Float
        /// True on the final update for this messageId; no more follow.
        let isComplete: Bool
    }

    /// Called (possibly off the main thread - see poll()'s caller) each
    /// time a message is extended or revised, and once more when it
    /// completes.
    var onMessageUpdated: ((Update) -> Void)?

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
                guard messageIds[i] > 0 else { continue }
                let start = i * Self.messageLength
                let bytes = textBlocks[start..<(start + Self.messageLength)]
                    .map { UInt8(bitPattern: $0) }
                let text = String(bytes: bytes, encoding: .isoLatin1)?
                    .trimmingCharacters(in: .whitespaces) ?? ""
                onMessageUpdated?(Update(messageId: messageIds[i], text: text,
                                          frequencyHz: frequencies[i], isComplete: complete[i]))
            }
        } while count == Self.batchSize
    }

    deinit {
        jtty_release_fft_resources()
    }
}
