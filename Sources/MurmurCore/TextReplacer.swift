import Foundation

/// A user rule that rewrites a spoken phrase into fixed text, e.g.
/// "my work email" -> "dennis@example.com".
public struct Replacement: Codable, Equatable, Hashable, Identifiable {
    public var id: UUID
    public var find: String
    public var replace: String

    public init(id: UUID = UUID(), find: String, replace: String) {
        self.id = id
        self.find = find
        self.replace = replace
    }
}

public enum TextReplacer {
    private static let wordChar = "[\\p{L}\\p{N}_]"

    /// Applies every rule case-insensitively. A phrase that starts or ends with
    /// a word character only matches on a word boundary, so "cat" never
    /// rewrites "concatenate". Longer phrases win over their prefixes.
    public static func apply(_ rules: [Replacement], to text: String) -> String {
        var byKey: [String: String] = [:]
        var phrases: [String] = []
        for rule in rules {
            let find = rule.find.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !find.isEmpty else { continue }
            let key = find.lowercased()
            if byKey[key] == nil {
                byKey[key] = rule.replace
                phrases.append(find)
            }
        }
        guard !phrases.isEmpty, !text.isEmpty else { return text }

        let alternatives = phrases
            .sorted { $0.count > $1.count }
            .map(boundedPattern)
            .joined(separator: "|")
        guard let regex = try? NSRegularExpression(pattern: "(\(alternatives))", options: [.caseInsensitive]) else {
            return text
        }

        let ns = text as NSString
        var result = ""
        var cursor = 0
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let range = match.range
            result += ns.substring(with: NSRange(location: cursor, length: range.location - cursor))
            let matched = ns.substring(with: range)
            result += byKey[matched.lowercased()] ?? matched
            cursor = range.location + range.length
        }
        result += ns.substring(from: cursor)
        return result
    }

    private static func boundedPattern(_ phrase: String) -> String {
        let escaped = NSRegularExpression.escapedPattern(for: phrase)
        let startsWithWord = phrase.first.map(isWordCharacter) ?? false
        let endsWithWord = phrase.last.map(isWordCharacter) ?? false
        return (startsWithWord ? "(?<!\(wordChar))" : "") + escaped + (endsWithWord ? "(?!\(wordChar))" : "")
    }

    private static func isWordCharacter(_ c: Character) -> Bool {
        c == "_" || c.isLetter || c.isNumber
    }
}
