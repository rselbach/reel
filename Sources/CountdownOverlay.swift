import AppKit
import SwiftUI
import os.log

private let logger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "com.rselbach.reel", category: "CountdownOverlay")

enum CountdownLayout {
    static let hudSize: CGFloat = 184

    static func sequence(duration: Int) -> [Int] {
        guard duration > 0 else { return [] }
        return Array((1...duration).reversed())
    }

    /// Small HUD centered over the area about to be recorded.
    static func hudFrame(referenceFrame: CGRect) -> CGRect {
        CGRect(
            x: referenceFrame.midX - hudSize / 2,
            y: referenceFrame.midY - hudSize / 2,
            width: hudSize,
            height: hudSize
        )
    }

    /// The HUD never takes key focus, so Esc cannot reach it. Clicking it and
    /// pressing the recording shortcut again, when it is on, are the ways out.
    static func cancelHint(shortcut: String?) -> String {
        shortcut.map { "Click or press \($0) to cancel" } ?? "Click to cancel"
    }

    /// How much of the ring is left this second: full when a number
    /// appears, empty as the next one is due.
    static func ringRemaining(secondsIntoTick: TimeInterval) -> Double {
        min(1, max(0, 1 - secondsIntoTick))
    }
}

/// What the countdown HUD shows. Updated by the countdown loop.
@MainActor
final class CountdownModel: ObservableObject {
    @Published var count: Int
    @Published var isCancelled = false
    @Published var tickStart = Date()
    let hint: String

    init(count: Int, hint: String) {
        self.count = count
        self.hint = hint
    }
}

/// A system-style HUD: the number rolls down while a ring empties over each
/// second, so it is clear when recording will start.
struct CountdownHUDView: View {
    @ObservedObject var model: CountdownModel

    private let ringWidth: CGFloat = 6

    var body: some View {
        VStack(spacing: 10) {
            ZStack {
                Circle()
                    .stroke(.white.opacity(0.18), lineWidth: ringWidth)
                TimelineView(.animation(paused: model.isCancelled)) { context in
                    Circle()
                        .trim(
                            from: 0,
                            to: model.isCancelled
                                ? 0
                                : CountdownLayout.ringRemaining(
                                    secondsIntoTick: context.date.timeIntervalSince(model.tickStart)
                                )
                        )
                        .stroke(.white, style: StrokeStyle(lineWidth: ringWidth, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }
                if model.isCancelled {
                    Image(systemName: "xmark")
                        .font(.system(size: 40, weight: .semibold))
                } else {
                    Text("\(model.count)")
                        .font(.system(size: 56, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .contentTransition(.numericText(countsDown: true))
                }
            }
            .frame(width: 100, height: 100)

            Text(model.hint)
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.7))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .foregroundStyle(.white)
        .padding(.top, 6)
        .frame(width: CountdownLayout.hudSize, height: CountdownLayout.hudSize)
    }
}

@MainActor
class CountdownOverlay {
    private var window: CountdownWindow?
    private var cancelled = false

    /// Cancels a countdown in progress (e.g. the hotkey was pressed again).
    func cancel() {
        cancelled = true
    }

    /// Shows the countdown and returns true when recording should start.
    /// A duration of 0 means the countdown is disabled and recording starts
    /// immediately. Cancellable by clicking the HUD, pressing Esc, or calling
    /// cancel().
    func show(targetFrame: CGRect? = nil, duration: Int) async -> Bool {
        guard duration > 0 else { return true }
        cancelled = false

        let referenceFrame: NSRect
        if let targetFrame {
            guard let converted = cocoaRect(fromQuartz: targetFrame) else {
                logger.error("Cannot show countdown: no screens available for coordinate conversion")
                return false
            }
            referenceFrame = converted
        } else if let screen = NSScreen.main {
            referenceFrame = screen.frame
        } else {
            logger.error("Cannot show countdown: no target frame and no main screen available")
            return false
        }

        let hudFrame = CountdownLayout.hudFrame(referenceFrame: referenceFrame)

        let window = CountdownWindow(
            contentRect: hudFrame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        window.level = .screenSaver
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.isReleasedWhenClosed = false
        // Reel is an accessory app and is rarely the active one; without this
        // the panel would vanish the moment focus returns to the demo target.
        window.hidesOnDeactivate = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let model = CountdownModel(
            count: duration,
            hint: CountdownLayout.cancelHint(shortcut: AppSettings.shared.recordingHotkey?.displayString)
        )
        let content = CountdownContentView(frame: NSRect(origin: .zero, size: hudFrame.size))
        content.onClick = { [weak self] in
            self?.cancelled = true
        }

        // The blur system HUDs use, rather than a flat black box, darkened
        // so white text stays legible over a white document.
        let background = NSVisualEffectView(frame: content.bounds)
        background.material = .hudWindow
        background.blendingMode = .behindWindow
        background.state = .active
        background.appearance = NSAppearance(named: .darkAqua)
        background.wantsLayer = true
        background.layer?.cornerRadius = 36
        background.layer?.masksToBounds = true
        background.autoresizingMask = [.width, .height]
        content.addSubview(background)

        let tint = NSView(frame: content.bounds)
        tint.wantsLayer = true
        tint.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.45).cgColor
        tint.layer?.cornerRadius = 36
        tint.autoresizingMask = [.width, .height]
        content.addSubview(tint)

        let hud = NSHostingView(rootView: CountdownHUDView(model: model))
        hud.frame = content.bounds
        hud.autoresizingMask = [.width, .height]
        content.addSubview(hud)
        window.contentView = content

        // Deliberately not makeKeyAndOrderFront/activate: the whole point of
        // the countdown is to give the user time to leave the app they are
        // about to demo in front. Taking key or activating Reel here means
        // recording starts with the wrong window focused.
        window.orderFrontRegardless()

        self.window = window

        defer {
            window.orderOut(nil)
            self.window = nil
        }

        var interrupted = false
        countdown: for count in CountdownLayout.sequence(duration: duration) {
            if cancelled { break }
            withAnimation(.snappy) {
                model.count = count
            }
            model.tickStart = Date()
            // Sleep in short slices so cancellation reacts promptly.
            for _ in 0..<10 {
                if cancelled { break countdown }
                do {
                    try await Task.sleep(for: .milliseconds(100))
                } catch {
                    logger.warning("Countdown sleep interrupted: \(error.localizedDescription)")
                    interrupted = true
                    break countdown
                }
            }
        }

        if cancelled {
            model.isCancelled = true
            do {
                try await Task.sleep(for: .milliseconds(500))
            } catch {
                logger.warning("Countdown cancel display interrupted: \(error.localizedDescription)")
            }
        }

        return !cancelled && !interrupted
    }
}

/// Non-activating panel: it floats above everything without making Reel the
/// active app, so the window the user is about to record keeps its focus.
class CountdownWindow: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Accepts the very first click even though the panel never becomes key, so a
/// single click on the HUD cancels instead of merely focusing it.
final class CountdownContentView: NSView {
    var onClick: (() -> Void)?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Keeps clicks here rather than in the hosted HUD, which would not get
    /// the first click of a panel that never becomes key.
    override func hitTest(_ point: NSPoint) -> NSView? {
        frame.contains(point) ? self : nil
    }

    override func mouseDown(with event: NSEvent) {
        onClick?()
    }
}
