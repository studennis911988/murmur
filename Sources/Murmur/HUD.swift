import AppKit
import SwiftUI

@MainActor
final class HUDModel: ObservableObject {
    enum Phase: Equatable {
        case hidden
        case listening
        case working(String)
        case notice(String, isError: Bool)
    }

    static let barCount = 24

    @Published var phase: Phase = .hidden
    @Published var levels = [Float](repeating: 0, count: barCount)
    @Published var partial = ""
    @Published var badge: String?
    @Published var hint: String?
    @Published var startedAt = Date()

    var onStop: (() -> Void)?
    var onCancel: (() -> Void)?

    func push(level: Float) {
        levels.removeFirst()
        levels.append(level)
    }
}

/// The floating pill at the bottom of the screen. It never takes focus, so the
/// app being dictated into stays frontmost and receives the paste.
@MainActor
final class HUDController {
    let model = HUDModel()
    private var panel: NSPanel?
    private var hideWork: DispatchWorkItem?
    private static let size = NSSize(width: 480, height: 160)

    func showListening(badge: String?) {
        model.partial = ""
        model.hint = nil
        model.badge = badge
        model.levels = [Float](repeating: 0, count: HUDModel.barCount)
        model.startedAt = Date()
        model.phase = .listening
        present()
    }

    func showWorking(_ message: String) {
        model.phase = .working(message)
        present()
    }

    func notice(_ message: String, isError: Bool = false, duration: TimeInterval = 2.4) {
        model.phase = .notice(message, isError: isError)
        present()
        let work = DispatchWorkItem { [weak self] in self?.hide() }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
    }

    func hide() {
        hideWork?.cancel()
        hideWork = nil
        model.phase = .hidden
        panel?.orderOut(nil)
    }

    private func present() {
        hideWork?.cancel()
        hideWork = nil
        let panel = self.panel ?? makePanel()
        if !panel.isVisible { position(panel) }
        panel.orderFrontRegardless()
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: Self.size),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isReleasedWhenClosed = false
        let host = FirstClickHostingView(rootView: HUDView(model: model))
        host.frame = NSRect(origin: .zero, size: Self.size)
        panel.contentView = host
        self.panel = panel
        return panel
    }

    /// Bottom-center of the screen with the mouse pointer, above the Dock.
    private func position(_ panel: NSPanel) {
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        panel.setFrameOrigin(NSPoint(x: visible.midX - Self.size.width / 2, y: visible.minY + 24))
    }
}

/// The panel is never key, so let its buttons act on the first click.
private final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

struct HUDView: View {
    @ObservedObject var model: HUDModel

    var body: some View {
        VStack(spacing: 8) {
            Spacer(minLength: 0)
            if model.phase == .listening, !model.partial.isEmpty {
                Text(model.partial)
                    .font(.system(size: 13))
                    .lineLimit(2)
                    .truncationMode(.head)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .frame(maxWidth: 440)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .transition(.opacity)
            }
            if model.phase != .hidden {
                pill.transition(.opacity.combined(with: .scale(scale: 0.96)))
            }
        }
        .padding(.bottom, 10)
        .frame(width: 480, height: 160, alignment: .bottom)
        .animation(.easeOut(duration: 0.15), value: model.phase)
        .animation(.easeOut(duration: 0.1), value: model.partial.isEmpty)
    }

    private var pill: some View {
        HStack(spacing: 10) {
            switch model.phase {
            case .hidden:
                EmptyView()
            case .listening:
                PulsingDot()
                if let badge = model.badge {
                    Text(badge)
                        .font(.system(size: 11, weight: .semibold))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(Color.accentColor.opacity(0.25), in: Capsule())
                }
                if let hint = model.hint {
                    Text(hint).font(.system(size: 12)).foregroundStyle(.orange)
                } else {
                    Waveform(levels: model.levels).frame(height: 22)
                }
                TimelineView(.periodic(from: model.startedAt, by: 1)) { context in
                    Text(elapsed(since: model.startedAt, now: context.date))
                        .font(.system(size: 12).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                HUDButton(symbol: "xmark", help: "Cancel (Esc)") { model.onCancel?() }
                HUDButton(symbol: "checkmark", help: "Finish", prominent: true) { model.onStop?() }
            case .working(let message):
                ProgressView().controlSize(.small)
                Text(message).font(.system(size: 13, weight: .medium))
                HUDButton(symbol: "xmark", help: "Cancel (Esc)") { model.onCancel?() }
            case .notice(let message, let isError):
                Image(systemName: isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .foregroundStyle(isError ? Color.orange : Color.green)
                Text(message)
                    .font(.system(size: 13))
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 360, alignment: .leading)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(.white.opacity(0.12)))
        .shadow(color: .black.opacity(0.25), radius: 10, y: 4)
    }

    private func elapsed(since start: Date, now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(start)))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

private struct Waveform: View {
    let levels: [Float]

    var body: some View {
        HStack(alignment: .center, spacing: 2) {
            ForEach(levels.indices, id: \.self) { index in
                Capsule()
                    .fill(Color.primary.opacity(0.75))
                    .frame(width: 3, height: max(3, CGFloat(levels[index]) * 22))
            }
        }
        .animation(.linear(duration: 0.05), value: levels)
    }
}

private struct PulsingDot: View {
    @State private var dim = false

    var body: some View {
        Circle()
            .fill(Color.red)
            .frame(width: 9, height: 9)
            .opacity(dim ? 0.35 : 1)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) { dim = true }
            }
    }
}

private struct HUDButton: View {
    let symbol: String
    let help: String
    var prominent = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .bold))
                .frame(width: 22, height: 22)
                .background(prominent ? Color.accentColor : Color.primary.opacity(0.12), in: Circle())
                .foregroundStyle(prominent ? Color.white : Color.primary)
        }
        .buttonStyle(.plain)
        .help(help)
    }
}
