// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Murmur",
    platforms: [.macOS(.v14)],
    targets: [
        // Pure, platform-independent logic (text shaping, prompts, WAV encoding).
        .target(name: "MurmurCore", path: "Sources/MurmurCore"),
        // The menu-bar app: audio, hotkeys, transcription engines, insertion, UI.
        .executableTarget(
            name: "Murmur",
            dependencies: ["MurmurCore"],
            path: "Sources/Murmur",
            linkerSettings: [
                .linkedFramework("Carbon"),
                .linkedFramework("Speech"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("ServiceManagement"),
            ]
        ),
        // Self-checks for MurmurCore. Command Line Tools ship without XCTest,
        // so this is a plain executable: `swift run MurmurChecks`.
        .executableTarget(name: "MurmurChecks", dependencies: ["MurmurCore"], path: "Sources/MurmurChecks"),
    ]
)
