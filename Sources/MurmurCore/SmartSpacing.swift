import Foundation

/// Text immediately around the insertion point of the focused field, read
/// through the Accessibility API before dictation starts.
public struct CaretContext: Equatable, Sendable {
    public var before: String
    public var after: String

    public init(before: String, after: String) {
        self.before = before
        self.after = after
    }

    /// True when the caret sits inside an unfinished sentence on the same line.
    public var continuesSentence: Bool {
        for c in before.reversed() {
            if c.isNewline { return false }
            if c.isWhitespace || SmartSpacing.closers.contains(c) { continue }
            return !SmartSpacing.terminators.contains(c)
        }
        return false
    }

    /// True when a word follows the caret on the same line.
    public var textFollows: Bool {
        for c in after {
            if c.isNewline { return false }
            if c.isWhitespace { continue }
            return true
        }
        return false
    }
}

/// Fits a transcript into the text around the caret: adds the separating
/// spaces a typist would, and drops sentence-start casing when dictating into
/// the middle of a sentence.
public enum SmartSpacing {
    static let terminators: Set<Character> = [".", "!", "?", "…", "。", "！", "？"]
    static let closers: Set<Character> = ["\"", "'", "”", "’", "»", ")", "]", "}", "」", "』", "）"]
    static let openers: Set<Character> = ["\"", "'", "“", "‘", "«", "(", "[", "{", "「", "『", "（", "/", "@", "#"]
    static let attachesLeft: Set<Character> = [".", ",", ";", ":", "!", "?", ")", "]", "}", "…", "%"]

    /// Words that are lowercase mid-sentence in English. Anything else (names,
    /// "I", acronyms) keeps the recognizer's capitalization.
    static let lowercaseStarters: Set<String> = [
        "a", "an", "the", "and", "but", "or", "so", "yet", "nor", "for", "to", "of", "in", "on", "at",
        "by", "with", "from", "into", "about", "as", "if", "then", "than", "because", "when", "while",
        "which", "who", "that", "this", "these", "those", "it", "its", "is", "are", "was", "were", "be",
        "we", "you", "they", "he", "she", "my", "our", "your", "their", "his", "her", "also", "just",
        "maybe", "not", "please", "let's", "there", "here", "what", "how", "where", "why", "some", "all",
        "can", "could", "would", "should", "will", "do", "does", "did", "have", "has", "had", "after",
        "before", "since", "until", "unless", "although", "though", "like", "even", "only", "very",
    ]

    public static func shape(_ text: String, context: CaretContext?) -> String {
        guard let context, !text.isEmpty else { return text }
        var body = text

        if context.continuesSentence {
            body = lowercasingFirstWordIfCommon(body)
        }
        if context.textFollows, body.hasSuffix("."), !body.hasSuffix(".."), body.filter({ terminators.contains($0) }).count == 1 {
            body.removeLast()
        }

        var result = body
        if let last = context.before.last, let first = body.first,
           !last.isWhitespace, !openers.contains(last), !isCJK(last),
           !first.isWhitespace, !attachesLeft.contains(first), !isCJK(first) {
            result = " " + result
        }
        if let next = context.after.first, let end = body.last,
           next.isLetter || next.isNumber, !isCJK(next),
           !end.isWhitespace, !isCJK(end) {
            result += " "
        }
        return result
    }

    static func lowercasingFirstWordIfCommon(_ text: String) -> String {
        let firstWord = text.prefix { !$0.isWhitespace && $0 != "," }
        guard let first = firstWord.first, first.isUppercase else { return text }
        let rest = firstWord.dropFirst()
        // Leave acronyms ("API") and words that are not sentence-case alone.
        if rest.contains(where: { $0.isUppercase }) { return text }
        guard lowercaseStarters.contains(firstWord.lowercased()) else { return text }
        return first.lowercased() + text.dropFirst()
    }

    static func isCJK(_ c: Character) -> Bool {
        guard let scalar = c.unicodeScalars.first else { return false }
        switch scalar.value {
        case 0x3000...0x30FF, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF, 0xAC00...0xD7AF, 0xFF00...0xFF60, 0xFFE0...0xFFE6:
            return true
        default:
            return false
        }
    }
}
