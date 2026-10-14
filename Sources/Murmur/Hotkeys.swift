import AppKit
import Carbon.HIToolbox

/// System-wide shortcuts through Carbon's RegisterEventHotKey, which needs no
/// Accessibility permission and consumes the key press so it never reaches
/// the focused app.
@MainActor
final class HotkeyCenter {
    static let shared = HotkeyCenter()

    enum ID: UInt32 {
        case dictate = 1, edit, pasteLast, escape
    }

    private struct Binding {
        let hotkey: Hotkey
        let pressed: () -> Void
        let released: (() -> Void)?
    }

    private static let signature: OSType = 0x4D52_4D52 // "MRMR"
    private var bindings: [UInt32: Binding] = [:]
    private var refs: [UInt32: EventHotKeyRef] = [:]
    private var down = Set<UInt32>()
    private var handlerRef: EventHandlerRef?
    private var suspended = false

    /// Returns false when the shortcut is invalid or another app already owns it.
    @discardableResult
    func register(_ id: ID, _ hotkey: Hotkey?, pressed: @escaping () -> Void, released: (() -> Void)? = nil) -> Bool {
        unregister(id)
        guard let hotkey else { return true }
        bindings[id.rawValue] = Binding(hotkey: hotkey, pressed: pressed, released: released)
        return suspended || activate(id.rawValue)
    }

    func unregister(_ id: ID) {
        deactivate(id.rawValue)
        bindings[id.rawValue] = nil
    }

    /// Releases every shortcut while the settings window records a new one.
    func suspend() {
        guard !suspended else { return }
        suspended = true
        bindings.keys.forEach(deactivate)
    }

    func resume() {
        guard suspended else { return }
        suspended = false
        bindings.keys.forEach { _ = activate($0) }
    }

    private func activate(_ id: UInt32) -> Bool {
        guard let binding = bindings[id] else { return false }
        installHandlerIfNeeded()
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            binding.hotkey.keyCode, binding.hotkey.modifiers,
            EventHotKeyID(signature: Self.signature, id: id),
            GetApplicationEventTarget(), 0, &ref
        )
        guard status == noErr, let ref else {
            Log.app.error("hotkey \(binding.hotkey.display, privacy: .public) not registered: \(status)")
            return false
        }
        refs[id] = ref
        return true
    }

    private func deactivate(_ id: UInt32) {
        if let ref = refs.removeValue(forKey: id) { UnregisterEventHotKey(ref) }
        down.remove(id)
    }

    fileprivate func dispatch(id: UInt32, pressed: Bool) {
        guard let binding = bindings[id], refs[id] != nil else { return }
        if pressed {
            // Ignore auto-repeat while the key stays down.
            guard down.insert(id).inserted else { return }
            binding.pressed()
        } else {
            down.remove(id)
            binding.released?()
        }
    }

    private func installHandlerIfNeeded() {
        guard handlerRef == nil else { return }
        var types = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased)),
        ]
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            guard let event else { return OSStatus(eventNotHandledErr) }
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(
                event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID
            )
            guard status == noErr, hotKeyID.signature == HotkeyCenter.signature else { return OSStatus(eventNotHandledErr) }
            let pressed = GetEventKind(event) == UInt32(kEventHotKeyPressed)
            let id = hotKeyID.id
            // Carbon delivers application-target events on the main thread.
            MainActor.assumeIsolated { HotkeyCenter.shared.dispatch(id: id, pressed: pressed) }
            return noErr
        }, types.count, &types, nil, &handlerRef)
    }
}

/// Push-to-talk on a lone modifier key (e.g. Right Option). Recording starts
/// once the key has been held briefly with nothing else pressed, so ordinary
/// shortcuts that use the same modifier don't trigger it.
@MainActor
final class ModifierHoldMonitor {
    var onBegin: (() -> Void)?
    var onEnd: (() -> Void)?

    private var key: HoldKey = .off
    private var monitors: [Any] = []
    private var isDown = false
    private var began = false
    private var pending: DispatchWorkItem?
    private let holdDelay: TimeInterval = 0.22

    func update(key: HoldKey) {
        guard key != self.key || monitors.isEmpty else { return }
        stop()
        self.key = key
        guard key != .off else { return }
        let mask: NSEvent.EventTypeMask = [.flagsChanged, .keyDown]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
        }) {
            monitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            self?.handle(event)
            return event
        }) {
            monitors.append(local)
        }
    }

    func stop() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
        pending?.cancel()
        pending = nil
        if began { onEnd?() }
        isDown = false
        began = false
    }

    private func handle(_ event: NSEvent) {
        if event.type == .keyDown {
            // A chord like ⌥E, not a push-to-talk hold.
            if isDown && !began { pending?.cancel(); pending = nil }
            return
        }
        let otherModifiers = event.modifierFlags.intersection([.command, .control, .shift, .option, .function])
            .subtracting(key.ownFlag)
        if event.keyCode != key.keyCode {
            if isDown && !began && !otherModifiers.isEmpty { pending?.cancel(); pending = nil }
            return
        }
        let nowDown = key.isDown(event.modifierFlags)
        if nowDown && !isDown {
            isDown = true
            guard otherModifiers.isEmpty else { return }
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.isDown, !self.began else { return }
                self.began = true
                self.onBegin?()
            }
            pending = work
            DispatchQueue.main.asyncAfter(deadline: .now() + holdDelay, execute: work)
        } else if !nowDown && isDown {
            isDown = false
            pending?.cancel()
            pending = nil
            if began {
                began = false
                onEnd?()
            }
        }
    }
}

private extension HoldKey {
    var ownFlag: NSEvent.ModifierFlags {
        switch self {
        case .off: return []
        case .rightOption: return .option
        case .rightCommand: return .command
        case .rightControl: return .control
        case .fn: return .function
        }
    }
}
