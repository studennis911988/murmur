import Foundation
import MurmurCore

struct HistoryEntry: Codable, Identifiable, Equatable {
    var id = UUID()
    var date = Date()
    /// Final inserted text, or "" for a failed recording.
    var text: String
    /// What the speech engine heard before AI polish, when it differs.
    var raw: String?
    var appName: String?
    var mode: String?
    var duration: TimeInterval
    /// Set when transcription failed; the audio is kept for a retry.
    var error: String?
    var audioFile: String?

    var failed: Bool { error != nil }
}

/// Recent dictations in ~/Library/Application Support/Murmur. Failed
/// recordings keep their audio so they can be transcribed again.
@MainActor
final class HistoryStore: ObservableObject {
    static let shared = HistoryStore()
    static let limit = 200

    @Published private(set) var entries: [HistoryEntry] = []

    let directory: URL
    private var fileURL: URL { directory.appendingPathComponent("history.json") }
    var audioDirectory: URL { directory.appendingPathComponent("audio", isDirectory: true) }

    private init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        directory = support.appendingPathComponent("Murmur", isDirectory: true)
        try? FileManager.default.createDirectory(at: audioDirectory, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([HistoryEntry].self, from: data) {
            entries = decoded
        }
    }

    var lastSuccessful: HistoryEntry? { entries.first { !$0.failed && !$0.text.isEmpty } }

    func add(_ entry: HistoryEntry) {
        entries.insert(entry, at: 0)
        while entries.count > Self.limit {
            removeAudio(of: entries.removeLast())
        }
        save()
    }

    /// Keeps a failed recording's audio and logs it for a later retry.
    func addFailure(samples: [Float], error: String, appName: String?, mode: String?, duration: TimeInterval) {
        var entry = HistoryEntry(text: "", appName: appName, mode: mode, duration: duration, error: error)
        let file = "\(entry.id.uuidString).wav"
        let wav = WAVEncoder.encode(samples: samples, sampleRate: Int(AudioRecorder.sampleRate))
        if (try? wav.write(to: audioDirectory.appendingPathComponent(file))) != nil {
            entry.audioFile = file
        }
        add(entry)
    }

    func audioURL(for entry: HistoryEntry) -> URL? {
        entry.audioFile.map { audioDirectory.appendingPathComponent($0) }
    }

    func markRecovered(_ id: UUID, text: String) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        removeAudio(of: entries[index])
        entries[index].text = text
        entries[index].error = nil
        entries[index].audioFile = nil
        save()
    }

    func delete(_ id: UUID) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        removeAudio(of: entries.remove(at: index))
        save()
    }

    func clear() {
        entries.forEach(removeAudio)
        entries.removeAll()
        save()
    }

    private func removeAudio(of entry: HistoryEntry) {
        if let url = audioURL(for: entry) { try? FileManager.default.removeItem(at: url) }
    }

    private func save() {
        do {
            let data = try JSONEncoder().encode(entries)
            try data.write(to: fileURL, options: [.atomic])
        } catch {
            Log.app.error("history not saved: \(error.localizedDescription, privacy: .public)")
        }
    }
}
