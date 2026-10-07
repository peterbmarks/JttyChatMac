import Foundation

/// Wire parameters and encoder for the JTTY mode codec. Ported from
/// JttyChatLinux/src/JttyCodec.{h,cpp}; the actual encode DSP lives in the
/// Fortran routines declared in JttyCodecBridge.h (see
/// ../../../ThirdParty/jtty_codec).
enum Jtty {
    // Wire parameters fixed by the codec: 12000/384 = 31.25 baud, frames
    // are 59 symbols long.
    static let rxSampleRate = 12000
    static let rxSamplesPerSymbol = 384
    static let txSampleRate = 48000
    static let txSamplesPerSymbol = 4 * rxSamplesPerSymbol
    static let symbolsPerFrame = 59
    static let maxMessageLength = 80
    static let maxFrames = 16 // genjtty's MAX_TONES = 59*16

    // Default audio tone (Hz) used for both transmit and the decoder's
    // primary search channel, matching WSJT-X's own JTTY defaults so two
    // default-configured stations can hear each other.
    static let defaultToneHz: Float = 1500.0

    struct EncodedMessage {
        var ok = false
        var canonicalText = "" // text as actually encoded (whitespace-padded input, trimmed)
        var samples: [Int16] = [] // 48 kHz mono PCM, ready to play
    }

    // Matches the codec's own alphabet (jtty_source_codec.f90's ALPHABET),
    // plus lowercase a-z which the codec also accepts.
    private static let supportedAlphabet =
        Set("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ +-./?!\"#$%,&*()_'=[]{}<>|:;abcdefghijklmnopqrstuvwxyz")

    // Builds the fixed-width, space-padded 80-byte frame genjtty_profile_
    // expects, sanitizing anything the codec can't represent to '#'.
    private static func prepareFrame(_ message: String) -> [CChar] {
        let bounded = String(message.prefix(maxMessageLength))
        var sanitized = ""
        sanitized.reserveCapacity(bounded.count)
        for c in bounded {
            sanitized.append(supportedAlphabet.contains(c) ? c : "#")
        }

        var bytes = Array(sanitized.unicodeScalars).map { CChar(bitPattern: UInt8(truncatingIfNeeded: $0.value)) }
        bytes.append(contentsOf: Array(repeating: CChar(bitPattern: UInt8(ascii: " ")),
                                        count: max(0, maxMessageLength - bytes.count)))
        return bytes
    }

    // Encodes message for transmission at the given audio tone frequency
    // (Hz). Truncates to maxMessageLength and replaces unsupported
    // characters with '#', matching the codec's own text normalization.
    static func encodeMessage(_ message: String, toneFrequencyHz: Float) -> EncodedMessage {
        var result = EncodedMessage()

        var frame = prepareFrame(message)
        var itone = [Int32](repeating: 0, count: symbolsPerFrame * maxFrames)
        var nsym: Int32 = 0
        var exchangeProfile: Int32 = 0 // NativeExchangeProfile::None - no contest exchange UI here

        genjtty_profile_(&frame, &exchangeProfile, &itone, &nsym, Int(maxMessageLength))
        guard nsym > 0 else { return result }

        // genjtty_profile_ normalizes the message in place (padding/casing);
        // read it back so what we display/log matches what was actually sent.
        let frameBytes = frame.map { UInt8(bitPattern: $0) }
        result.canonicalText = String(decoding: frameBytes, as: UTF8.self)
            .trimmingCharacters(in: .whitespaces)

        var nsps = Int32(txSamplesPerSymbol)
        var bt: Float = 2.0
        var fsample = Float(txSampleRate)
        var f0 = toneFrequencyHz
        var icmplx: Int32 = 0
        var nwave = nsym * nsps

        var wave = [Float](repeating: 0, count: Int(nwave))
        wave.withUnsafeMutableBufferPointer { wavePtr in
            gen_jttywave_(&itone, &nsym, &nsps, &bt, &fsample, &f0, wavePtr.baseAddress, wavePtr.baseAddress,
                          &icmplx, &nwave)
        }
        guard nwave > 0 else { return result }

        result.samples = wave.prefix(Int(nwave)).map { sample in
            let v = (sample * 32767.0).clamped(to: -32768.0...32767.0)
            return Int16(v.rounded())
        }

        result.ok = true
        return result
    }
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
