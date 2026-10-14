import AppKit
import MurmurCore

/// Headless entry points for scripting and testing the pipeline without the UI.
@MainActor
enum CLI {
    nonisolated static let flags = ["--transcribe", "--polish", "--status", "--help", "--snapshot"]

    static let usage = """
    Usage: Murmur [options]
      (no options)              run the menu-bar app
      --transcribe <audio>      transcribe a file with the configured engine
      --polish <text>           run Claude clean-up on text
      --status                  print permission status
    Options:
      --engine apple|cloud|whisperCpp   override the engine for this run
      --language <tag>                  override the language (e.g. en-US, zh-TW)
      --model <path>                    override the local model
      --english-model <path>            override the local model used for English
      --app <name>                      destination app name for --polish context
      --out <file>                      also write the result to a file
    """

    static func run(_ args: [String]) async -> Int32 {
        func value(_ flag: String) -> String? {
            guard let index = args.firstIndex(of: flag), args.indices.contains(index + 1) else { return nil }
            return args[index + 1]
        }
        func emit(_ text: String) {
            print(text)
            if let out = value("--out") { try? text.write(toFile: out, atomically: true, encoding: .utf8) }
        }

        let settings = Settings.shared
        settings.persistChanges = false
        if args.contains("--help") {
            print(usage)
            return 0
        }
        if let directory = value("--snapshot") {
            do {
                try Snapshots.write(to: URL(fileURLWithPath: directory))
                print("wrote snapshots to \(directory)")
                return 0
            } catch {
                fputs("snapshot failed: \(error.localizedDescription)\n", stderr)
                return 1
            }
        }
        if args.contains("--status") {
            print("microphone: \(Permissions.microphone == .authorized ? "granted" : "not granted (\(Permissions.microphone.rawValue))")")
            print("speech recognition: \(Permissions.speech == .authorized ? "granted" : "not granted (\(Permissions.speech.rawValue))")")
            print("accessibility: \(Accessibility.isTrusted ? "granted" : "not granted")")
            print("engine: \(settings.engine.rawValue), language: \(settings.language)")
            print("anthropic key: \(Secrets.get(.anthropic) == nil ? "missing" : "saved")")
            return 0
        }
        if let engine = value("--engine") {
            guard let kind = EngineKind(rawValue: engine) else {
                fputs("unknown engine \(engine)\n", stderr)
                return 64
            }
            settings.engine = kind
        }
        if let language = value("--language") { settings.language = language }
        if let model = value("--model") { settings.whisperModel = model }
        if let model = value("--english-model") { settings.englishModel = model }

        do {
            if let path = value("--transcribe") {
                let samples = try AudioFileLoader.load(URL(fileURLWithPath: path))
                if settings.engine == .apple, !(await Permissions.ensureSpeechRecognition()) {
                    fputs("speech recognition is not authorized for Murmur\n", stderr)
                    return 2
                }
                let session = try Transcriber.makeSession(settings: settings, options: TranscriptionOptions(vocabulary: settings.vocabularyTerms))
                let started = Date()
                let text = settings.normalizingScript(TranscriptFilter.clean(try await session.finish(samples: samples), likelySilence: false))
                let audioSeconds = Double(samples.count) / AudioRecorder.sampleRate
                fputs(String(format: "[%@] %.1fs of audio transcribed in %.2fs\n", settings.engine.rawValue, audioSeconds, Date().timeIntervalSince(started)), stderr)
                emit(text)
            }
            if let text = value("--polish") {
                guard let key = Secrets.get(.anthropic) ?? ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"] else {
                    throw ClaudeError.missingKey
                }
                let client = ClaudeClient(apiKey: key, model: settings.claudeModel, effort: settings.claudeEffort)
                let started = Date()
                let polished = try await client.complete(
                    system: Prompts.cleanupSystem(style: settings.cleanupStyle, vocabulary: settings.vocabularyTerms, instructions: nil),
                    user: Prompts.cleanupUser(transcript: text, context: InsertionContext(appName: value("--app")))
                )
                fputs(String(format: "[%@] polished in %.2fs\n", settings.claudeModel, Date().timeIntervalSince(started)), stderr)
                emit(polished)
            }
            return 0
        } catch {
            fputs("error: \(error.localizedDescription)\n", stderr)
            return 1
        }
    }
}

let arguments = CommandLine.arguments
if arguments.contains(where: CLI.flags.contains) {
    Task { @MainActor in
        exit(await CLI.run(arguments))
    }
    dispatchMain()
} else {
    MainActor.assumeIsolated {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { app.run() }
    }
}
