import AppKit
import SwiftUI

/// Walks the user through a grant in System Settings. It opens the right
/// pane and moves Reel's window beside it so both stay in view. For the
/// screen recording list, which takes dropped apps, a copy of Reel's icon
/// then floats from the window into the list to show that it can be dragged
/// there.
@MainActor
final class SystemSettingsGuide {
    typealias AnimationRunner =
        @MainActor (TimeInterval, CAMediaTimingFunctionName, @MainActor @escaping () -> Void)
        async -> Void

    private static let settingsBundleID = "com.apple.systempreferences"

    private let openURL: (URL) -> Bool
    private let settingsWindowFrameProvider: () -> NSRect?
    private let sleep: (Duration) async throws -> Void
    private let shouldReduceMotion: () -> Bool
    private let animateStep: AnimationRunner

    private weak var window: NSWindow?
    private var phantom: NSPanel?
    private var generation: UInt64 = 0

    init(
        openURL: @escaping (URL) -> Bool = { NSWorkspace.shared.open($0) },
        settingsWindowFrameProvider: @escaping () -> NSRect? = { SystemSettingsGuide.liveSettingsWindowFrame() },
        sleep: @escaping (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        shouldReduceMotion: @escaping () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion },
        animateStep: @escaping AnimationRunner = { duration, timing, changes in
            await SystemSettingsGuide.liveAnimate(duration: duration, timing: timing, changes: changes)
        }
    ) {
        self.openURL = openURL
        self.settingsWindowFrameProvider = settingsWindowFrameProvider
        self.sleep = sleep
        self.shouldReduceMotion = shouldReduceMotion
        self.animateStep = animateStep
    }

    func begin(_ permission: PrivacyPermission, beside window: NSWindow) async throws {
        guard let url = permission.settingsURL, openURL(url) else {
            throw PermissionError.systemSettingsUnavailable(permission)
        }
        generation &+= 1
        let currentGeneration = generation
        phantom?.orderOut(nil)
        phantom = nil
        if self.window !== window {
            self.window?.level = .normal
        }
        self.window = window
        // Floating keeps the instructions in view while System Settings is
        // the active app.
        window.level = .floating

        guard let settingsFrame = await settledSettingsWindowFrame(generation: currentGeneration),
            isCurrent(currentGeneration)
        else { return }

        let screen = NSScreen.screens.first { $0.frame.intersects(settingsFrame) } ?? NSScreen.main
        if let visible = screen?.visibleFrame {
            let frame = GuideLayout.frame(for: window.frame.size, beside: settingsFrame, in: visible)
            window.setFrame(frame, display: true, animate: true)
        }

        guard isCurrent(currentGeneration),
            permission.acceptsDroppedApp,
            let icon = window.contentView?.firstSubview(of: AppIconDragSourceView.self),
            let iconFrame = icon.window?.convertToScreen(icon.convert(icon.bounds, to: nil))
        else { return }
        await showPhantom(
            from: iconFrame,
            to: GuideLayout.dropTarget(in: settingsFrame),
            generation: currentGeneration
        )
    }

    func end() {
        generation &+= 1
        window?.level = .normal
        window = nil
        phantom?.orderOut(nil)
        phantom = nil
    }

    private func isCurrent(_ expectedGeneration: UInt64) -> Bool {
        !Task.isCancelled && generation == expectedGeneration
    }

    /// System Settings takes a moment to open and switch panes, so this waits
    /// until its window holds still. Window bounds need no screen recording
    /// permission; only window titles do.
    private func settledSettingsWindowFrame(generation expectedGeneration: UInt64) async -> NSRect? {
        var previous: NSRect?
        for _ in 0..<50 {
            guard isCurrent(expectedGeneration) else { return nil }
            do {
                try await sleep(.milliseconds(100))
            } catch {
                return nil
            }
            guard isCurrent(expectedGeneration) else { return nil }
            guard let frame = settingsWindowFrameProvider() else { continue }
            if frame == previous {
                return frame
            }
            previous = frame
        }
        guard isCurrent(expectedGeneration) else { return nil }
        return previous
    }

    private static func liveSettingsWindowFrame() -> NSRect? {
        guard
            let pid = NSRunningApplication.runningApplications(withBundleIdentifier: Self.settingsBundleID).first?
                .processIdentifier,
            let infoList = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]]
        else { return nil }

        for info in infoList {
            guard info[kCGWindowOwnerPID as String] as? pid_t == pid,
                info[kCGWindowLayer as String] as? Int == 0,
                let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                let bounds = CGRect(dictionaryRepresentation: boundsDict)
            else { continue }
            return cocoaRect(fromQuartz: bounds)
        }
        return nil
    }

    private func showPhantom(from start: NSRect, to target: NSPoint, generation expectedGeneration: UInt64) async {
        guard isCurrent(expectedGeneration), !shouldReduceMotion() else { return }
        phantom?.orderOut(nil)

        let panel = NSPanel(
            contentRect: start,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle]
        let imageView = NSImageView(image: NSApplication.shared.applicationIconImage)
        imageView.imageScaling = .scaleProportionallyUpOrDown
        panel.contentView = imageView
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        phantom = panel

        defer {
            panel.orderOut(nil)
            if phantom === panel {
                phantom = nil
            }
        }

        // Lift the copy off the icon, carry it into the list, then let go.
        let lifted = start.insetBy(dx: -6, dy: -6)
        let landedSize = NSSize(width: start.width * 0.75, height: start.height * 0.75)
        let landed = NSRect(
            x: target.x - landedSize.width / 2,
            y: target.y - landedSize.height / 2,
            width: landedSize.width,
            height: landedSize.height
        )
        await animateStep(0.2, .easeOut) {
            panel.animator().alphaValue = 0.9
            panel.animator().setFrame(lifted, display: true)
        }
        guard isCurrent(expectedGeneration), phantom === panel else { return }
        do {
            try await sleep(.milliseconds(150))
        } catch {
            return
        }
        guard isCurrent(expectedGeneration), phantom === panel else { return }
        await animateStep(0.9, .easeInEaseOut) {
            panel.animator().setFrame(landed, display: true)
        }
        guard isCurrent(expectedGeneration), phantom === panel else { return }
        do {
            try await sleep(.milliseconds(450))
        } catch {
            return
        }
        guard isCurrent(expectedGeneration), phantom === panel else { return }
        await animateStep(0.35, .easeIn) {
            panel.animator().alphaValue = 0
        }
    }

    private static func liveAnimate(
        duration: TimeInterval,
        timing: CAMediaTimingFunctionName,
        changes: @escaping () -> Void
    ) async {
        await withCheckedContinuation { continuation in
            NSAnimationContext.runAnimationGroup { context in
                context.duration = duration
                context.timingFunction = CAMediaTimingFunction(name: timing)
                changes()
            } completionHandler: {
                continuation.resume()
            }
        }
    }
}

/// Where the guide puts things on screen, in Cocoa coordinates.
enum GuideLayout {
    static let gap: CGFloat = 16

    /// Beside System Settings: to its right when that fits, else to its left,
    /// else against the right edge of the screen, overlapping it.
    static func frame(for size: NSSize, beside settings: NSRect, in visible: NSRect) -> NSRect {
        let top = min(settings.maxY, visible.maxY)
        let y = max(visible.minY, top - size.height)
        return NSRect(
            x: x(for: size.width, beside: settings, in: visible), y: y, width: size.width, height: size.height)
    }

    private static func x(for width: CGFloat, beside settings: NSRect, in visible: NSRect) -> CGFloat {
        if settings.maxX + gap + width <= visible.maxX {
            return settings.maxX + gap
        }
        if settings.minX - gap - width >= visible.minX {
            return settings.minX - gap - width
        }
        return visible.maxX - width
    }

    /// The middle of the app list in a Privacy & Security pane, right of the
    /// sidebar and a little above center.
    static func dropTarget(in settings: NSRect) -> NSPoint {
        NSPoint(x: settings.minX + settings.width * 0.62, y: settings.minY + settings.height * 0.55)
    }
}

/// Reel's icon as a drag source for the app bundle, so it can be dropped
/// onto the screen recording list in System Settings.
struct DraggableAppIcon: NSViewRepresentable {
    func makeNSView(context: Context) -> AppIconDragSourceView {
        AppIconDragSourceView()
    }

    func updateNSView(_ nsView: AppIconDragSourceView, context: Context) {}
}

final class AppIconDragSourceView: NSView, NSDraggingSource {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        toolTip = "Drag Reel into System Settings"
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    override var mouseDownCanMoveWindow: Bool { false }

    /// The window sits beside System Settings while that app is active, so
    /// the first drag must not be spent activating Reel.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        NSApp.applicationIconImage.draw(in: bounds)
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .openHand)
    }

    override func mouseDown(with event: NSEvent) {}

    override func mouseDragged(with event: NSEvent) {
        let item = NSDraggingItem(pasteboardWriter: Bundle.main.bundleURL as NSURL)
        item.setDraggingFrame(bounds, contents: NSApp.applicationIconImage)
        beginDraggingSession(with: [item], event: event, source: self)
    }

    func draggingSession(
        _ session: NSDraggingSession,
        sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        // Copy only: a move would let Finder carry the running app away.
        context == .outsideApplication ? .copy : []
    }
}

extension NSView {
    fileprivate func firstSubview<View: NSView>(of type: View.Type) -> View? {
        for subview in subviews {
            if let match = subview as? View ?? subview.firstSubview(of: type) {
                return match
            }
        }
        return nil
    }
}
