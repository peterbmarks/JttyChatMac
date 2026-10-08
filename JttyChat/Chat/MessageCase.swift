import Foundation

/// Re-cases an all-caps JTTY message into something readable, for the
/// "Capitalise messages" setting.
///
/// JTTY is an uppercase-only mode - the codec normalizes everything it
/// sends and returns everything it decodes in caps - so a plain chat view
/// reads as one long shout. Swift's own `String.capitalized` is the wrong
/// tool here: it title-cases every word, which turns callsigns and Q-codes
/// into nonsense ("VK3TPM DE W1AW" -> "Vk3Tpm De W1Aw").
///
/// So instead of lowercasing blindly, each token is classified first, and
/// only ordinary prose words get re-cased. Anything that looks like ham
/// shorthand - a callsign, a signal report, a Q-code, a prosign - is left
/// exactly as the decoder produced it.
enum MessageCase {
    /// Lowercases ordinary words, leaves callsigns/abbreviations in caps,
    /// and capitalises the start of each sentence.
    ///
    ///     "TEST 12345 THIS IS VK3TPM" -> "Test 12345 this is VK3TPM"
    ///     "VK3TPM DE W1AW UR RST 599" -> "VK3TPM DE W1AW UR RST 599"
    static func sentenceCased(_ message: String) -> String {
        var result = ""
        result.reserveCapacity(message.count)

        // True only for the first token of each sentence, so a sentence
        // that opens with shorthand ("PSE QSL VIA BURO") doesn't hand the
        // capital to whatever prose word happens to come next.
        var atSentenceStart = true

        for token in tokenize(message) {
            guard !token.isSeparator else {
                result += token.text
                continue
            }

            if keepAsIs(token.text) {
                result += token.text
            } else {
                var word = token.text.lowercased()
                if atSentenceStart {
                    word = uppercasingFirstLetter(word)
                }
                result += word
            }
            atSentenceStart = false

            if token.text.contains(where: { ".!?".contains($0) }) {
                atSentenceStart = true
            }
        }

        return result
    }

    // MARK: - Token classification

    // Vowels for the "no vowels means it's an abbreviation" test below. Y
    // is deliberately excluded so VY and YL are treated as shorthand.
    private static let vowels = Set("AEIOU")

    // Ham shorthand that does contain a vowel, so the no-vowel rule below
    // can't catch it. Deliberately excludes tokens that are also everyday
    // English words (AS, ES, HI, IN, OR, PA...) - protecting those would
    // leave ordinary sentences half-shouted, which is worse than losing the
    // caps on the occasional Q-code.
    private static let hamAbbreviations: Set<String> = [
        "DE", "UR", "OM", "TU", "PSE", "AGN", "CUL", "GUD", "MNI", "SRI",
        "TKS", "ABT", "NIL", "UTC", "RPT", "SSB", "SOTA", "POTA", "IOTA",
        "QRA", "QRG", "QRL", "QRM", "QRN", "QRO", "QRP", "QRT", "QRU",
        "QRV", "QRX", "QSA", "QSB", "QSK", "QSL", "QSO", "QSX", "QSY",
        "QTC", "QTR",
    ]

    // English words that happen to have no vowels (by the AEIOU test) and
    // would otherwise be mistaken for abbreviations.
    private static let vowellessWords: Set<String> = [
        "BY", "MY", "WHY", "TRY", "DRY", "FLY", "SKY", "SHY", "CRY", "SLY",
        "PLY", "PRY", "FRY", "SPY", "STY", "THY", "WRY", "GYM", "MYTH",
        "HYMN", "LYNX", "RHYTHM",
    ]

    /// Whether a token should survive untouched, in the caps the decoder
    /// produced.
    private static func keepAsIs(_ token: String) -> Bool {
        // Punctuation is carried along with the token ("QRZ?"), so classify
        // on the alphanumeric core.
        let core = token.uppercased().filter { $0.isLetter || $0.isNumber || $0 == "/" }
        guard !core.isEmpty else { return true }

        let letters = core.filter { $0.isLetter }

        // Nothing to re-case (numbers, signal reports, "73").
        if letters.isEmpty { return true }

        if vowellessWords.contains(letters) { return false }

        // Letters mixed with digits is the shape of a callsign (VK3TPM,
        // W1AW) or a mode name (FT8).
        if core.contains(where: \.isNumber) { return true }

        // Portable/mobile suffixes: VK3TPM/P, W1AW/M.
        if core.contains("/") { return true }

        // A bare letter is a prosign (K, R, N) rather than a word.
        if letters.count == 1 { return true }

        if hamAbbreviations.contains(letters) { return true }

        // Anything pronounceable has a vowel; CQ, TNX, RST, QTH, WX, CT
        // don't, and are shorthand.
        if !letters.contains(where: { vowels.contains($0) }) { return true }

        return false
    }

    // MARK: - Tokenizing

    private struct Token {
        let text: String
        let isSeparator: Bool
    }

    // Splits into whitespace runs and non-whitespace runs, so the original
    // spacing is reproduced exactly when the pieces are concatenated back.
    private static func tokenize(_ message: String) -> [Token] {
        var tokens: [Token] = []
        var current = ""
        var currentIsSeparator: Bool?

        for character in message {
            let isSeparator = character.isWhitespace
            if isSeparator != currentIsSeparator, let wasSeparator = currentIsSeparator {
                tokens.append(Token(text: current, isSeparator: wasSeparator))
                current = ""
            }
            currentIsSeparator = isSeparator
            current.append(character)
        }
        if let currentIsSeparator, !current.isEmpty {
            tokens.append(Token(text: current, isSeparator: currentIsSeparator))
        }
        return tokens
    }

    private static func uppercasingFirstLetter(_ word: String) -> String {
        guard let index = word.firstIndex(where: { $0.isLetter }) else { return word }
        return word.replacingCharacters(in: index...index, with: word[index].uppercased())
    }
}
