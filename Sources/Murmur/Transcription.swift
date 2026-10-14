import AppKit
import AVFoundation
import MurmurCore
import Speech

/// One recording's trip through a speech-to-text engine.
protocol TranscriptionSession: AnyObject {
    /// Live microphone audio in its native format, for streaming engines.
    func append(_ buffer: AVAudioPCMBuffer)
    /// The whole recording as 16 kHz mono samples; returns the transcript.
    func finish(samples: [Float]) async throws -> String
    func cancel()
}

enum TranscriptionError: LocalizedError {
    case permissionDenied(String)
    case unavailable(String)
    case misconfigured(String)
    case server(String)

    var errorDescription: String? {
        switch self {
        case .permissionDenied(let m), .unavailable(let m), .misconfigured(let m), .server(let m): return m
        }
    }
}

struct TranscriptionOptions {
    var vocabulary: [String]
    var onPartial: (@MainActor (String) -> Void)?
}

enum Transcriber {
    /// Whisper continues the script of its prompt; in eval/ this cut
    /// Simplified output on Taiwanese Mandarin from 75–100% of clips to 10–17%.
    static let traditionalHint = "以下是繁體中文的句子。"

    @MainActor
    static func makeSession(settings: Settings, options: TranscriptionOptions) throws -> TranscriptionSession {
        switch settings.engine {
        case .apple:
            return try AppleSpeechSession(
                locale: settings.speechLocale,
                onDeviceOnly: settings.appleOnDeviceOnly,
                vocabulary: options.vocabulary,
                onPartial: settings.showLivePreview ? options.onPartial : nil
            )
        case .cloud:
            guard let key = Secrets.get(.cloudTranscription) else {
                throw TranscriptionError.misconfigured("Add a Whisper API key in Settings → Transcription.")
            }
            guard let url = URL(string: settings.cloudBaseURL.trimmingCharacters(in: .whitespaces)), url.scheme?.hasPrefix("http") == true else {
                throw TranscriptionError.misconfigured("The Whisper API base URL is not valid.")
            }
            return CloudWhisperSession(
                baseURL: url, apiKey: key, model: settings.cloudModel,
                language: settings.whisperLanguage, vocabulary: options.vocabulary,
                scriptHint: settings.prefersTraditionalChinese && settings.whisperLanguage == "zh" ? Transcriber.traditionalHint : nil
            )
        case .whisperCpp:
            let wantsEnglish = settings.whisperLanguage == "en" && !settings.englishModel.isEmpty
            let model = wantsEnglish ? settings.englishModel : settings.whisperModel
            guard !model.isEmpty, FileManager.default.fileExists(atPath: model) else {
                throw TranscriptionError.misconfigured("Choose a local model in Settings → Transcription.")
            }
            let family = LocalModels.family(of: model)
            let binary = LocalModels.runner(for: family, whisperCLI: settings.whisperBinary)
            guard FileManager.default.isExecutableFile(atPath: binary) else {
                throw TranscriptionError.misconfigured("\((binary as NSString).lastPathComponent) not found at \(binary). Install whisper.cpp with `brew install whisper-cpp` or fix the path in Settings.")
            }
            if family == .parakeet, let language = settings.whisperLanguage, !LocalModels.parakeetLanguages.contains(language) {
                throw TranscriptionError.unavailable("Parakeet doesn't understand \(settings.language). Pick a Whisper model for this language.")
            }
            var language = settings.whisperLanguage
            // Breeze-ASR-25 is trained on Taiwanese Mandarin with English
            // code-switching under the "zh" token: forcing it transcribes
            // English as accurately as "en" and avoids mis-detection.
            if family == .breeze, language == nil || language == "en" { language = "zh" }
            return WhisperCppSession(
                binary: binary, model: model, family: family, language: language,
                vocabulary: options.vocabulary,
                scriptHint: family == .whisper && settings.prefersTraditionalChinese && language == "zh" ? Transcriber.traditionalHint : nil
            )
        }
    }
}

/// ggml speech models in ~/Library/Application Support/Murmur/models, run
/// with the user's own whisper.cpp install.
enum LocalModels {
    enum Family { case whisper, breeze, parakeet }

    /// NVIDIA Parakeet TDT v3 covers these European languages only.
    static let parakeetLanguages: Set<String> = [
        "bg", "hr", "cs", "da", "nl", "en", "et", "fi", "fr", "de", "el", "hu", "it",
        "lv", "lt", "mt", "pl", "pt", "ro", "sk", "sl", "es", "sv", "ru", "uk",
    ]

    static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Murmur/models", isDirectory: true)
    }

    static func available() -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "bin" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    static func family(of model: String) -> Family {
        let name = (model as NSString).lastPathComponent.lowercased()
        if name.contains("parakeet") { return .parakeet }
        if name.contains("breeze") { return .breeze }
        return .whisper
    }

    /// Parakeet models need whisper.cpp's `parakeet-cli`, installed next to `whisper-cli`.
    static func runner(for family: Family, whisperCLI: String) -> String {
        guard family == .parakeet else { return whisperCLI }
        return ((whisperCLI as NSString).deletingLastPathComponent as NSString).appendingPathComponent("parakeet-cli")
    }
}

// MARK: - Apple Speech

/// Apple's speech framework refuses to run ("Siri and Dictation are
/// disabled") unless macOS Dictation is switched on, even for on-device use.
enum SystemDictation {
    static var isEnabled: Bool {
        let value = CFPreferencesCopyAppValue("Dictation Enabled" as CFString, "com.apple.assistant.support" as CFString)
        return (value as? Bool) ?? true
    }

    static let disabledMessage = "Apple Speech needs macOS Dictation switched on: System Settings → Keyboard → Dictation. Or pick another engine in Murmur → Settings → Transcription."

    /// Language codes with an on-device model installed, e.g. ["en-US", "zh-TW"].
    static var installedOnDeviceLanguages: [String] {
        guard let status = CFPreferencesCopyAppValue("Offline Dictation Status" as CFString, "com.apple.assistant.support" as CFString) as? [String: Any] else { return [] }
        return status.compactMap { key, value in ((value as? [String: Any])?["Installed"] as? Bool) == true ? key : nil }.sorted()
    }

    static func openSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }
}

/// Streams audio to SFSpeechRecognizer while recording, so the final result is
/// ready almost as soon as the user stops. On-device by default.
/// Unchecked: mutable state is guarded by `lock`.
final class AppleSpeechSession: TranscriptionSession, @unchecked Sendable {
    private let recognizer: SFSpeechRecognizer
    private let request = SFSpeechAudioBufferRecognitionRequest()
    private var task: SFSpeechRecognitionTask?
    private let onPartial: (@MainActor (String) -> Void)?

    private let lock = NSLock()
    private var latest = ""
    private var outcome: Result<String, Error>?
    private var waiter: CheckedContinuation<String, Error>?
    private var receivedLiveAudio = false

    init(locale: Locale, onDeviceOnly: Bool, vocabulary: [String], onPartial: (@MainActor (String) -> Void)?) throws {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: break
        case .notDetermined:
            throw TranscriptionError.permissionDenied("Speech recognition permission hasn't been granted yet.")
        default:
            throw TranscriptionError.permissionDenied("Speech recognition is turned off for Murmur in System Settings → Privacy & Security → Speech Recognition.")
        }
        guard let recognizer = SFSpeechRecognizer(locale: locale) else {
            throw TranscriptionError.unavailable("Apple Speech doesn't support \(locale.identifier). Pick another language or engine.")
        }
        guard SystemDictation.isEnabled else {
            throw TranscriptionError.unavailable(SystemDictation.disabledMessage)
        }
        guard recognizer.isAvailable else {
            throw TranscriptionError.unavailable("Apple Speech is unavailable right now for \(locale.identifier).")
        }
        if onDeviceOnly {
            guard recognizer.supportsOnDeviceRecognition else {
                throw TranscriptionError.unavailable("On-device recognition isn't installed for \(locale.identifier). Turn off \"Keep audio on this Mac\" or add the language under System Settings → Keyboard → Dictation.")
            }
            request.requiresOnDeviceRecognition = true
        }
        // Always ask for partials: they are the fallback if the final result
        // is late. Whether they reach the HUD is up to `onPartial`.
        request.shouldReportPartialResults = true
        request.addsPunctuation = true
        request.taskHint = .dictation
        request.contextualStrings = Array(vocabulary.prefix(100))
        self.recognizer = recognizer
        self.onPartial = onPartial
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            self?.handle(result: result, error: error)
        }
        Log.transcription.info("apple speech: \(locale.identifier, privacy: .public), on-device \(self.request.requiresOnDeviceRecognition)")
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        receivedLiveAudio = true
        lock.unlock()
        request.append(buffer)
    }

    func finish(samples: [Float]) async throws -> String {
        let live = lock.withLock { receivedLiveAudio }
        if !live {
            // File transcription: feed the decoded audio in one go.
            AudioFileLoader.buffers(from: samples).forEach(request.append)
        }
        request.endAudio()

        // The final result normally arrives within a second of endAudio;
        // never hang on it.
        let audioSeconds = Double(samples.count) / AudioRecorder.sampleRate
        let deadline = live ? 6 : 15 + audioSeconds
        DispatchQueue.global().asyncAfter(deadline: .now() + deadline) { [weak self] in
            self?.complete(nil)
        }
        return try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if let outcome {
                lock.unlock()
                continuation.resume(with: outcome)
            } else {
                waiter = continuation
                lock.unlock()
            }
        }
    }

    func cancel() {
        task?.cancel()
        complete(.failure(CancellationError()))
    }

    private func handle(result: SFSpeechRecognitionResult?, error: Error?) {
        if let result {
            let text = result.bestTranscription.formattedString
            lock.lock()
            latest = text
            lock.unlock()
            if result.isFinal {
                complete(.success(text))
                return
            }
            if let onPartial {
                DispatchQueue.main.async { MainActor.assumeIsolated { onPartial(text) } }
            }
        }
        if let error {
            let ns = error as NSError
            // 1110: no speech detected; 301/216: request was cancelled/ended.
            let benign = ns.domain == "kAFAssistantErrorDomain" && [1110, 301, 216, 203].contains(ns.code)
            lock.lock()
            let partial = latest
            lock.unlock()
            if benign || !partial.isEmpty {
                complete(.success(partial))
            } else if !SystemDictation.isEnabled {
                complete(.failure(TranscriptionError.unavailable(SystemDictation.disabledMessage)))
            } else {
                Log.transcription.error("apple speech failed: \(ns.domain, privacy: .public) \(ns.code) \(ns.localizedDescription, privacy: .public)")
                complete(.failure(TranscriptionError.server("Apple Speech failed: \(ns.localizedDescription)")))
            }
        }
    }

    /// Settles the result once. `nil` means "deadline reached": use the latest
    /// partial, or fail so the recording is kept for a retry.
    private func complete(_ result: Result<String, Error>?) {
        lock.lock()
        guard outcome == nil else { lock.unlock(); return }
        let settled = result ?? (latest.isEmpty
            ? .failure(TranscriptionError.server("Apple Speech didn't return a result in time."))
            : .success(latest))
        outcome = settled
        let continuation = waiter
        waiter = nil
        lock.unlock()
        continuation?.resume(with: settled)
    }
}

// MARK: - OpenAI-compatible Whisper API

/// Unchecked: mutable state is guarded by `lock`.
final class CloudWhisperSession: TranscriptionSession, @unchecked Sendable {
    private let baseURL: URL
    private let apiKey: String
    private let model: String
    private let language: String?
    private let vocabulary: [String]
    private let scriptHint: String?
    private let lock = NSLock()
    private var task: Task<String, Error>?
    private var cancelled = false

    init(baseURL: URL, apiKey: String, model: String, language: String?, vocabulary: [String], scriptHint: String?) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.model = model
        self.language = language
        self.vocabulary = vocabulary
        self.scriptHint = scriptHint
    }

    func append(_ buffer: AVAudioPCMBuffer) {}

    func finish(samples: [Float]) async throws -> String {
        let wav = WAVEncoder.encode(samples: samples, sampleRate: Int(AudioRecorder.sampleRate))
        guard wav.count < 25_000_000 else {
            throw TranscriptionError.unavailable("Recording is too long for the Whisper API's 25 MB upload limit (about 13 minutes).")
        }
        let seconds = Double(samples.count) / AudioRecorder.sampleRate
        let request = makeRequest(wav: wav, timeout: 30 + seconds / 2)
        let task = Task { try await Self.send(request, attemptsLeft: 2) }
        let alreadyCancelled = lock.withLock {
            self.task = task
            return cancelled
        }
        if alreadyCancelled { task.cancel() }
        return try await task.value
    }

    func cancel() {
        let task = lock.withLock {
            cancelled = true
            return self.task
        }
        task?.cancel()
    }

    private func makeRequest(wav: Data, timeout: TimeInterval) -> URLRequest {
        let boundary = "murmur-\(UUID().uuidString)"
        var request = URLRequest(url: baseURL.appendingPathComponent("audio/transcriptions"))
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
        }
        field("model", model)
        field("response_format", "json")
        if let language { field("language", language) }
        let prompt = [scriptHint, vocabulary.isEmpty ? nil : "Vocabulary: \(vocabulary.joined(separator: ", "))."]
            .compactMap { $0 }.joined(separator: " ")
        if !prompt.isEmpty { field("prompt", prompt) }
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\nContent-Type: audio/wav\r\n\r\n".utf8))
        body.append(wav)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        request.httpBody = body
        return request
    }

    private static func send(_ request: URLRequest, attemptsLeft: Int) async throws -> String {
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 429 || status >= 500, attemptsLeft > 1 {
                try await Task.sleep(nanoseconds: 800_000_000)
                return try await send(request, attemptsLeft: attemptsLeft - 1)
            }
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            guard (200..<300).contains(status) else {
                let message = (json?["error"] as? [String: Any])?["message"] as? String
                    ?? String(data: data, encoding: .utf8)?.prefix(200).description ?? "no details"
                throw TranscriptionError.server("Whisper API error \(status): \(message)")
            }
            guard let text = json?["text"] as? String else {
                throw TranscriptionError.server("Whisper API returned an unexpected response.")
            }
            return text
        } catch let error as URLError where attemptsLeft > 1 && error.code != .cancelled {
            Log.transcription.error("whisper api retry after \(error.localizedDescription, privacy: .public)")
            return try await send(request, attemptsLeft: attemptsLeft - 1)
        }
    }
}

// MARK: - whisper.cpp

/// Runs the user's own whisper.cpp build (`whisper-cli`, or `parakeet-cli`
/// for Parakeet models) on a temporary WAV.
/// Unchecked: mutable state is guarded by `lock`.
final class WhisperCppSession: TranscriptionSession, @unchecked Sendable {
    private let binary: String
    private let model: String
    private let family: LocalModels.Family
    private let language: String?
    private let vocabulary: [String]
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false

    private let scriptHint: String?

    init(binary: String, model: String, family: LocalModels.Family, language: String?, vocabulary: [String], scriptHint: String?) {
        self.binary = binary
        self.model = model
        self.family = family
        self.language = language
        self.vocabulary = vocabulary
        self.scriptHint = scriptHint
    }

    func append(_ buffer: AVAudioPCMBuffer) {}

    func finish(samples: [Float]) async throws -> String {
        let wavURL = FileManager.default.temporaryDirectory.appendingPathComponent("murmur-\(UUID().uuidString).wav")
        try WAVEncoder.encode(samples: samples, sampleRate: Int(AudioRecorder.sampleRate)).write(to: wavURL)
        defer { try? FileManager.default.removeItem(at: wavURL) }

        let threads = max(1, min(8, ProcessInfo.processInfo.activeProcessorCount - 2))
        var arguments = ["-m", model, "-f", wavURL.path, "-np", "-t", String(threads)]
        if family != .parakeet {
            arguments += ["-nt", "-l", language ?? "auto"]
            let prompt = [scriptHint, vocabulary.isEmpty ? nil : vocabulary.joined(separator: ", ")]
                .compactMap { $0 }.joined(separator: " ")
            if !prompt.isEmpty { arguments += ["--prompt", prompt] }
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = arguments
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        let alreadyCancelled = lock.withLock {
            if !cancelled { self.process = process }
            return cancelled
        }
        if alreadyCancelled { throw CancellationError() }

        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: TranscriptionError.misconfigured("Couldn't start \((self.binary as NSString).lastPathComponent): \(error.localizedDescription)"))
                    return
                }
                // cancel() may have run before the process existed.
                if self.lock.withLock({ self.cancelled }) { process.terminate() }
                // Drain both pipes before waiting so a chatty process can't block.
                var errData = Data()
                let errReader = DispatchQueue(label: "murmur.whisper.stderr")
                errReader.async { errData = stderr.fileHandleForReading.readDataToEndOfFile() }
                let outData = stdout.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                errReader.sync {}
                if process.terminationReason == .uncaughtSignal {
                    continuation.resume(throwing: CancellationError())
                } else if process.terminationStatus != 0 {
                    let detail = String(data: errData, encoding: .utf8)?.split(separator: "\n").suffix(3).joined(separator: " ") ?? ""
                    continuation.resume(throwing: TranscriptionError.server("whisper-cli exited with \(process.terminationStatus). \(detail)"))
                } else {
                    let text = String(data: outData, encoding: .utf8) ?? ""
                    continuation.resume(returning: text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: " "))
                }
            }
        }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let running = process
        lock.unlock()
        if running?.isRunning == true { running?.terminate() }
    }
}
