import AppKit
import ApplicationServices
import Carbon.HIToolbox
import MurmurCore

/// Where the user is typing, captured when a recording starts.
struct AppContext {
    var appName: String?
    var bundleID: String?
    var windowTitle: String?
    var caret: CaretContext?
    /// The selection as Accessibility reports it: nil when the app doesn't
    /// expose it, "" when a standard text field reports no selection.
    var selectedText: String?

    var insertion: InsertionContext {
        InsertionContext(appName: appName, windowTitle: windowTitle, caret: caret)
    }
}

/// Reads the focused app's UI through the Accessibility API. Every call can
/// block on an unresponsive app for up to the messaging timeout, so call these
/// off the main thread.
enum Accessibility {
    static var isTrusted: Bool { AXIsProcessTrusted() }

    static func requestTrust() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    private static let messagingTimeout: Float = 0.25
    private static let caretWindow = 64
    private static let webEnabledLock = NSLock()
    nonisolated(unsafe) private static var webEnabledPIDs = Set<pid_t>()

    static func context(pid: pid_t, appName: String?, bundleID: String?, readCaret: Bool, readSelection: Bool) -> AppContext {
        var context = AppContext(appName: appName, bundleID: bundleID)
        guard isTrusted else { return context }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, messagingTimeout)
        enableWebAccessibility(app, pid: pid)

        if let window = element(app, kAXFocusedWindowAttribute) {
            context.windowTitle = attribute(window, kAXTitleAttribute) as? String
        }
        guard readCaret || readSelection, let focused = focusedElement(app) else { return context }
        if isSecure(focused) { return context }
        if readCaret { context.caret = caretContext(focused) }
        if readSelection { context.selectedText = selection(focused) }
        return context
    }

    private static let standardTextRoles: Set<String> = [
        kAXTextFieldRole as String, kAXTextAreaRole as String, kAXComboBoxRole as String, "AXSearchField",
    ]

    /// An empty selection is only trusted from standard text roles; elsewhere
    /// (web areas, custom editors) "" often just means "not exposed".
    private static func selection(_ element: AXUIElement) -> String? {
        if let selected = attribute(element, kAXSelectedTextAttribute) as? String, !selected.isEmpty {
            return selected
        }
        guard let role = attribute(element, kAXRoleAttribute) as? String, standardTextRoles.contains(role),
              let value = attribute(element, kAXSelectedTextRangeAttribute),
              CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        // swiftlint:disable:next force_cast
        guard AXValueGetValue(value as! AXValue, .cfRange, &range) else { return nil }
        return range.length == 0 ? "" : nil
    }

    /// Chromium and Electron apps build their accessibility tree only when
    /// asked; this flag asks without the side effects of AXEnhancedUserInterface.
    private static func enableWebAccessibility(_ app: AXUIElement, pid: pid_t) {
        webEnabledLock.lock()
        let isNew = webEnabledPIDs.insert(pid).inserted
        webEnabledLock.unlock()
        if isNew {
            AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        }
    }

    private static func focusedElement(_ app: AXUIElement) -> AXUIElement? {
        if let focused = element(app, kAXFocusedUIElementAttribute) { return focused }
        let systemWide = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(systemWide, messagingTimeout)
        return element(systemWide, kAXFocusedUIElementAttribute)
    }

    private static func isSecure(_ element: AXUIElement) -> Bool {
        let secure = kAXSecureTextFieldSubrole as String
        return attribute(element, kAXRoleAttribute) as? String == secure
            || attribute(element, kAXSubroleAttribute) as? String == secure
    }

    private static func caretContext(_ element: AXUIElement) -> CaretContext? {
        guard let value = attribute(element, kAXSelectedTextRangeAttribute),
              CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var selection = CFRange()
        // swiftlint:disable:next force_cast
        guard AXValueGetValue(value as! AXValue, .cfRange, &selection), selection.location >= 0 else { return nil }

        let beforeStart = max(0, selection.location - caretWindow)
        let afterStart = selection.location + selection.length
        var afterLength = caretWindow
        if let total = attribute(element, kAXNumberOfCharactersAttribute) as? Int {
            afterLength = max(0, min(caretWindow, total - afterStart))
        }
        guard let before = string(element, CFRange(location: beforeStart, length: selection.location - beforeStart)),
              let after = string(element, CFRange(location: afterStart, length: afterLength)) else { return nil }
        return CaretContext(before: before, after: after)
    }

    private static func string(_ element: AXUIElement, _ range: CFRange) -> String? {
        guard range.length > 0 else { return "" }
        var range = range
        if let axRange = AXValueCreate(.cfRange, &range) {
            var value: CFTypeRef?
            if AXUIElementCopyParameterizedAttributeValue(element, kAXStringForRangeParameterizedAttribute as CFString, axRange, &value) == .success,
               let text = value as? String {
                return text
            }
        }
        guard let full = attribute(element, kAXValueAttribute) as? String else { return nil }
        let ns = full as NSString
        let location = min(range.location, ns.length)
        return ns.substring(with: NSRange(location: location, length: min(range.length, ns.length - location)))
    }

    private static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }

    private static func element(_ parent: AXUIElement, _ name: String) -> AXUIElement? {
        guard let value = attribute(parent, name), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        // swiftlint:disable:next force_cast
        return (value as! AXUIElement)
    }
}

/// Everything on the pasteboard, so a paste can put the user's clipboard back.
struct PasteboardSnapshot {
    private let items: [[NSPasteboard.PasteboardType: Data]]

    init(_ pasteboard: NSPasteboard) {
        items = (pasteboard.pasteboardItems ?? []).map { item in
            var entry: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) { entry[type] = data }
            }
            return entry
        }
    }

    func restore(to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        guard !items.isEmpty else { return }
        let restored = items.map { entry -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in entry { item.setData(data, forType: type) }
            return item
        }
        pasteboard.writeObjects(restored)
    }
}

/// Puts text into the focused app by pasting, which works everywhere a user
/// can paste: native apps, browsers, Electron apps, terminals.
@MainActor
enum TextInserter {
    enum Outcome { case pasted, copiedOnly }

    /// Marks our temporary clipboard write so clipboard managers skip it.
    private static let transientType = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")

    /// The user's clipboard while one of our temporary writes is on it, and
    /// the task that will put it back. Back-to-back pastes or copies reuse
    /// this snapshot instead of snapshotting our own transient text.
    private static var pending: (snapshot: PasteboardSnapshot, restore: Task<Void, Never>)?

    /// Takes ownership of the user's real clipboard contents.
    private static func takeUserClipboard(_ pasteboard: NSPasteboard) -> PasteboardSnapshot {
        if let pending {
            pending.restore.cancel()
            self.pending = nil
            return pending.snapshot
        }
        return PasteboardSnapshot(pasteboard)
    }

    /// Restores `snapshot` after `delay` unless the clipboard changed again
    /// (more than `expectedChanges` times) in the meantime.
    private static func scheduleRestore(_ snapshot: PasteboardSnapshot, after delay: TimeInterval, ifChangeCountIs expected: Int) {
        let pasteboard = NSPasteboard.general
        let task = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            if pasteboard.changeCount == expected { snapshot.restore(to: pasteboard) }
            pending = nil
        }
        pending = (snapshot, task)
    }

    static func insert(_ text: String, preserveClipboard: Bool) async -> Outcome {
        let pasteboard = NSPasteboard.general
        let snapshot: PasteboardSnapshot? = preserveClipboard ? takeUserClipboard(pasteboard) : nil
        if !preserveClipboard, let pending {
            pending.restore.cancel()
            self.pending = nil
        }
        // Without Accessibility we can't send ⌘V; leave the text on the
        // clipboard for the user to paste.
        guard Accessibility.isTrusted else {
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
            return .copiedOnly
        }
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        if preserveClipboard { pasteboard.setData(Data(), forType: transientType) }
        await waitForModifierRelease()
        KeySender.press(KeySender.keyCode(for: "v") ?? CGKeyCode(kVK_ANSI_V), flags: .maskCommand)
        Log.insertion.info("pasted \(text.count) characters")

        // Give the target app time to read the clipboard, then put the
        // user's content back unless something else replaced ours.
        if let snapshot { scheduleRestore(snapshot, after: 0.8, ifChangeCountIs: pasteboard.changeCount) }
        return .pasted
    }

    /// Copies the current selection with ⌘C and restores the clipboard.
    static func copySelection() async -> String? {
        guard Accessibility.isTrusted else { return nil }
        let pasteboard = NSPasteboard.general
        let clipboardIsOurs = pending != nil
        let snapshot = takeUserClipboard(pasteboard)
        let before = pasteboard.changeCount
        await waitForModifierRelease(timeout: 0.4)
        KeySender.press(KeySender.keyCode(for: "c") ?? CGKeyCode(kVK_ANSI_C), flags: .maskCommand)
        var copied: String?
        for _ in 0..<15 {
            try? await Task.sleep(nanoseconds: 40_000_000)
            if pasteboard.changeCount != before {
                copied = pasteboard.string(forType: .string)
                break
            }
        }
        if pasteboard.changeCount != before {
            snapshot.restore(to: pasteboard)
        } else {
            // Nothing copied. Put the user's clipboard back if our last paste
            // still occupies it, and undo a slow app's late answer to ⌘C.
            if clipboardIsOurs { snapshot.restore(to: pasteboard) }
            scheduleRestore(snapshot, after: 1.0, ifChangeCountIs: pasteboard.changeCount + 1)
        }
        guard let copied, !copied.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return copied
    }

    /// The hotkey's modifiers may still be held; a ⌘V sent alongside a held ⌥
    /// means "paste and match style" or nothing at all in some apps.
    private static func waitForModifierRelease(timeout: TimeInterval = 1.0) async {
        let deadline = Date().addingTimeInterval(timeout)
        let held: CGEventFlags = [.maskCommand, .maskAlternate, .maskControl, .maskShift, .maskSecondaryFn]
        while !CGEventSource.flagsState(.combinedSessionState).intersection(held).isEmpty, Date() < deadline {
            try? await Task.sleep(nanoseconds: 15_000_000)
        }
    }
}

@MainActor
enum KeySender {
    static func press(_ keyCode: CGKeyCode, flags: CGEventFlags) {
        let source = CGEventSource(stateID: .combinedSessionState)
        let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        down?.flags = flags
        up?.flags = flags
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }

    /// The virtual key that types `character` in the current keyboard layout,
    /// so ⌘V still means paste on Dvorak or AZERTY. Nil for layouts without
    /// that letter (Cyrillic, Greek…), where macOS matches shortcuts by ANSI
    /// position anyway.
    static func keyCode(for character: Character) -> CGKeyCode? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let layoutData = Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue() as Data
        let keyboardType = UInt32(LMGetKbdType())
        return layoutData.withUnsafeBytes { raw -> CGKeyCode? in
            guard let layout = raw.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return nil }
            for code in 0..<128 {
                var deadKeyState: UInt32 = 0
                var chars = [UniChar](repeating: 0, count: 4)
                var length = 0
                let status = UCKeyTranslate(
                    layout, UInt16(code), UInt16(kUCKeyActionDisplay), 0, keyboardType,
                    OptionBits(kUCKeyTranslateNoDeadKeysBit), &deadKeyState, chars.count, &length, &chars
                )
                if status == noErr, length == 1, let scalar = UnicodeScalar(chars[0]), Character(scalar) == character {
                    return CGKeyCode(code)
                }
            }
            return nil
        }
    }
}
