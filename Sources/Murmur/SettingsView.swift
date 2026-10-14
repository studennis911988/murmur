import AppKit
import AVFoundation
import Carbon.HIToolbox
import MurmurCore
import Speech
import SwiftUI

enum SettingsTab: String, CaseIterable, Identifiable {
    case setup, general, transcription, ai, vocabulary, history
    var id: String { rawValue }

    var title: String {
        switch self {
        case .setup: return "Setup"
        case .general: return "General"
        case .transcription: return "Transcription"
        case .ai: return "AI"
        case .vocabulary: return "Vocabulary"
        case .history: return "History"
        }
    }

    var symbol: String {
        switch self {
        case .setup: return "checklist"
        case .general: return "gearshape"
        case .transcription: return "waveform"
        case .ai: return "sparkles"
        case .vocabulary: return "character.book.closed"
        case .history: return "clock.arrow.circlepath"
        }
    }
}

struct SettingsView: View {
    let dictation: DictationController
    @EnvironmentObject var runtime: RuntimeState

    var body: some View {
        NavigationSplitView {
            List(SettingsTab.allCases, selection: Binding<SettingsTab?>(
                get: { runtime.settingsTab },
                set: { if let tab = $0 { runtime.settingsTab = tab } }
            )) { tab in
                Label(tab.title, systemImage: tab.symbol).tag(tab)
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 180, max: 220)
        } detail: {
            content(for: runtime.settingsTab)
                .navigationTitle(runtime.settingsTab.title)
        }
        .frame(minWidth: 720, minHeight: 520)
    }

    @ViewBuilder
    private func content(for tab: SettingsTab) -> some View {
        switch tab {
        case .setup: SetupTab()
        case .general: GeneralTab()
        case .transcription: TranscriptionTab()
        case .ai: AITab()
        case .vocabulary: VocabularyTab()
        case .history: HistoryTab(dictation: dictation)
        }
    }
}

/// Section footer, left-aligned like System Settings.
private struct Footer: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Setup

private struct SetupTab: View {
    @EnvironmentObject var settings: Settings
    @EnvironmentObject var runtime: RuntimeState
    @State private var microphone = Permissions.microphone
    @State private var speech = Permissions.speech
    @State private var dictationEnabled = SystemDictation.isEnabled
    private let refresh = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        Form {
            Section {
                Text("Murmur types what you say into any app. Grant these permissions once:")
                    .foregroundStyle(.secondary)
                PermissionRow(
                    title: "Microphone", detail: "To hear you while you dictate.",
                    granted: microphone == .authorized,
                    action: microphone == .notDetermined ? "Allow" : "Open Settings"
                ) {
                    if microphone == .notDetermined {
                        Task { _ = await Permissions.ensureMicrophone(); microphone = Permissions.microphone }
                    } else {
                        Permissions.open(.microphone)
                    }
                }
                PermissionRow(
                    title: "Accessibility", detail: "To paste into the app you're using and read the text around the cursor.",
                    granted: runtime.accessibilityTrusted, action: "Open Settings"
                ) {
                    Accessibility.requestTrust()
                    Permissions.open(.accessibility)
                }
                if settings.engine == .apple {
                    PermissionRow(
                        title: "macOS Dictation", detail: "Apple's speech engine only runs with Dictation switched on (System Settings → Keyboard → Dictation).",
                        granted: dictationEnabled, action: "Open Keyboard Settings"
                    ) {
                        SystemDictation.openSettings()
                    }
                    PermissionRow(
                        title: "Speech Recognition", detail: "For Apple's built-in speech engine.",
                        granted: speech == .authorized,
                        action: speech == .notDetermined ? "Allow" : "Open Settings"
                    ) {
                        if speech == .notDetermined {
                            Task { _ = await Permissions.ensureSpeechRecognition(); speech = Permissions.speech }
                        } else {
                            Permissions.open(.speechRecognition)
                        }
                    }
                }
            }
            Section("How to dictate") {
                if settings.holdKey != .off {
                    Label("Hold **\(settings.holdKey.title)**, speak, and let go.", systemImage: "hand.point.down")
                }
                if let hotkey = settings.dictateHotkey {
                    Label("Or press **\(hotkey.display)** to start and again to finish. Holding it works as push-to-talk too.", systemImage: "keyboard")
                }
                if let hotkey = settings.editHotkey {
                    Label("Select text and press **\(hotkey.display)**, then say how to change it (needs Claude).", systemImage: "wand.and.stars")
                }
                Label("Press **Esc** to cancel. Everything you dictate is in **History**.", systemImage: "escape")
            }
            Section {
                Text("If you rebuild Murmur from source, macOS treats the new build as a different app: switch Murmur off and on again under Accessibility.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                HStack {
                    Spacer()
                    Button(settings.hasCompletedOnboarding ? "Done" : "Get Started") {
                        settings.hasCompletedOnboarding = true
                        runtime.settingsTab = .general
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
        .formStyle(.grouped)
        .onReceive(refresh) { _ in
            microphone = Permissions.microphone
            speech = Permissions.speech
            dictationEnabled = SystemDictation.isEnabled
            runtime.accessibilityTrusted = Accessibility.isTrusted
        }
    }
}

private struct PermissionRow: View {
    let title: String
    let detail: String
    let granted: Bool
    let action: String
    let perform: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .foregroundStyle(granted ? Color.green : Color.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).fontWeight(.medium)
                Text(detail).font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            if granted {
                Text("Granted").foregroundStyle(.secondary)
            } else {
                Button(action, action: perform)
            }
        }
    }
}

// MARK: - General

private struct GeneralTab: View {
    @EnvironmentObject var settings: Settings
    @EnvironmentObject var runtime: RuntimeState
    @State private var launchAtLogin = LaunchAtLogin.isEnabled
    @State private var launchError: String?

    var body: some View {
        Form {
            Section("Shortcuts") {
                LabeledContent("Dictate") { HotkeyField(hotkey: $settings.dictateHotkey) }
                LabeledContent("Edit selection by voice") { HotkeyField(hotkey: $settings.editHotkey) }
                LabeledContent("Paste last transcript") { HotkeyField(hotkey: $settings.pasteLastHotkey) }
                Picker("Hold to talk", selection: $settings.holdKey) {
                    ForEach(HoldKey.allCases) { Text($0.title).tag($0) }
                }
                if settings.holdKey == .fn {
                    Text("Set System Settings → Keyboard → \"Press 🌐 key to\" to \"Do Nothing\" so macOS doesn't also react to Fn.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                ForEach(runtime.hotkeyIssues, id: \.self) { issue in
                    Label(issue, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                }
            }
            Section("While dictating") {
                Toggle("Show live transcript (Apple Speech)", isOn: $settings.showLivePreview)
                Toggle("Play start and stop sounds", isOn: $settings.playSounds)
                Picker("Stop automatically after silence", selection: $settings.autoStopSilence) {
                    Text("Never").tag(0.0)
                    Text("5 seconds").tag(5.0)
                    Text("10 seconds").tag(10.0)
                    Text("30 seconds").tag(30.0)
                    Text("2 minutes").tag(120.0)
                }
            }
            Section("Inserting text") {
                Toggle("Fit spacing and capitalization to the text around the cursor", isOn: $settings.smartSpacing)
                Toggle("Restore my clipboard after pasting", isOn: $settings.preserveClipboard)
            }
            Section {
                Toggle("Open Murmur at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in
                        guard enabled != LaunchAtLogin.isEnabled else { return }
                        launchError = LaunchAtLogin.set(enabled)
                        launchAtLogin = LaunchAtLogin.isEnabled
                    }
                if let launchError {
                    Text(launchError).font(.callout).foregroundStyle(.orange)
                }
            }
        }
        .formStyle(.grouped)
    }
}

/// Click, then press the new shortcut. Esc cancels.
struct HotkeyField: View {
    @Binding var hotkey: Hotkey?
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        HStack(spacing: 6) {
            Button(action: { recording ? stopRecording() : startRecording() }) {
                Text(recording ? "Press a shortcut…" : (hotkey?.display ?? "None"))
                    .frame(minWidth: 120)
            }
            if hotkey != nil, !recording {
                Button { hotkey = nil } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help("Remove shortcut")
            }
        }
        .onDisappear { stopRecording() }
    }

    private func startRecording() {
        recording = true
        HotkeyCenter.shared.suspend()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
            if event.keyCode == UInt16(kVK_Escape), modifiers.isEmpty {
                stopRecording()
            } else if let recorded = Hotkey(event: event) {
                hotkey = recorded
                stopRecording()
            } else {
                NSSound.beep()
            }
            return nil
        }
    }

    private func stopRecording() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if recording { HotkeyCenter.shared.resume() }
        recording = false
    }
}

// MARK: - Transcription

private struct TranscriptionTab: View {
    @EnvironmentObject var settings: Settings

    var body: some View {
        Form {
            Section {
                Picker("Engine", selection: $settings.engine) {
                    ForEach(EngineKind.allCases) { Text($0.title).tag($0) }
                }
                Picker("Language", selection: $settings.language) {
                    ForEach(languageOptions, id: \.code) { Text($0.name).tag($0.code) }
                }
            }
            switch settings.engine {
            case .apple: appleSection
            case .cloud: cloudSection
            case .whisperCpp: whisperSection
            }
        }
        .formStyle(.grouped)
    }

    private var appleSection: some View {
        Section("Apple Speech") {
            Toggle("Keep audio on this Mac (on-device recognition only)", isOn: $settings.appleOnDeviceOnly)
            let recognizer = SFSpeechRecognizer(locale: settings.speechLocale)
            if recognizer == nil {
                Label("\(settings.speechLocale.identifier) isn't supported by Apple Speech.", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            } else if recognizer?.supportsOnDeviceRecognition == false {
                Label("On-device recognition for \(settings.speechLocale.identifier) isn't installed. Add the language under System Settings → Keyboard → Dictation, or allow Apple's servers.", systemImage: "info.circle")
                    .foregroundStyle(.secondary)
            } else {
                Label("Free, private, and streams a live preview while you speak.", systemImage: "checkmark.seal")
                    .foregroundStyle(.secondary)
            }
            if !SystemDictation.isEnabled {
                HStack {
                    Label("macOS Dictation is off, which Apple Speech requires.", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                    Spacer()
                    Button("Open Keyboard Settings") { SystemDictation.openSettings() }
                }
            }
            let installed = SystemDictation.installedOnDeviceLanguages
            if !installed.isEmpty {
                LabeledContent("On-device languages", value: installed.joined(separator: ", "))
            }
        }
    }

    private var cloudSection: some View {
        Section {
            HStack {
                Text("Preset")
                Spacer()
                ForEach(CloudPreset.all) { preset in
                    Button(preset.name) {
                        settings.cloudBaseURL = preset.baseURL
                        settings.cloudModel = preset.model
                    }
                }
            }
            TextField("Base URL", text: $settings.cloudBaseURL)
            TextField("Model", text: $settings.cloudModel)
            LabeledContent("API key") { APIKeyField(account: .cloudTranscription, placeholder: "sk-… or gsk_…") }
        } header: {
            Text("Whisper API")
        } footer: {
            Footer("Any OpenAI-compatible /audio/transcriptions endpoint. Your audio is uploaded to this provider. Groq's whisper-large-v3-turbo is fast and inexpensive; OpenAI's gpt-4o-transcribe is very accurate.")
        }
    }

    private var whisperSection: some View {
        Section {
            let models = LocalModels.available()
            Picker("Model", selection: $settings.whisperModel) {
                if !models.contains(where: { $0.path == settings.whisperModel }) {
                    Text(settings.whisperModel.isEmpty ? "None" : (settings.whisperModel as NSString).lastPathComponent)
                        .tag(settings.whisperModel)
                }
                ForEach(models, id: \.path) { Text($0.lastPathComponent).tag($0.path) }
            }
            Picker("Model for English", selection: $settings.englishModel) {
                Text("Same as above").tag("")
                if !settings.englishModel.isEmpty, !models.contains(where: { $0.path == settings.englishModel }) {
                    Text((settings.englishModel as NSString).lastPathComponent).tag(settings.englishModel)
                }
                ForEach(models, id: \.path) { Text($0.lastPathComponent).tag($0.path) }
            }
            HStack {
                Button("Other Model…") { choose { settings.whisperModel = $0 } }
                Button("Show Models Folder") {
                    try? FileManager.default.createDirectory(at: LocalModels.directory, withIntermediateDirectories: true)
                    NSWorkspace.shared.open(LocalModels.directory)
                }
            }
            HStack {
                TextField("whisper-cli", text: $settings.whisperBinary)
                Button("Choose…") { choose { settings.whisperBinary = $0 } }
            }
        } header: {
            Text("Local model (whisper.cpp)")
        } footer: {
            Footer("Runs fully offline with your own whisper.cpp install (`brew install whisper-cpp`). Put ggml models in the models folder. In eval/ on an M4 Pro: Breeze-ASR-25 was the most accurate for Taiwanese Mandarin and mixed Mandarin–English (it always runs as \"zh\", which also transcribes English well); Parakeet TDT v3 was the fastest and most accurate for English (used when the language is English). Whisper large-v3-turbo is a solid all-rounder. No live preview; the transcript arrives after you stop.")
        }
    }

    private func choose(_ apply: (String) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.showsHiddenFiles = true
        if panel.runModal() == .OK, let url = panel.url { apply(url.path) }
    }
}

struct APIKeyField: View {
    let account: Secrets.Account
    let placeholder: String
    @State private var draft = ""
    @State private var saved = false

    var body: some View {
        HStack {
            SecureField("API key", text: $draft, prompt: Text(saved ? "Saved in Keychain" : placeholder))
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 220)
                .onSubmit(save)
            Button("Save", action: save).disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
            if saved {
                Button("Remove") {
                    Secrets.set(nil, for: account)
                    saved = false
                }
            }
        }
        .onAppear { saved = Secrets.get(account) != nil }
    }

    private func save() {
        guard !draft.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        Secrets.set(draft, for: account)
        draft = ""
        saved = Secrets.get(account) != nil
    }
}

// MARK: - AI

private struct AITab: View {
    @EnvironmentObject var settings: Settings

    var body: some View {
        Form {
            Section {
                LabeledContent("Anthropic API key") { APIKeyField(account: .anthropic, placeholder: "sk-ant-…") }
                Picker("Model", selection: $settings.claudeModel) {
                    ForEach(ClaudeModelOption.all) { Text("\($0.id) — \($0.note)").tag($0.id) }
                }
                Picker("Effort", selection: $settings.claudeEffort) {
                    Text("Low — quickest").tag("low")
                    Text("Medium").tag("medium")
                    Text("High — most careful").tag("high")
                }
            } header: {
                Text("Claude")
            } footer: {
                Footer("Used for AI polish and for editing selected text by voice. The transcript (and, for edits, the selected text) is sent to Anthropic.")
            }

            Section("AI polish for dictation") {
                Picker("Mode", selection: Binding(get: { settings.polishMode }, set: { settings.polishMode = $0 })) {
                    Text("Off — insert exactly what was heard").tag(PolishMode.off)
                    Text("Clean up").tag(PolishMode.cleanup)
                    ForEach(settings.customModes) { Text($0.name).tag(PolishMode.custom($0.id)) }
                }
                Toggle("Remove filler words", isOn: $settings.cleanupRemoveFillers)
                Toggle("Break into paragraphs", isOn: $settings.cleanupParagraphs)
                Toggle("Format spoken lists as lists", isOn: $settings.cleanupLists)
                Toggle("Tell Claude which app and window you're typing into", isOn: $settings.useAppContext)
            }

            Section {
                ForEach($settings.customModes) { $mode in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            TextField("Name", text: $mode.name, prompt: Text("Mode name"))
                                .labelsHidden()
                                .textFieldStyle(.plain)
                                .font(.headline)
                            Button(role: .destructive) {
                                if settings.polishMode == .custom(mode.id) { settings.polishMode = .off }
                                settings.customModes.removeAll { $0.id == mode.id }
                            } label: { Image(systemName: "trash") }
                                .buttonStyle(.borderless)
                        }
                        TextEditor(text: $mode.instructions)
                            .font(.callout)
                            .frame(minHeight: 54)
                            .scrollContentBackground(.hidden)
                            .padding(4)
                            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))
                    }
                    .padding(.vertical, 4)
                }
                Button("Add Mode") {
                    settings.customModes.append(CustomMode(name: "New mode", instructions: "Describe how Claude should transform your dictation."))
                }
            } header: {
                Text("Custom modes")
            } footer: {
                Footer("A mode adds your own instructions on top of clean-up — e.g. \"write it as a polite email\" or \"translate to English\". Pick the active mode here or from the menu bar.")
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Vocabulary

private struct VocabularyTab: View {
    @EnvironmentObject var settings: Settings

    var body: some View {
        Form {
            Section {
                TextEditor(text: $settings.vocabulary)
                    .font(.body)
                    .frame(minHeight: 80)
                    .scrollContentBackground(.hidden)
            } header: {
                Text("Dictionary")
            } footer: {
                Footer("Names, jargon, and product terms you want spelled right, separated by commas or new lines. Every engine and Claude get them as hints.")
            }

            Section {
                ForEach($settings.replacements) { $rule in
                    HStack {
                        TextField("When I say", text: $rule.find, prompt: Text("When I say…"))
                            .labelsHidden()
                        Image(systemName: "arrow.right").foregroundStyle(.secondary)
                        TextField("Insert", text: $rule.replace, prompt: Text("Insert…"))
                            .labelsHidden()
                        Button {
                            settings.replacements.removeAll { $0.id == rule.id }
                        } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless)
                    }
                }
                Button("Add Replacement") {
                    settings.replacements.append(Replacement(find: "", replace: ""))
                }
            } header: {
                Text("Replacements")
            } footer: {
                Footer("Swaps a spoken phrase for fixed text after transcription, e.g. \"my email\" → your address. Matching ignores case and whole words only.")
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - History

private struct HistoryTab: View {
    let dictation: DictationController
    @EnvironmentObject var settings: Settings
    @EnvironmentObject var history: HistoryStore
    @State private var confirmClear = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Toggle("Keep history", isOn: $settings.historyEnabled)
                Spacer()
                Button("Show Files") { NSWorkspace.shared.open(history.directory) }
                Button("Clear All…") { confirmClear = true }.disabled(history.entries.isEmpty)
            }
            .padding(12)
            Divider()
            if history.entries.isEmpty {
                ContentUnavailableView("No dictations yet", systemImage: "waveform", description: Text("Everything you dictate shows up here."))
            } else {
                List(history.entries) { entry in
                    HistoryRow(entry: entry, dictation: dictation)
                }
            }
        }
        .confirmationDialog("Delete all history and saved recordings?", isPresented: $confirmClear) {
            Button("Delete All", role: .destructive) { history.clear() }
        }
    }
}

private struct HistoryRow: View {
    let entry: HistoryEntry
    let dictation: DictationController
    @EnvironmentObject var history: HistoryStore

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(entry.date, format: .dateTime.month(.abbreviated).day().hour().minute())
                if let app = entry.appName { Text("· \(app)") }
                if let mode = entry.mode { Text("· \(mode)") }
                Text("· \(Int(entry.duration.rounded()))s")
                Spacer()
                if entry.failed {
                    Button("Retry") { dictation.retry(entry) }.disabled(entry.audioFile == nil)
                } else {
                    Button("Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(entry.text, forType: .string)
                    }
                }
                Button { history.delete(entry.id) } label: { Image(systemName: "trash") }
                    .buttonStyle(.borderless)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            if let error = entry.error {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).font(.callout)
            } else {
                Text(entry.text).textSelection(.enabled)
                if let raw = entry.raw {
                    DisclosureGroup("Heard") {
                        Text(raw).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                    .font(.callout)
                }
            }
        }
        .padding(.vertical, 4)
    }
}
