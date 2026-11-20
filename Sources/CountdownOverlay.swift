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

    /// Small HUD centered over the area about to be recorded, clamped inside
    /// `screenFrame` when provided so windows near or past a display edge do
    /// not clip the HUD off-screen.
    static func hudFrame(referenceFrame: CGRect, screenFrame: CGRect? = nil) -> CGRect {
        var x = referenceFrame.midX - hudSize / 2
        var y = referenceFrame.midY - hudSize / 2
        if let screenFrame {
            let maxX = max(screenFrame.minX, screenFrame.maxX - hudSize)
            let maxY = max(screenFrame.minY, screenFrame.maxY - hudSize)
            x = min(max(x, screenFrame.minX), maxX)
            y = min(max(y, screenFrame.minY), maxY)
        }
        return CGRect(
            x: x,
            y: y,
            width: hudSize,
            height: hudSize
        )
    }

    /// Picks the screen frame containing `referenceFrame`'s center, falling
    /// back to the screen with the largest overlap and then the primary screen.
    static func containingScreenFrame(for referenceFrame: CGRect, screens: [CGRect]) -> CGRect? {
        let center = CGPoint(x: referenceFrame.midX, y: referenceFrame.midY)
        if let containing = screens.first(where: { $0.contains(center) }) {
            return containing
        }
        let bestOverlap =
            screens
            .map { screen -> (CGRect, CGFloat) in
                let overlap = screen.intersection(referenceFrame)
                let area = overlap.isNull ? 0 : overlap.width * overlap.height
                return (screen, area)
            }
            .max { $0.1 < $1.1 }
        if let bestOverlap, bestOverlap.1 > 0 {
            return bestOverlap.0
        }
        return screens.first
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
    private var isShowing = false
    private var sleepTask: Task<Void, Never>?
    private let tickDuration: Duration
    private let cancelDisplayDuration: Duration

    init(
        tickDuration: Duration = .seconds(1),
        cancelDisplayDuration: Duration = .milliseconds(500)
    ) {
        self.tickDuration = tickDuration
        self.cancelDisplayDuration = cancelDisplayDuration
    }

    /// Cancels a countdown in progress (e.g. the hotkey was pressed again).
    func cancel() {
        cancelled = true
        sleepTask?.cancel()
    }

    /// Shows the countdown and returns true when recording should start.
    /// A duration of 0 means the countdown is disabled and recording starts
    /// immediately. Cancellable by clicking the HUD or calling cancel().
    func show(targetFrame: CGRect? = nil, duration: Int) async -> Bool {
        guard duration > 0 else { return true }
        guard !isShowing else {
            logger.warning("Countdown is already showing; ignoring overlapping call")
            return false
        }
        isShowing = true
        defer { isShowing = false }
        cancelled = false

        let referenceFrame: NSRect
        let screenFrame: NSRect?
        if let targetFrame {
            guard let converted = cocoaRect(fromQuartz: targetFrame) else {
                logger.error("Cannot show countdown: no screens available for coordinate conversion")
                return false
            }
            referenceFrame = converted
            screenFrame = CountdownLayout.containingScreenFrame(
                for: converted,
                screens: NSScreen.screens.map(\.frame)
            )
        } else if let screen = NSScreen.main {
            referenceFrame = screen.frame
            screenFrame = screen.frame
        } else {
            logger.error("Cannot show countdown: no target frame and no main screen available")
            return false
        }

        let hudFrame = CountdownLayout.hudFrame(
            referenceFrame: referenceFrame,
            screenFrame: screenFrame
        )

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
            self?.cancel()
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
            window.close()
            self.window = nil
        }

        let clock = ContinuousClock()
        var nextDeadline = clock.now
        var interrupted = false

        for count in CountdownLayout.sequence(duration: duration) {
            if cancelled || Task.isCancelled {
                interrupted = !cancelled
                break
            }
            withAnimation(.snappy) {
                model.count = count
            }
            model.tickStart = Date()
            nextDeadline = nextDeadline.advanced(by: tickDuration)

            let completedTick = await waitUntil(deadline: nextDeadline, clock: clock)
            if !completedTick {
                interrupted = !cancelled
                break
            }
        }

        if cancelled {
            model.isCancelled = true
            let displayDuration = cancelDisplayDuration
            await Task<Void, Never> {
                _ = try? await clock.sleep(for: displayDuration)
            }.value
        }

        return !cancelled && !interrupted
    }

    private func waitUntil(
        deadline: ContinuousClock.Instant,
        clock: ContinuousClock
    ) async -> Bool {
        guard !cancelled, !Task.isCancelled else { return false }

        let task = Task<Void, Never> { @MainActor in
            _ = try? await clock.sleep(until: deadline)
        }
        sleepTask = task
        defer {
            if sleepTask == task {
                sleepTask = nil
            }
            task.cancel()
        }

        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }

        return !cancelled && !Task.isCancelled
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
