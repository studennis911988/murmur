import Foundation
import MurmurCore

var failures = 0
var passes = 0

func expect(_ actual: String, _ expected: String, _ name: String, line: Int = #line) {
    if actual == expected {
        passes += 1
    } else {
        failures += 1
        print("FAIL [\(line)] \(name)\n  expected: \(expected.debugDescription)\n  actual:   \(actual.debugDescription)")
    }
}

func expect(_ condition: Bool, _ name: String, line: Int = #line) {
    if condition { passes += 1 } else { failures += 1; print("FAIL [\(line)] \(name)") }
}

// MARK: Text replacements

let rules = [
    Replacement(find: "my email", replace: "dennis@example.com"),
    Replacement(find: "cat", replace: "dog"),
    Replacement(find: "New York", replace: "NY"),
    Replacement(find: "New York City", replace: "NYC"),
    Replacement(find: "c++", replace: "C++"),
]
expect(TextReplacer.apply(rules, to: "Send it to My Email please."), "Send it to dennis@example.com please.", "case-insensitive phrase")
expect(TextReplacer.apply(rules, to: "concatenate the cat"), "concatenate the dog", "word boundary")
expect(TextReplacer.apply(rules, to: "I love New York City and New York."), "I love NYC and NY.", "longest phrase wins")
expect(TextReplacer.apply(rules, to: "I write c++ daily"), "I write C++ daily", "regex metacharacters escaped")
expect(TextReplacer.apply([], to: "unchanged"), "unchanged", "no rules")
expect(TextReplacer.apply([Replacement(find: "  ", replace: "x")], to: "a b"), "a b", "blank rule ignored")
expect(TextReplacer.apply([Replacement(find: "price", replace: "$5 \\1")], to: "the price"), "the $5 \\1", "replacement is literal")

// MARK: Caret context

expect(CaretContext(before: "Hello there", after: "").continuesSentence, "mid-sentence")
expect(!CaretContext(before: "Done. ", after: "").continuesSentence, "after period")
expect(!CaretContext(before: "Line one\n", after: "").continuesSentence, "after newline")
expect(!CaretContext(before: "", after: "").continuesSentence, "empty field")
expect(!CaretContext(before: "He said \"stop.\" ", after: "").continuesSentence, "closing quote after period")
expect(CaretContext(before: "", after: "  word").textFollows, "text follows")
expect(!CaretContext(before: "", after: " \nnext line").textFollows, "newline ends following text")

// MARK: Smart spacing

let mid = CaretContext(before: "I think", after: "")
expect(SmartSpacing.shape("The plan works.", context: mid), " the plan works.", "lowercase common word mid-sentence")
expect(SmartSpacing.shape("Paris is lovely.", context: mid), " Paris is lovely.", "keep proper noun")
expect(SmartSpacing.shape("I agree.", context: mid), " I agree.", "keep I")
expect(SmartSpacing.shape("API calls fail.", context: mid), " API calls fail.", "keep acronym")
expect(SmartSpacing.shape("Hello world.", context: CaretContext(before: "Done.", after: "")), " Hello world.", "space after period")
expect(SmartSpacing.shape("Hello.", context: CaretContext(before: "Done. ", after: "")), "Hello.", "no double space")
expect(SmartSpacing.shape("big", context: CaretContext(before: "the ", after: "house")), "big ", "trailing space before word")
expect(SmartSpacing.shape("Big.", context: CaretContext(before: "the ", after: "house")), "Big ", "drop period when text follows")
expect(SmartSpacing.shape(", and more", context: CaretContext(before: "apples", after: "")), ", and more", "no space before comma")
expect(SmartSpacing.shape("Hello", context: CaretContext(before: "(", after: "")), "Hello", "no space after opener")
expect(SmartSpacing.shape("你好。", context: CaretContext(before: "我說", after: "")), "你好。", "no spaces around CJK")
expect(SmartSpacing.shape("The end.", context: nil), "The end.", "no context leaves text")

// MARK: Transcript cleanup

expect(TranscriptFilter.clean(" you ", likelySilence: true), "", "silence hallucination dropped")
expect(TranscriptFilter.clean("Thank you.", likelySilence: true), "", "thank you on silence dropped")
expect(TranscriptFilter.clean("Thank you.", likelySilence: false), "Thank you.", "real thank you kept")
expect(TranscriptFilter.clean("[BLANK_AUDIO] Hello   world [Music]", likelySilence: false), "Hello world", "annotations removed")
expect(TranscriptFilter.clean("(upbeat music)", likelySilence: false), "", "only annotation becomes empty")
expect(TranscriptFilter.clean("[TODO] write tests", likelySilence: false), "[TODO] write tests", "user brackets kept")
expect(TranscriptFilter.clean("First line\n  second line ", likelySilence: false), "First line\nsecond line", "lines trimmed")

// MARK: Vocabulary

expect(Vocabulary.terms(from: "Kubernetes, kubectl\nFigma; kubernetes, ,").joined(separator: "|"), "Kubernetes|kubectl|Figma", "terms deduplicated")

// MARK: WAV

let wav = WAVEncoder.encode(samples: [0, 1, -1, 2], sampleRate: 16000)
expect(wav.count == 44 + 8, "wav size")
expect(String(data: wav.prefix(4), encoding: .ascii) == "RIFF", "wav header")
let samples = wav.suffix(8).withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
expect(samples == [0, Int16.max, -Int16.max, Int16.max], "wav samples clamped")

// MARK: Prompts

let system = Prompts.cleanupSystem(style: CleanupStyle(), vocabulary: ["Figma"], instructions: "Write as an email.")
expect(system.contains("Figma") && system.contains("<mode>") && system.contains("never a request"), "cleanup prompt pieces")
let user = Prompts.cleanupUser(transcript: "hi", context: InsertionContext(appName: "Slack", caret: mid))
expect(user.contains("App: Slack") && user.contains("Continues a sentence: yes") && user.hasSuffix("</transcript>"), "cleanup user message")
expect(!Prompts.cleanupSystem(style: CleanupStyle(), vocabulary: [], instructions: "  ").contains("<mode>"), "blank mode ignored")

// MARK: Chinese script

expect(ChineseScript.traditionalIfSimplified("这个问题很简单"), "這個問題很簡單", "simplified converted")
expect(ChineseScript.traditionalIfSimplified("我们下周见"), "我們下周見", "simplified-only characters converted, shared forms kept")
expect(ChineseScript.traditionalIfSimplified("周杰倫在台北"), "周杰倫在台北", "shared forms alone untouched")
expect(ChineseScript.traditionalIfSimplified("我下周三要去台中"), "我下周三要去台中", "valid traditional untouched")
expect(ChineseScript.traditionalIfSimplified("這个 bug 在 API 里"), "這個 bug 在 API 里", "partly simplified with Latin")
expect(ChineseScript.traditionalIfSimplified("plain English"), "plain English", "non-Chinese untouched")
expect(ChineseScript.usesTraditional("zh-TW") && ChineseScript.usesTraditional("zh_Hant_HK") && !ChineseScript.usesTraditional("zh-CN"), "traditional tags")

print("\(passes) passed, \(failures) failed")
exit(failures == 0 ? 0 : 1)
