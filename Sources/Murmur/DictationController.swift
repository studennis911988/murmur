import AppKit
import MurmurCore

/// Runs one dictation at a time: capture context → record → transcribe →
/// optional Claude polish or edit → shape the text → paste.
@MainActor
final class DictationController: ObservableObject {
    enum Phase: Equatable { case idle, starting, recording, processing }
    enum Intent { case dictate, edit }
    enum Trigger { case toggleKey, holdKey, menu }

    @Published private(set) var phase: Phase = .idle

    let settings: Settings
    let history: HistoryStore
    let hud: HUDController

    private var recorder: AudioRecorder?
    private var session: TranscriptionSession?
    private var contextTask: Task<AppContext, Never>?
    private var work: Task<Void, Never>?
    private var intent: Intent = .dictate
    private var trigger: Trigger = .menu
    private var selection: String?
    private var stopRequested = false
    /// Bumped per dictation so a cancelled run can't touch the next one.
    private var generation = 0

    private var pressStartedRecording = false
    private var pressDate = Date.distantPast
    /// Holding the toggle shortcut at least this long makes it push-to-talk.
    private let holdThreshold: TimeInterval = 0.45

    init(settings: Settings, history: HistoryStore, hud: HUDController) {
        self.settings = settings
        self.history = history
        self.hud = hud
        hud.model.onStop = { [weak self] in self?.stop() }
        hud.model.onCancel = { [weak self] in self?.cancel() }
    }

    // MARK: Triggers

    /// Toggle shortcut pressed: tap to start, tap again to finish; or hold to talk.
    func shortcutPressed(_ intent: Intent) {
        pressDate = Date()
        switch phase {
        case .idle:
            pressStartedRecording = true
            start(intent, trigger: .toggleKey)
        case .starting, .recording:
            if trigger == .holdKey {
                // Pressing ⌥Space while holding Right ⌥ (which already started
                // a hold recording) means "switch to toggle", not "stop".
                trigger = .toggleKey
                pressStartedRecording = true
                return
            }
            pressStartedRecording = false
            stop()
        case .processing:
            NSSound.beep()
        }
    }

    func shortcutReleased() {
        defer { pressStartedRecording = false }
        guard pressStartedRecording, trigger == .toggleKey,
              Date().timeIntervalSince(pressDate) >= holdThreshold else { return }
        stop()
    }

    func holdBegan() {
        if phase == .idle { start(.dictate, trigger: .holdKey) }
    }

    func holdEnded() {
        if trigger == .holdKey { stop() }
    }

    func toggleFromMenu(_ intent: Intent) {
        if phase == .idle { start(intent, trigger: .menu) } else { stop() }
    }

    // MARK: Recording

    func start(_ intent: Intent, trigger: Trigger) {
        guard phase == .idle else { return }
        generation += 1
        let run = generation
        phase = .starting
        self.intent = intent
        self.trigger = trigger
        stopRequested = false
        selection = nil
        work = Task { await begin(run) }
    }

    private func begin(_ run: Int) async {
        guard await Permissions.ensureMicrophone() else {
            Permissions.open(.microphone)
            return fail(run, "Microphone access is off. Allow Murmur in System Settings → Privacy & Security → Microphone.")
        }
        if settings.engine == .apple, !(await Permissions.ensureSpeechRecognition()) {
            Permissions.open(.speechRecognition)
            return fail(run, "Speech Recognition is off for Murmur. Allow it in System Settings, or pick another engine.")
        }
        if intent == .edit, Secrets.get(.anthropic) == nil {
            return fail(run, "Voice editing uses Claude. \(ClaudeError.missingKey.localizedDescription)")
        }
        guard isCurrent(run) else { return }

        let app = NSWorkspace.shared.frontmostApplication
        let isSelf = app?.processIdentifier == ProcessInfo.processInfo.processIdentifier
        let pid = isSelf ? nil : app?.processIdentifier
        let appName = app?.localizedName
        let bundleID = app?.bundleIdentifier
        let readCaret = intent == .dictate
        let readSelection = intent == .edit
        let context = Task.detached(priority: .userInitiated) { () -> AppContext in
            guard let pid else { return AppContext() }
            return Accessibility.context(pid: pid, appName: appName, bundleID: bundleID, readCaret: readCaret, readSelection: readSelection)
        }
        contextTask = context

        if intent == .edit {
            // Accessibility exposes the selection instantly in native apps;
            // fall back to ⌘C for browsers and Electron apps that don't.
            switch await context.value.selectedText {
            case let text?: selection = text.isEmpty ? nil : text
            case nil where pid != nil: selection = await TextInserter.copySelection()
            case nil: selection = nil
            }
            guard isCurrent(run) else { return }
        }

        let session: TranscriptionSession
        do {
            session = try Transcriber.makeSession(
                settings: settings,
                options: TranscriptionOptions(vocabulary: settings.vocabularyTerms) { [weak self] text in
                    guard let self, self.generation == run else { return }
                    self.hud.model.partial = text
                }
            )
        } catch {
            return fail(run, error.localizedDescription)
        }
        self.session = session

        let recorder = AudioRecorder()
        recorder.silenceTimeout = settings.autoStopSilence
        recorder.onBuffer = { buffer in session.append(buffer) }
        recorder.onLevel = { [weak self] level in self?.hud.model.push(level: level) }
        recorder.onSilenceTimeout = { [weak self] in
            guard let self, self.generation == run else { return }
            Log.audio.info("auto-stop after silence")
            self.stop()
        }
        recorder.onInterrupted = { [weak self] in
            guard let self, self.generation == run, self.phase == .recording else { return }
            Log.audio.info("input device changed; finishing with the audio so far")
            self.stop()
        }
        recorder.onNoAudio = { [weak self] in
            guard let self, self.generation == run, self.phase == .recording else { return }
            self.hud.model.hint = "No sound — check the microphone"
        }
        do {
            try recorder.start()
        } catch {
            session.cancel()
            return fail(run, "Couldn't start the microphone: \(error.localizedDescription)")
        }
        self.recorder = recorder
        phase = .recording
        Sounds.start()
        hud.showListening(badge: badge)
        HotkeyCenter.shared.register(.escape, .escape, pressed: { [weak self] in self?.cancel() })
        if stopRequested { stop() }
    }

    private var badge: String? {
        switch intent {
        case .edit: return selection == nil ? "Compose" : "Edit selection"
        case .dictate: return settings.activePolish?.name
        }
    }

    func stop() {
        switch phase {
        case .starting:
            stopRequested = true
        case .recording:
            guard let recorder else { return }
            let recording = recorder.stop()
            self.recorder = nil
            Sounds.stop()
            phase = .processing
            let run = generation
            let session = self.session
            work = Task { await process(recording, session, run) }
        case .idle, .processing:
            break
        }
    }

    func cancel() {
        guard phase != .idle else { return }
        if let recorder { _ = recorder.stop() }
        recorder = nil
        work?.cancel()
        session?.cancel()
        hud.hide()
        Log.app.info("dictation cancelled")
        finish(generation)
    }

    // MARK: Processing

    private func process(_ recording: Recording, _ session: TranscriptionSession?, _ run: Int) async {
        defer { finish(run) }
        guard let session else { return }
        if recording.duration < 0.3 || recording.voicedDuration < 0.08 {
            session.cancel()
            hud.notice("Didn't catch that — no speech heard.")
            return
        }
        let polish = intent == .dictate ? settings.activePolish : nil
        hud.showWorking("Transcribing…")

        var raw: String
        do {
            raw = try await session.finish(samples: recording.samples)
        } catch {
            guard isCurrent(run), !(error is CancellationError) else { return }
            let context = await contextTask?.value
            Log.transcription.error("transcription failed: \(error.localizedDescription, privacy: .public)")
            var message = error.localizedDescription
            if settings.historyEnabled {
                history.addFailure(samples: recording.samples, error: message, appName: context?.appName, mode: polish?.name, duration: recording.duration)
                message += " The recording is saved in History for a retry."
            }
            hud.notice(message, isError: true, duration: 5)
            return
        }
        guard isCurrent(run) else { return }
        raw = settings.normalizingScript(TranscriptFilter.clean(raw, likelySilence: recording.voicedDuration < 0.4))
        guard !raw.isEmpty else {
            hud.notice("No speech detected.")
            return
        }
        let context = await contextTask?.value ?? AppContext()
        guard isCurrent(run) else { return }
        let destination = settings.useAppContext ? context.insertion : InsertionContext(caret: context.caret)

        var text = raw
        var warning: String?
        switch intent {
        case .dictate:
            if let polish {
                if let key = Secrets.get(.anthropic) {
                    hud.showWorking(polish.instructions == nil ? "Polishing…" : "\(polish.name)…")
                    do {
                        text = try await claude(key).complete(
                            system: Prompts.cleanupSystem(style: settings.cleanupStyle, vocabulary: settings.vocabularyTerms, instructions: polish.instructions),
                            user: Prompts.cleanupUser(transcript: raw, context: destination)
                        )
                    } catch {
                        guard isCurrent(run) else { return }
                        Log.app.error("polish failed: \(error.localizedDescription, privacy: .public)")
                        warning = "AI polish failed (\(error.localizedDescription)). Inserted the raw transcript."
                    }
                } else {
                    warning = "AI polish is on but no Anthropic API key is set. Inserted the raw transcript."
                }
            }
            text = TextReplacer.apply(settings.replacements, to: text)
            if settings.smartSpacing { text = SmartSpacing.shape(text, context: context.caret) }

        case .edit:
            guard let key = Secrets.get(.anthropic) else { return }
            hud.showWorking(selection == nil ? "Writing…" : "Rewriting…")
            let vocabulary = settings.vocabularyTerms
            do {
                if let selection {
                    text = try await claude(key).complete(
                        system: Prompts.editSystem(vocabulary: vocabulary),
                        user: Prompts.editUser(selection: selection, instruction: raw, context: destination)
                    )
                } else {
                    text = try await claude(key).complete(
                        system: Prompts.composeSystem(vocabulary: vocabulary),
                        user: Prompts.composeUser(instruction: raw, context: destination)
                    )
                }
            } catch {
                guard isCurrent(run) else { return }
                hud.notice("Claude couldn't do that: \(error.localizedDescription)", isError: true, duration: 5)
                return
            }
            text = TextReplacer.apply(settings.replacements, to: text)
        }
        guard isCurrent(run) else { return }

        let outcome = await TextInserter.insert(text, preserveClipboard: settings.preserveClipboard)
        if settings.historyEnabled {
            history.add(HistoryEntry(
                text: text,
                raw: text == raw ? nil : raw,
                appName: context.appName,
                mode: intent == .edit ? (selection == nil ? "Compose" : "Edit") : polish?.name,
                duration: recording.duration
            ))
        }
        switch outcome {
        case .pasted:
            if let warning { hud.notice(warning, isError: true, duration: 4) } else { hud.hide() }
        case .copiedOnly:
            hud.notice("Copied to the clipboard. Allow Murmur under Privacy & Security → Accessibility to paste automatically.", isError: true, duration: 5)
        }
    }

    private func claude(_ key: String) -> ClaudeClient {
        ClaudeClient(apiKey: key, model: settings.claudeModel, effort: settings.claudeEffort)
    }

    private func isCurrent(_ run: Int) -> Bool {
        run == generation && !Task.isCancelled && phase != .idle
    }

    private func fail(_ run: Int, _ message: String) {
        guard run == generation else { return }
        hud.notice(message, isError: true, duration: 5)
        finish(run)
    }

    private func finish(_ run: Int) {
        guard run == generation, phase != .idle else { return }
        HotkeyCenter.shared.unregister(.escape)
        recorder = nil
        session = nil
        contextTask = nil
        work = nil
        selection = nil
        phase = .idle
    }

    // MARK: Other actions

    func pasteLast() {
        guard phase == .idle, let entry = history.lastSuccessful else {
            NSSound.beep()
            return
        }
        Task { _ = await TextInserter.insert(entry.text, preserveClipboard: settings.preserveClipboard) }
    }

    /// Transcribes an audio file with the current engine and copies the text.
    func transcribeFile(_ url: URL) {
        guard phase == .idle else { return NSSound.beep() }
        generation += 1
        let run = generation
        phase = .processing
        hud.showWorking("Transcribing \(url.lastPathComponent)…")
        HotkeyCenter.shared.register(.escape, .escape, pressed: { [weak self] in self?.cancel() })
        work = Task {
            defer { finish(run) }
            do {
                let samples = try await Task.detached(priority: .userInitiated) { try AudioFileLoader.load(url) }.value
                let text = try await transcribeOffline(samples, run: run)
                guard isCurrent(run) else { return }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                if settings.historyEnabled {
                    history.add(HistoryEntry(text: text, appName: url.lastPathComponent, mode: "File", duration: Double(samples.count) / AudioRecorder.sampleRate))
                }
                hud.notice(text.isEmpty ? "No speech found in the file." : "Transcript copied to the clipboard.")
            } catch {
                guard isCurrent(run) else { return }
                hud.notice(error.localizedDescription, isError: true, duration: 5)
            }
        }
    }

    /// Re-runs a failed recording from History; the result goes to the clipboard.
    func retry(_ entry: HistoryEntry) {
        guard phase == .idle, let url = history.audioURL(for: entry) else { return NSSound.beep() }
        generation += 1
        let run = generation
        phase = .processing
        hud.showWorking("Retrying transcription…")
        work = Task {
            defer { finish(run) }
            do {
                let samples = try AudioFileLoader.load(url)
                var text = try await transcribeOffline(samples, run: run)
                text = TextReplacer.apply(settings.replacements, to: text)
                guard isCurrent(run) else { return }
                guard !text.isEmpty else { return hud.notice("Still no speech detected.") }
                history.markRecovered(entry.id, text: text)
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                hud.notice("Recovered — copied to the clipboard.")
            } catch {
                guard isCurrent(run) else { return }
                hud.notice(error.localizedDescription, isError: true, duration: 5)
            }
        }
    }

    private func transcribeOffline(_ samples: [Float], run: Int) async throws -> String {
        if settings.engine == .apple, !(await Permissions.ensureSpeechRecognition()) {
            throw TranscriptionError.permissionDenied("Speech Recognition is off for Murmur.")
        }
        // Decoding a long file can outlast a cancel; never adopt a session then.
        guard isCurrent(run) else { throw CancellationError() }
        let session = try Transcriber.makeSession(settings: settings, options: TranscriptionOptions(vocabulary: settings.vocabularyTerms))
        self.session = session
        let text = try await session.finish(samples: samples)
        return settings.normalizingScript(TranscriptFilter.clean(text, likelySilence: false))
    }
}
