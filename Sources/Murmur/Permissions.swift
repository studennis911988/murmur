import AppKit
import AVFoundation
import Speech

enum Permissions {
    enum Pane: String {
        case microphone = "Privacy_Microphone"
        case accessibility = "Privacy_Accessibility"
        case speechRecognition = "Privacy_SpeechRecognition"
    }

    static var microphone: AVAuthorizationStatus { AVCaptureDevice.authorizationStatus(for: .audio) }
    static var speech: SFSpeechRecognizerAuthorizationStatus { SFSpeechRecognizer.authorizationStatus() }

    static func ensureMicrophone() async -> Bool {
        switch microphone {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }

    static func ensureSpeechRecognition() async -> Bool {
        switch speech {
        case .authorized: return true
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0 == .authorized) }
            }
        default: return false
        }
    }

    static func open(_ pane: Pane) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane.rawValue)") {
            NSWorkspace.shared.open(url)
        }
    }
}

@MainActor
enum Sounds {
    private static let startSound: NSSound? = load("Tink")
    private static let stopSound: NSSound? = load("Pop")

    static func start() { play(startSound) }
    static func stop() { play(stopSound) }

    private static func load(_ name: String) -> NSSound? {
        let sound = NSSound(named: NSSound.Name(name))
        sound?.volume = 0.3
        return sound
    }

    private static func play(_ sound: NSSound?) {
        guard Settings.shared.playSounds, let sound else { return }
        sound.stop()
        sound.play()
    }
}
