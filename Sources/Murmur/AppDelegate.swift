import AppKit
import Combine
import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers

/// Runtime facts the settings window shows but that aren't preferences.
@MainActor
final class RuntimeState: ObservableObject {
    static let shared = RuntimeState()
    @Published var hotkeyIssues: [String] = []
    @Published var accessibilityTrusted = Accessibility.isTrusted
    @Published var settingsTab: SettingsTab = .setup
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let settings = Settings.shared
    let history = HistoryStore.shared
    let runtime = RuntimeState.shared
    let hud = HUDController()
    lazy var dictation = DictationController(settings: settings, history: history, hud: hud)

    private let holdMonitor = ModifierHoldMonitor()
    private var statusItem: NSStatusItem?
    private var settingsWindow: NSWindow?
    private var trustTimer: Timer?
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = makeMainMenu()
        setupStatusItem()
        registerHotkeys()

        holdMonitor.onBegin = { [weak self] in self?.dictation.holdBegan() }
        holdMonitor.onEnd = { [weak self] in self?.dictation.holdEnded() }
        holdMonitor.update(key: settings.holdKey)

        // @Published fires before the value is stored; re-read on the next turn.
        Publishers.MergeMany(
            settings.$dictateHotkey.map { _ in () }.eraseToAnyPublisher(),
            settings.$editHotkey.map { _ in () }.eraseToAnyPublisher(),
            settings.$pasteLastHotkey.map { _ in () }.eraseToAnyPublisher()
        )
        .dropFirst(3)
        .receive(on: DispatchQueue.main)
        .sink { [weak self] in self?.registerHotkeys() }
        .store(in: &cancellables)
        settings.$holdKey.dropFirst().sink { [weak self] key in self?.holdMonitor.update(key: key) }.store(in: &cancellables)
        dictation.$phase.sink { [weak self] phase in self?.updateStatusIcon(phase) }.store(in: &cancellables)

        watchAccessibilityTrust()
        if !settings.hasCompletedOnboarding || !Accessibility.isTrusted || Permissions.microphone != .authorized {
            showSettings(tab: .setup)
        }
        Log.app.info("Murmur started")
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettings(tab: runtime.settingsTab)
        return true
    }

    // MARK: Shortcuts

    private func registerHotkeys() {
        let center = HotkeyCenter.shared
        var issues: [String] = []
        func check(_ ok: Bool, _ hotkey: Hotkey?, _ name: String) {
            if !ok, let hotkey { issues.append("\(hotkey.display) (\(name)) is taken by another app or shortcut.") }
        }
        check(center.register(.dictate, settings.dictateHotkey,
                              pressed: { [weak self] in self?.dictation.shortcutPressed(.dictate) },
                              released: { [weak self] in self?.dictation.shortcutReleased() }),
              settings.dictateHotkey, "dictate")
        check(center.register(.edit, settings.editHotkey,
                              pressed: { [weak self] in self?.dictation.shortcutPressed(.edit) },
                              released: { [weak self] in self?.dictation.shortcutReleased() }),
              settings.editHotkey, "edit by voice")
        check(center.register(.pasteLast, settings.pasteLastHotkey,
                              pressed: { [weak self] in self?.dictation.pasteLast() }),
              settings.pasteLastHotkey, "paste last")
        runtime.hotkeyIssues = issues
    }

    /// Global key monitors only start delivering once Accessibility is
    /// granted, so reinstall the push-to-talk monitor when that happens.
    private func watchAccessibilityTrust() {
        trustTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let trusted = Accessibility.isTrusted
                if trusted != self.runtime.accessibilityTrusted {
                    self.runtime.accessibilityTrusted = trusted
                    if trusted {
                        self.holdMonitor.update(key: .off)
                        self.holdMonitor.update(key: self.settings.holdKey)
                    }
                }
            }
        }
    }

    // MARK: Status item

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item
        updateStatusIcon(.idle)
    }

    private func updateStatusIcon(_ phase: DictationController.Phase) {
        let symbol: String
        switch phase {
        case .idle: symbol = "waveform"
        case .starting, .recording: symbol = "waveform.circle.fill"
        case .processing: symbol = "ellipsis.circle"
        }
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Murmur")
        image?.isTemplate = true
        statusItem?.button?.image = image
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let phase = dictation.phase

        let status: String
        switch phase {
        case .idle:
            status = settings.dictateHotkey.map { "Ready — press \($0.display) to dictate" } ?? "Ready"
        case .starting, .recording: status = "Listening…"
        case .processing: status = "Working…"
        }
        menu.addItem(disabled(status))
        if !runtime.accessibilityTrusted {
            menu.addItem(item("⚠︎ Allow Accessibility to paste…", #selector(openSetup)))
        }
        menu.addItem(.separator())

        let dictateTitle = phase == .idle ? "Start Dictation" : "Finish Dictation"
        menu.addItem(item(dictateTitle + shortcutSuffix(settings.dictateHotkey), #selector(toggleDictation)))
        menu.addItem(item("Edit Selection by Voice" + shortcutSuffix(settings.editHotkey), #selector(toggleEdit), enabled: phase == .idle))
        menu.addItem(item("Paste Last Transcript" + shortcutSuffix(settings.pasteLastHotkey), #selector(pasteLast), enabled: phase == .idle && history.lastSuccessful != nil))
        if phase != .idle {
            menu.addItem(item("Cancel", #selector(cancelDictation)))
        }
        menu.addItem(.separator())

        let polishMenu = NSMenu()
        addPolish(polishMenu, "Off", .off)
        addPolish(polishMenu, "Clean up", .cleanup)
        if !settings.customModes.isEmpty { polishMenu.addItem(.separator()) }
        for mode in settings.customModes { addPolish(polishMenu, mode.name, .custom(mode.id)) }
        polishMenu.addItem(.separator())
        polishMenu.addItem(item("Edit Modes…", #selector(openAI)))
        let polishItem = NSMenuItem(title: "AI Polish: \(settings.activePolish?.name ?? "Off")", action: nil, keyEquivalent: "")
        polishItem.submenu = polishMenu
        menu.addItem(polishItem)

        let languageMenu = NSMenu()
        var quickLanguages = ["auto", "en-US", "zh-TW"]
        if !quickLanguages.contains(settings.language) { quickLanguages.append(settings.language) }
        for code in quickLanguages {
            let entry = item(languageName(code), #selector(selectLanguage(_:)))
            entry.representedObject = code
            entry.state = settings.language == code ? .on : .off
            languageMenu.addItem(entry)
        }
        languageMenu.addItem(.separator())
        languageMenu.addItem(item("More Languages…", #selector(openTranscription)))
        let languageItem = NSMenuItem(title: "Language: \(languageName(settings.language))", action: nil, keyEquivalent: "")
        languageItem.submenu = languageMenu
        menu.addItem(languageItem)

        let recentMenu = NSMenu()
        let recent = history.entries.filter { !$0.failed }.prefix(8)
        if recent.isEmpty { recentMenu.addItem(disabled("No dictations yet")) }
        for entry in recent {
            let preview = entry.text.replacingOccurrences(of: "\n", with: " ")
            let recentItem = item(preview.count > 60 ? String(preview.prefix(57)) + "…" : preview, #selector(copyRecent(_:)))
            recentItem.representedObject = entry.text
            recentItem.toolTip = "Click to copy"
            recentMenu.addItem(recentItem)
        }
        recentMenu.addItem(.separator())
        recentMenu.addItem(item("Show History…", #selector(openHistory)))
        let recentItem = NSMenuItem(title: "Recent", action: nil, keyEquivalent: "")
        recentItem.submenu = recentMenu
        menu.addItem(recentItem)
        menu.addItem(item("Transcribe Audio File…", #selector(transcribeFile), enabled: phase == .idle))
        menu.addItem(.separator())
        menu.addItem(item("Settings…", #selector(openSettings), key: ","))
        menu.addItem(item("Quit Murmur", #selector(NSApplication.terminate(_:)), key: "q", target: NSApp))
    }

    private func languageName(_ code: String) -> String {
        code == "auto" ? "Auto-detect" : languageOptions.first { $0.code == code }?.name ?? code
    }

    private func addPolish(_ menu: NSMenu, _ title: String, _ mode: PolishMode) {
        let entry = item(title, #selector(selectPolish(_:)))
        entry.representedObject = mode.storage
        entry.state = settings.polishMode == mode ? .on : .off
        menu.addItem(entry)
    }

    private func item(_ title: String, _ action: Selector, key: String = "", enabled: Bool = true, target: AnyObject? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = target ?? self
        item.isEnabled = enabled
        return item
    }

    private func disabled(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func shortcutSuffix(_ hotkey: Hotkey?) -> String {
        hotkey.map { "    \($0.display)" } ?? ""
    }

    // MARK: Actions

    @objc private func toggleDictation() { dictation.toggleFromMenu(.dictate) }
    @objc private func toggleEdit() { dictation.toggleFromMenu(.edit) }
    @objc private func pasteLast() { dictation.pasteLast() }
    @objc private func cancelDictation() { dictation.cancel() }
    @objc private func openSettings() { showSettings(tab: runtime.settingsTab == .setup && settings.hasCompletedOnboarding ? .general : runtime.settingsTab) }
    @objc private func openSetup() { showSettings(tab: .setup) }
    @objc private func openAI() { showSettings(tab: .ai) }
    @objc private func openHistory() { showSettings(tab: .history) }

    @objc private func openTranscription() { showSettings(tab: .transcription) }

    @objc private func selectLanguage(_ sender: NSMenuItem) {
        if let code = sender.representedObject as? String { settings.language = code }
    }

    @objc private func selectPolish(_ sender: NSMenuItem) {
        guard let storage = sender.representedObject as? String else { return }
        settings.polishMode = PolishMode(storage: storage)
        if settings.polishMode != .off, Secrets.get(.anthropic) == nil { showSettings(tab: .ai) }
    }

    @objc private func copyRecent(_ sender: NSMenuItem) {
        guard let text = sender.representedObject as? String else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    @objc private func transcribeFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio, .movie]
        panel.allowsMultipleSelection = false
        panel.message = "Choose a recording to transcribe. The transcript is copied to the clipboard."
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        dictation.transcribeFile(url)
    }

    func showSettings(tab: SettingsTab) {
        runtime.settingsTab = tab
        if settingsWindow == nil {
            let root = SettingsView(dictation: dictation)
                .environmentObject(settings)
                .environmentObject(history)
                .environmentObject(runtime)
            let window = NSWindow(contentViewController: NSHostingController(rootView: root))
            window.title = "Murmur"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            window.toolbarStyle = .unified
            window.setContentSize(NSSize(width: 820, height: 620))
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    /// A menu-bar app shows no menu bar, but text fields still need the Edit
    /// menu's key equivalents (⌘C, ⌘V, ⌘A, ⌘Z) to work.
    private func makeMainMenu() -> NSMenu {
        let main = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        appMenu.addItem(withTitle: "Quit Murmur", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)
        return main
    }
}

enum LaunchAtLogin {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    /// Returns a message for the user when it didn't simply work.
    static func set(_ enabled: Bool) -> String? {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            return error.localizedDescription
        }
        if enabled, SMAppService.mainApp.status == .requiresApproval {
            SMAppService.openSystemSettingsLoginItems()
            return "Approve Murmur under System Settings → General → Login Items."
        }
        return nil
    }
}
