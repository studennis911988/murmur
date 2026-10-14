import Foundation

public enum Vocabulary {
    /// Splits the user's dictionary (comma, semicolon or newline separated)
    /// into unique terms, keeping the first spelling of each.
    public static func terms(from raw: String) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for piece in raw.split(whereSeparator: { $0 == "," || $0 == ";" || $0.isNewline }) {
            let term = piece.trimmingCharacters(in: .whitespaces)
            guard !term.isEmpty, seen.insert(term.lowercased()).inserted else { continue }
            result.append(term)
        }
        return result
    }
}

public enum TranscriptFilter {
    /// Phrases speech models emit for silence or noise. A transcript made only
    /// of one of these is treated as empty.
    static let silencePhrases: Set<String> = [
        "you", "thank you", "thanks", "thanks for watching", "thank you for watching",
        "thank you so much for watching", "bye", "okay", "uh", "um", "hmm",
        "subtitles by the amaraorg community", "please subscribe",
    ]

    /// Strips non-speech annotations ("[BLANK_AUDIO]", "(music)") and
    /// collapses whitespace. When the recording held little voiced audio, a
    /// transcript consisting only of a known silence phrase becomes "".
    public static func clean(_ text: String, likelySilence: Bool) -> String {
        var cleaned = text.replacingOccurrences(
            of: "\\[(?:blank[_ ]audio|no speech|music|silence|inaudible|noise|applause|laughter)\\]|\\((?:[a-z ]*music|silence|inaudible|noise|applause|laughter)\\)",
            with: " ",
            options: [.regularExpression, .caseInsensitive]
        )
        cleaned = cleaned.replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression)
        cleaned = cleaned
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let key = cleaned.lowercased().filter { $0.isLetter || $0 == " " }.trimmingCharacters(in: .whitespaces)
        if cleaned.allSatisfy({ $0.isPunctuation || $0.isWhitespace }) { return "" }
        if likelySilence, key.isEmpty || silencePhrases.contains(key) { return "" }
        return cleaned
    }
}

public enum WAVEncoder {
    /// 16-bit PCM mono WAV, the format every transcription API accepts.
    public static func encode(samples: [Float], sampleRate: Int) -> Data {
        let byteCount = samples.count * 2
        var data = Data(capacity: 44 + byteCount)
        func append<T: FixedWidthInteger>(_ value: T) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        data.append(contentsOf: Array("RIFF".utf8))
        append(UInt32(36 + byteCount))
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8))
        append(UInt32(16))
        append(UInt16(1))                      // PCM
        append(UInt16(1))                      // mono
        append(UInt32(sampleRate))
        append(UInt32(sampleRate * 2))         // byte rate
        append(UInt16(2))                      // block align
        append(UInt16(16))                     // bits per sample
        data.append(contentsOf: Array("data".utf8))
        append(UInt32(byteCount))
        for sample in samples {
            let clamped = max(-1, min(1, sample))
            append(Int16(clamped * Float(Int16.max)))
        }
        return data
    }
}
