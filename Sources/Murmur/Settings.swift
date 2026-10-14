import AppKit
import Carbon.HIToolbox
import Combine
import MurmurCore

/// A global keyboard shortcut in Carbon terms (virtual key code + modifier mask).
struct Hotkey: Codable, Equatable, Hashable {
    var keyCode: UInt32
    var modifiers: UInt32
    var keyName: String

    static let dictate = Hotkey(keyCode: UInt32(kVK_Space), modifiers: UInt32(optionKey), keyName: "Space")
    static let edit = Hotkey(keyCode: UInt32(kVK_Space), modifiers: UInt32(optionKey | shiftKey), keyName: "Space")
    static let pasteLast = Hotkey(keyCode: UInt32(kVK_ANSI_V), modifiers: UInt32(controlKey | optionKey), keyName: "V")
    static let escape = Hotkey(keyCode: UInt32(kVK_Escape), modifiers: 0, keyName: "Esc")

    var display: String {
        var s = ""
        if modifiers & UInt32(controlKey) != 0 { s += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { s += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { s += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { s += "⌘" }
        return s + keyName
    }

    init(keyCode: UInt32, modifiers: UInt32, keyName: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.keyName = keyName
    }

    /// Builds a hotkey from a key press in the shortcut recorder.
    init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var mods: UInt32 = 0
        if flags.contains(.control) { mods |= UInt32(controlKey) }
        if flags.contains(.option) { mods |= UInt32(optionKey) }
        if flags.contains(.shift) { mods |= UInt32(shiftKey) }
        if flags.contains(.command) { mods |= UInt32(cmdKey) }
        let code = UInt32(event.keyCode)
        let name = Hotkey.specialKeyNames[Int(code)]
            ?? event.charactersIgnoringModifiers?.uppercased().trimmingCharacters(in: .whitespaces)
            ?? "?"
        let isFunctionKey = name.hasPrefix("F") && name.count > 1 && Int(name.dropFirst()) != nil
        // A bare letter would hijack normal typing.
        guard mods != 0 || isFunctionKey, !name.isEmpty else { return nil }
        self.init(keyCode: code, modifiers: mods, keyName: name)
    }

    static let specialKeyNames: [Int: String] = [
        kVK_Space: "Space", kVK_Return: "Return", kVK_Tab: "Tab", kVK_Delete: "Delete", kVK_Escape: "Esc",
        kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_DownArrow: "↓", kVK_UpArrow: "↑",
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
        kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
        kVK_F13: "F13", kVK_F14: "F14", kVK_F15: "F15", kVK_F16: "F16", kVK_F17: "F17", kVK_F18: "F18",
        kVK_F19: "F19",
    ]
}

/// A modifier key that records while held (push-to-talk).
enum HoldKey: String, Codable, CaseIterable, Identifiable {
    case off, rightOption, rightCommand, rightControl, fn

    var id: String { rawValue }

    var title: String {
        switch self {
        case .off: return "Off"
        case .rightOption: return "Right Option (⌥)"
        case .rightCommand: return "Right Command (⌘)"
        case .rightControl: return "Right Control (⌃)"
        case .fn: return "Fn (🌐)"
        }
    }

    var keyCode: UInt16? {
        switch self {
        case .off: return nil
        case .rightOption: return UInt16(kVK_RightOption)
        case .rightCommand: return UInt16(kVK_RightCommand)
        case .rightControl: return UInt16(kVK_RightControl)
        case .fn: return UInt16(kVK_Function)
        }
    }

    /// Device-dependent flag bit for the specific (right-hand) key, from IOKit's
    /// NX_DEVICER*KEYMASK, so holding the left key never counts.
    func isDown(_ flags: NSEvent.ModifierFlags) -> Bool {
        switch self {
        case .off: return false
        case .rightOption: return flags.rawValue & 0x40 != 0
        case .rightCommand: return flags.rawValue & 0x10 != 0
        case .rightControl: return flags.rawValue & 0x2000 != 0
        case .fn: return flags.contains(.function)
        }
    }
}

enum EngineKind: String, Codable, CaseIterable, Identifiable {
    case apple, cloud, whisperCpp

    var id: String { rawValue }

    var title: String {
        switch self {
        case .apple: return "Apple Speech (built in)"
        case .cloud: return "Whisper API (OpenAI, Groq, …)"
        case .whisperCpp: return "whisper.cpp (local model)"
        }
    }
}

/// An OpenAI-compatible `/audio/transcriptions` endpoint.
struct CloudPreset: Identifiable, Hashable {
    let id: String
    let name: String
    let baseURL: String
    let model: String

    static let all = [
        CloudPreset(id: "groq", name: "Groq", baseURL: "https://api.groq.com/openai/v1", model: "whisper-large-v3-turbo"),
        CloudPreset(id: "openai", name: "OpenAI", baseURL: "https://api.openai.com/v1", model: "gpt-4o-transcribe"),
    ]
}

/// What happens to a transcript before it is pasted.
struct CustomMode: Codable, Equatable, Hashable, Identifiable {
    var id = UUID()
    var name: String
    var instructions: String

    static let examples = [
        CustomMode(name: "Email", instructions: "Format the dictation as a complete email with a greeting, short paragraphs, and a sign-off. Keep the speaker's content; do not invent details."),
        CustomMode(name: "Bullet notes", instructions: "Turn the dictation into concise bullet points grouped by topic."),
        CustomMode(name: "Prompt", instructions: "Rewrite the dictation as a clear, well-structured prompt for an AI assistant, preserving every requirement the speaker mentioned."),
    ]
}

enum PolishMode: Equatable, Hashable {
    case off, cleanup, custom(UUID)

    init(storage: String) {
        switch storage {
        case "off": self = .off
        case "cleanup": self = .cleanup
        default: self = UUID(uuidString: storage).map(PolishMode.custom) ?? .off
        }
    }

    var storage: String {
        switch self {
        case .off: return "off"
        case .cleanup: return "cleanup"
        case .custom(let id): return id.uuidString
        }
    }
}

struct ClaudeModelOption: Identifiable, Hashable {
    let id: String
    let note: String

    static let all = [
        ClaudeModelOption(id: "claude-opus-5-5", note: "best quality"),
        ClaudeModelOption(id: "claude-sonnet-5-5", note: "balanced"),
        ClaudeModelOption(id: "claude-haiku-5-5", note: "fastest, cheapest"),
    ]
}

/// Persistent preferences. Every property writes through to UserDefaults.
@MainActor
final class Settings: ObservableObject {
    static let shared = Settings()

    private let defaults = UserDefaults.standard
    /// The CLI flips this off so per-run overrides never touch saved settings.
    var persistChanges = true

    @Published var dictateHotkey: Hotkey? { didSet { store(dictateHotkey, "dictateHotkey") } }
    @Published var editHotkey: Hotkey? { didSet { store(editHotkey, "editHotkey") } }
    @Published var pasteLastHotkey: Hotkey? { didSet { store(pasteLastHotkey, "pasteLastHotkey") } }
    @Published var holdKey: HoldKey { didSet { store(holdKey, "holdKey") } }

    @Published var engine: EngineKind { didSet { store(engine, "engine") } }
    /// "auto" or a BCP-47 tag such as "en-US" or "zh-TW".
    @Published var language: String { didSet { store(language, "language") } }
    @Published var appleOnDeviceOnly: Bool { didSet { store(appleOnDeviceOnly, "appleOnDeviceOnly") } }
    @Published var cloudBaseURL: String { didSet { store(cloudBaseURL, "cloudBaseURL") } }
    @Published var cloudModel: String { didSet { store(cloudModel, "cloudModel") } }
    @Published var whisperBinary: String { didSet { store(whisperBinary, "whisperBinary") } }
    @Published var whisperModel: String { didSet { store(whisperModel, "whisperModel") } }
    /// Optional faster model used when the language is English (e.g. Parakeet).
    @Published var englishModel: String { didSet { store(englishModel, "englishModel") } }

    @Published var polishModeStorage: String { didSet { store(polishModeStorage, "polishMode") } }
    @Published var claudeModel: String { didSet { store(claudeModel, "claudeModel") } }
    @Published var claudeEffort: String { didSet { store(claudeEffort, "claudeEffort") } }
    @Published var cleanupRemoveFillers: Bool { didSet { store(cleanupRemoveFillers, "cleanupRemoveFillers") } }
    @Published var cleanupParagraphs: Bool { didSet { store(cleanupParagraphs, "cleanupParagraphs") } }
    @Published var cleanupLists: Bool { didSet { store(cleanupLists, "cleanupLists") } }
    @Published var customModes: [CustomMode] { didSet { store(customModes, "customModes") } }
    @Published var useAppContext: Bool { didSet { store(useAppContext, "useAppContext") } }

    @Published var vocabulary: String { didSet { store(vocabulary, "vocabulary") } }
    @Published var replacements: [Replacement] { didSet { store(replacements, "replacements") } }

    @Published var smartSpacing: Bool { didSet { store(smartSpacing, "smartSpacing") } }
    @Published var preserveClipboard: Bool { didSet { store(preserveClipboard, "preserveClipboard") } }
    @Published var playSounds: Bool { didSet { store(playSounds, "playSounds") } }
    @Published var showLivePreview: Bool { didSet { store(showLivePreview, "showLivePreview") } }
    /// Seconds of continuous silence that end a recording; 0 disables.
    @Published var autoStopSilence: Double { didSet { store(autoStopSilence, "autoStopSilence") } }
    @Published var historyEnabled: Bool { didSet { store(historyEnabled, "historyEnabled") } }
    @Published var hasCompletedOnboarding: Bool { didSet { store(hasCompletedOnboarding, "hasCompletedOnboarding") } }

    private init() {
        func load<T: Codable>(_ key: String, _ fallback: T) -> T {
            guard let data = UserDefaults.standard.data(forKey: key),
                  let value = try? JSONDecoder().decode(T.self, from: data) else { return fallback }
            return value
        }
        dictateHotkey = load("dictateHotkey", Hotkey.dictate)
        editHotkey = load("editHotkey", Hotkey.edit)
        pasteLastHotkey = load("pasteLastHotkey", Hotkey.pasteLast)
        holdKey = load("holdKey", HoldKey.rightOption)
        engine = load("engine", EngineKind.apple)
        language = load("language", "auto")
        appleOnDeviceOnly = load("appleOnDeviceOnly", true)
        cloudBaseURL = load("cloudBaseURL", CloudPreset.all[0].baseURL)
        cloudModel = load("cloudModel", CloudPreset.all[0].model)
        whisperBinary = load("whisperBinary", "/opt/homebrew/bin/whisper-cli")
        whisperModel = load("whisperModel", "")
        englishModel = load("englishModel", "")
        polishModeStorage = load("polishMode", "off")
        claudeModel = load("claudeModel", ClaudeModelOption.all[0].id)
        claudeEffort = load("claudeEffort", "low")
        cleanupRemoveFillers = load("cleanupRemoveFillers", true)
        cleanupParagraphs = load("cleanupParagraphs", true)
        cleanupLists = load("cleanupLists", true)
        customModes = load("customModes", CustomMode.examples)
        useAppContext = load("useAppContext", true)
        vocabulary = load("vocabulary", "")
        replacements = load("replacements", [Replacement]())
        smartSpacing = load("smartSpacing", true)
        preserveClipboard = load("preserveClipboard", true)
        playSounds = load("playSounds", true)
        showLivePreview = load("showLivePreview", true)
        autoStopSilence = load("autoStopSilence", 30.0)
        historyEnabled = load("historyEnabled", true)
        hasCompletedOnboarding = load("hasCompletedOnboarding", false)
    }

    private func store<T: Codable>(_ value: T, _ key: String) {
        guard persistChanges else { return }
        if let data = try? JSONEncoder().encode(value) {
            defaults.set(data, forKey: key)
        }
    }

    var polishMode: PolishMode {
        get { PolishMode(storage: polishModeStorage) }
        set { polishModeStorage = newValue.storage }
    }

    var vocabularyTerms: [String] { Vocabulary.terms(from: vocabulary) }

    var cleanupStyle: CleanupStyle {
        CleanupStyle(removeFillers: cleanupRemoveFillers, paragraphs: cleanupParagraphs, lists: cleanupLists)
    }

    /// Name and extra instructions of the active polish mode, or nil when off.
    var activePolish: (name: String, instructions: String?)? {
        switch polishMode {
        case .off: return nil
        case .cleanup: return ("Clean up", nil)
        case .custom(let id):
            guard let mode = customModes.first(where: { $0.id == id }) else { return nil }
            return (mode.name, mode.instructions)
        }
    }

    /// The recognizer locale for Apple Speech.
    var speechLocale: Locale {
        language == "auto" ? Locale.current : Locale(identifier: language)
    }

    /// Whether Chinese output should be in Traditional characters: from the
    /// chosen language, or for auto-detect from the user's preferred languages.
    var prefersTraditionalChinese: Bool {
        if language != "auto" { return ChineseScript.usesTraditional(language) }
        guard let chinese = Locale.preferredLanguages.first(where: { $0.lowercased().hasPrefix("zh") || $0.lowercased().hasPrefix("yue") }) else {
            return ["TW", "HK", "MO"].contains(Locale.current.region?.identifier ?? "")
        }
        return ChineseScript.usesTraditional(chinese)
    }

    /// Applies the user's Chinese script to a transcript.
    func normalizingScript(_ text: String) -> String {
        prefersTraditionalChinese ? ChineseScript.traditionalIfSimplified(text) : text
    }

    /// ISO-639-1 code for Whisper-style engines, or nil for auto-detect.
    var whisperLanguage: String? {
        guard language != "auto" else { return nil }
        return String(language.prefix(while: { $0 != "-" && $0 != "_" })).lowercased()
    }
}

/// Languages offered in the picker; Apple Speech availability varies per Mac.
let languageOptions: [(code: String, name: String)] = [
    ("auto", "System language / auto-detect"),
    ("en-US", "English (US)"), ("en-GB", "English (UK)"), ("zh-TW", "中文（台灣）"), ("zh-CN", "中文（中国大陆）"),
    ("ja-JP", "日本語"), ("ko-KR", "한국어"), ("es-ES", "Español"), ("fr-FR", "Français"), ("de-DE", "Deutsch"),
    ("it-IT", "Italiano"), ("pt-BR", "Português (Brasil)"), ("nl-NL", "Nederlands"), ("sv-SE", "Svenska"),
    ("ru-RU", "Русский"), ("uk-UA", "Українська"), ("pl-PL", "Polski"), ("tr-TR", "Türkçe"), ("hi-IN", "हिन्दी"),
    ("vi-VN", "Tiếng Việt"), ("th-TH", "ไทย"), ("id-ID", "Bahasa Indonesia"),
]
