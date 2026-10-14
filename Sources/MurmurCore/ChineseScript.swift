import Foundation

/// Keeps Chinese output in the script the user writes. Whisper models often
/// answer Taiwanese Mandarin in Simplified characters; converting the whole
/// text is only safe when it really is Simplified, because some characters
/// (周, 台, 里, 后…) are also correct Traditional and appear in names.
public enum ChineseScript {
    /// Language tags conventionally written in Traditional characters.
    public static func usesTraditional(_ tag: String) -> Bool {
        let tag = tag.lowercased().replacingOccurrences(of: "_", with: "-")
        return ["zh-tw", "zh-hk", "zh-mo", "zh-hant", "yue"].contains { tag.hasPrefix($0) }
    }

    /// Simplified forms that are also valid Traditional characters. Changing
    /// only these is not evidence that the text is Simplified.
    static let sharedForms: Set<Character> = Set("周里台后干面系只准范制松谷斗云表志余采几才姜致并征咸布占回御朴沈秋舍卷吊伙克恶冬困奸念夸尸挂板朱杰汇灶症秘胡")

    private static let toTraditionalTransform = StringTransform("Hans-Hant")

    /// Taiwan-standard forms where ICU's generic Traditional output differs.
    private static let taiwanForms: [Character: Character] = [
        "裏": "裡", "着": "著", "衆": "眾", "綫": "線", "爲": "為", "啓": "啟", "麪": "麵", "峯": "峰",
    ]

    /// Converts `text` to Traditional when it contains Simplified-only
    /// characters; otherwise returns it unchanged.
    public static func traditionalIfSimplified(_ text: String) -> String {
        guard text.unicodeScalars.contains(where: { (0x4E00...0x9FFF).contains($0.value) }),
              let converted = text.applyingTransform(toTraditionalTransform, reverse: false),
              converted != text else { return text }
        let original = Array(text)
        let changed = Array(converted)
        guard original.count == changed.count else { return text }
        let simplifiedOnly = zip(original, changed).contains { $0 != $1 && !sharedForms.contains($0) }
        guard simplifiedOnly else { return text }
        return String(changed.map { taiwanForms[$0] ?? $0 })
    }
}
