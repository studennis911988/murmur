import os

/// `log stream --level debug --predicate 'subsystem == "dev.murmur.app"'`
enum Log {
    static let app = Logger(subsystem: "dev.murmur.app", category: "app")
    static let audio = Logger(subsystem: "dev.murmur.app", category: "audio")
    static let transcription = Logger(subsystem: "dev.murmur.app", category: "transcription")
    static let insertion = Logger(subsystem: "dev.murmur.app", category: "insertion")
}
