import AppKit
import SwiftUI

/// Renders the HUD and settings screens to PNGs (`--snapshot <dir>`) so UI
/// changes can be reviewed without driving the live app.
@MainActor
enum Snapshots {
    static func write(to directory: URL) throws {
        _ = NSApplication.shared
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let model = HUDModel()
        model.levels = (0..<HUDModel.barCount).map { Float(0.15 + 0.75 * abs(sin(Double($0) * 0.7))) }
        model.partial = "so I think we should move the launch to Thursday and"
        model.badge = "Clean up"
        model.phase = .listening
        try save(HUDView(model: model), size: NSSize(width: 480, height: 160), to: directory.appendingPathComponent("hud-listening.png"))

        let working = HUDModel()
        working.phase = .working("Polishing…")
        try save(HUDView(model: working), size: NSSize(width: 480, height: 160), to: directory.appendingPathComponent("hud-working.png"))

        let notice = HUDModel()
        notice.phase = .notice("Copied to the clipboard. Allow Murmur under Privacy & Security → Accessibility to paste automatically.", isError: true)
        try save(HUDView(model: notice), size: NSSize(width: 480, height: 160), to: directory.appendingPathComponent("hud-notice.png"))

        let runtime = RuntimeState.shared
        let dictation = DictationController(settings: .shared, history: .shared, hud: HUDController())
        for tab in SettingsTab.allCases {
            runtime.settingsTab = tab
            let view = SettingsView(dictation: dictation)
                .environmentObject(Settings.shared)
                .environmentObject(HistoryStore.shared)
                .environmentObject(runtime)
            try save(view, size: NSSize(width: 820, height: 620), to: directory.appendingPathComponent("settings-\(tab.rawValue).png"))
        }
    }

    private static func save<V: View>(_ view: V, size: NSSize, to url: URL) throws {
        let window = NSWindow(
            contentRect: NSRect(origin: NSPoint(x: -20_000, y: -20_000), size: size),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.appearance = NSAppearance(named: .darkAqua)
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
        host.frame = NSRect(origin: .zero, size: size)
        window.contentView = host
        window.orderFrontRegardless()
        // Let SwiftUI lay out and run onAppear.
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        window.orderOut(nil)
        try rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}
