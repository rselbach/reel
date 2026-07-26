import SwiftUI
import ScreenCaptureKit

enum RecordingSelection: Equatable {
    case display(CGDirectDisplayID)
    case window(SCWindow)
    /// Draw a new area.
    case region
    /// Record the area drawn last time, without drawing it again.
    case lastRegion

    static func == (lhs: RecordingSelection, rhs: RecordingSelection) -> Bool {
        switch (lhs, rhs) {
        case (.display(let l), .display(let r)): return l == r
        case (.window(let l), .window(let r)): return l.windowID == r.windowID
        case (.region, .region): return true
        case (.lastRegion, .lastRegion): return true
        default: return false
        }
    }
}

enum RecordingDialogText {
    static let windows = "Windows"
    static let search = "Search"
    static let refreshHelp = "Refresh displays and windows"
    static let refresh = "Refresh"
    static let noWindows = "No open windows found."
    static let noWindowsHint = "Open a window, then refresh."
    static let noSearchResults = "No windows match your search."
    static let nothingRecordable = "No recordable displays or windows found"
    static let nothingRecordableHint = "Check screen recording permission and try again."
    static let openSystemSettings = "Open System Settings..."
    static let openSystemSettingsFailed = "Could not open System Settings."
    static let selectArea = "Select Area to Record..."
    static let forThisRecording = "For this recording"
    static let recordCamera = "Camera"

    static func recordAudio(source: AppSettings.AudioSource) -> String {
        source.displayName
    }
}

enum RecordingDialogLogic {
    static func displayTitle(index: Int, displayCount: Int) -> String {
        displayCount == 1 ? "Display" : "Display \(index + 1)"
    }

    static func windowTitle(appName: String?, windowTitle: String?) -> String {
        let fallbackName = appName?.isEmpty == false ? appName! : "Unknown"
        guard let title = windowTitle, !title.isEmpty, title != fallbackName else {
            return fallbackName
        }
        return "\(title) — \(fallbackName)"
    }

    /// Names the remembered area by its size, so it is obvious which area is
    /// about to be reused.
    static func lastAreaLabel(size: CGSize) -> String {
        "Use Last Area (\(Int(size.width.rounded())) × \(Int(size.height.rounded())) px)"
    }

    /// Keeps a preselected target only when it is actually listed, so Start
    /// Recording is never enabled for a window or display that has gone away
    /// since it was remembered.
    static func validPreselection(
        _ selection: RecordingSelection?,
        displayIDs: [CGDirectDisplayID],
        windowIDs: [CGWindowID]
    ) -> RecordingSelection? {
        switch selection {
        case .display(let displayID):
            return displayIDs.contains(displayID) ? selection : nil
        case .window(let window):
            return windowIDs.contains(window.windowID) ? selection : nil
        case .region, .lastRegion, .none:
            return selection
        }
    }

    static func windowMatchesSearch(appName: String?, windowTitle: String?, query: String) -> Bool {
        guard !query.isEmpty else { return true }
        let normalizedQuery = query.lowercased()
        return (appName ?? "").lowercased().contains(normalizedQuery) ||
            (windowTitle ?? "").lowercased().contains(normalizedQuery)
    }
}

enum PickerNavigation {
    /// Columns the adaptive grid lays out at a given width. Mirrors the
    /// GridItem configuration, so arrow keys step by the row the user sees.
    static func columnCount(availableWidth: CGFloat, minimum: CGFloat, spacing: CGFloat) -> Int {
        guard availableWidth > 0, minimum > 0 else { return 1 }
        return max(1, Int((availableWidth + spacing) / (minimum + spacing)))
    }

    /// Next selected index for an arrow key. Movement is clamped rather than
    /// wrapped, so holding an arrow settles at an end instead of cycling.
    static func nextIndex(
        from index: Int?,
        direction: MoveCommandDirection,
        count: Int,
        columns: Int
    ) -> Int {
        guard count > 0 else { return 0 }
        guard let index else { return 0 }
        let step: Int
        switch direction {
        case .left: step = -1
        case .right: step = 1
        case .up: step = -max(1, columns)
        case .down: step = max(1, columns)
        @unknown default: step = 0
        }
        return min(max(0, index + step), count - 1)
    }
}

enum ThumbnailLoading {
    static let maxConcurrentCaptures = 6

    static func batches(
        count: Int,
        limit: Int = maxConcurrentCaptures
    ) -> [Range<Int>] {
        guard count > 0, limit > 0 else { return [] }
        return stride(from: 0, to: count, by: limit).map {
            $0..<min(count, $0 + limit)
        }
    }
}

/// Read-only snapshot wrapper for fanning ScreenCaptureKit objects (and the
/// NSImages made from them) out to concurrent thumbnail tasks. SCDisplay/
/// SCWindow/NSImage are not Sendable, but these are immutable snapshots that
/// are only read.
private struct UncheckedSendable<T>: @unchecked Sendable {
    let value: T
}

@MainActor
private enum AppIconCache {
    static let images = NSCache<NSString, NSImage>()

    static func icon(bundleID: String) -> NSImage? {
        if let image = images.object(forKey: bundleID as NSString) {
            return image
        }
        guard let appURL = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: bundleID
        ) else {
            return nil
        }
        let image = NSWorkspace.shared.icon(forFile: appURL.path())
        images.setObject(image, forKey: bundleID as NSString)
        return image
    }
}

struct RecordingDialog: View {
    let onStart: (RecordingSelection, RecordingOverrides) -> Void
    let onCancel: () -> Void
    let onRefresh: @MainActor () async -> (
        displays: [SCDisplay],
        windows: [SCWindow],
        excludedApplications: [SCRunningApplication]
    )
    /// Output pixel size of the remembered area, when there is one to reuse.
    let lastRegionOutputSize: CGSize?

    @State private var displays: [SCDisplay]
    @State private var windows: [SCWindow]
    @State private var excludedApplications: [SCRunningApplication]
    @State private var selection: RecordingSelection?
    @State private var displayThumbnails: [Int: NSImage] = [:]
    @State private var windowThumbnails: [CGWindowID: NSImage] = [:]
    @State private var isLoading = true
    @State private var searchText = ""
    @State private var settingsError: String?
    @State private var recordAudio: Bool
    @State private var recordCamera: Bool
    @StateObject private var levelMonitor = AudioLevelMonitor()

    init(
        availableDisplays: [SCDisplay],
        availableWindows: [SCWindow],
        excludedApplications: [SCRunningApplication],
        initialSelection: RecordingSelection?,
        lastRegionOutputSize: CGSize?,
        initialOverrides: RecordingOverrides,
        onStart: @escaping (RecordingSelection, RecordingOverrides) -> Void,
        onCancel: @escaping () -> Void,
        onRefresh: @escaping @MainActor () async -> (
            displays: [SCDisplay],
            windows: [SCWindow],
            excludedApplications: [SCRunningApplication]
        )
    ) {
        self.onStart = onStart
        self.onCancel = onCancel
        self.onRefresh = onRefresh
        self.lastRegionOutputSize = lastRegionOutputSize
        _recordAudio = State(initialValue: initialOverrides.recordAudio ?? false)
        _recordCamera = State(initialValue: initialOverrides.recordCamera ?? false)
        _displays = State(initialValue: availableDisplays)
        _windows = State(initialValue: availableWindows)
        _excludedApplications = State(initialValue: excludedApplications)
        _selection = State(initialValue: RecordingDialogLogic.validPreselection(
            initialSelection,
            displayIDs: availableDisplays.map(\.displayID),
            windowIDs: availableWindows.map(\.windowID)
        ))
    }

    private var filteredWindows: [SCWindow] {
        guard !searchText.isEmpty else { return windows }
        return windows.filter { window in
            RecordingDialogLogic.windowMatchesSearch(
                appName: window.owningApplication?.applicationName,
                windowTitle: window.title,
                query: searchText
            )
        }
    }
    
    private let thumbnailSize = CGSize(width: 160, height: 100)
    private static let gridMinimum: CGFloat = 160
    private static let gridSpacing: CGFloat = 12
    private static let gridWidth: CGFloat = 540 - 32
    private let columns = [
        GridItem(.adaptive(minimum: gridMinimum, maximum: 200), spacing: gridSpacing)
    ]

    /// Everything the arrow keys can move between, in the order shown.
    private var orderedSelections: [RecordingSelection] {
        displays.map { .display($0.displayID) } + filteredWindows.map { .window($0) }
    }

    private func moveSelection(_ direction: MoveCommandDirection) {
        let targets = orderedSelections
        guard !targets.isEmpty else { return }

        let current = selection.flatMap { targets.firstIndex(of: $0) }
        let columns = PickerNavigation.columnCount(
            availableWidth: Self.gridWidth,
            minimum: Self.gridMinimum,
            spacing: Self.gridSpacing
        )
        selection = targets[
            PickerNavigation.nextIndex(
                from: current,
                direction: direction,
                count: targets.count,
                columns: columns
            )
        ]
    }
    
    var body: some View {
        VStack(spacing: 0) {
            Text("Select what to record")
                .font(.headline)
                .padding(.top, 16)
                .padding(.bottom, 12)
            
            if !displays.isEmpty {
                Text("Displays")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(0..<displays.count, id: \.self) { index in
                            let displayID = displays[index].displayID
                            ThumbnailCard(
                                image: displayThumbnails[index],
                                title: RecordingDialogLogic.displayTitle(
                                    index: index,
                                    displayCount: displays.count
                                ),
                                isSelected: selection == .display(displayID),
                                isLoading: isLoading,
                                action: { selection = .display(displayID) },
                                onDoubleClick: { start(.display(displayID)) }
                            )
                            .frame(width: 160)
                        }
                    }
                    .padding(.horizontal, 16)
                }
                .frame(height: 130)
            }

            HStack {
                Button {
                    start(.region)
                } label: {
                    Label(RecordingDialogText.selectArea, systemImage: "rectangle.dashed")
                }

                if let lastRegionOutputSize {
                    Button {
                        start(.lastRegion)
                    } label: {
                        Label(
                            RecordingDialogLogic.lastAreaLabel(size: lastRegionOutputSize),
                            systemImage: "arrow.counterclockwise"
                        )
                    }
                }

                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)

            // The refresh control lives outside the windows list: when nothing
            // is listed yet is exactly when the user needs to retry.
            HStack {
                Text(RecordingDialogText.windows)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                Spacer()
                Button {
                    Task { await refresh() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .disabled(isLoading)
                .help(RecordingDialogText.refreshHelp)
                if !windows.isEmpty {
                    TextField(RecordingDialogText.search, text: $searchText)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 150)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)

            if windows.isEmpty {
                emptyState
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else if filteredWindows.isEmpty {
                Text(RecordingDialogText.noSearchResults)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(16)
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(filteredWindows, id: \.windowID) { window in
                            ThumbnailCard(
                                image: windowThumbnails[window.windowID],
                                title: windowTitle(for: window),
                                appIcon: appIcon(for: window),
                                isSelected: selection == .window(window),
                                isLoading: isLoading,
                                action: { selection = .window(window) },
                                onDoubleClick: { start(.window(window)) }
                            )
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 16)
                }
            }

            Divider()
            
            // Changing the microphone or camera for one take should not mean
            // opening Settings and coming back.
            HStack(spacing: 12) {
                Text(RecordingDialogText.forThisRecording)
                    .font(.caption)
                    .foregroundColor(.secondary)
                Toggle(
                    RecordingDialogText.recordAudio(source: AppSettings.shared.audioSource),
                    isOn: $recordAudio
                )
                Toggle(RecordingDialogText.recordCamera, isOn: $recordCamera)

                if recordAudio, AppSettings.shared.audioSource == .microphone {
                    AudioLevelMeter(level: levelMonitor.level)
                        .frame(width: 80)
                }

                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.top, 10)

            if recordAudio,
               AppSettings.shared.audioSource == .microphone,
               let error = levelMonitor.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundColor(.orange)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
            }

            HStack {
                Button("Cancel") {
                    onCancel()
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button("Start Recording") {
                    if let selection {
                        start(selection)
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selection == nil)
            }
            .padding(16)
        }
        .frame(width: 540, height: 540)
        .task {
            await loadThumbnails()
        }
        .onMoveCommand { moveSelection($0) }
        .onAppear { refreshMetering() }
        .onDisappear { levelMonitor.stop() }
        .onChange(of: recordAudio) {
            refreshMetering()
        }
    }
    
    /// Shown in place of the window grid. Missing displays *and* windows
    /// almost always means the screen recording permission is not in effect,
    /// so that case offers a way straight to System Settings.
    @ViewBuilder
    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 6) {
            if displays.isEmpty {
                Text(RecordingDialogText.nothingRecordable)
                    .font(.subheadline)
                Text(RecordingDialogText.nothingRecordableHint)
                    .font(.caption)
                    .foregroundColor(.secondary)
                Button(RecordingDialogText.openSystemSettings) {
                    openScreenCaptureSettings()
                }
                .padding(.top, 4)
            } else {
                Text(RecordingDialogText.noWindows)
                    .font(.subheadline)
                Text(RecordingDialogText.noWindowsHint)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            if let settingsError {
                Text(settingsError)
                    .font(.caption)
                    .foregroundColor(.red)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 16)
    }

    private func start(_ selection: RecordingSelection) {
        onStart(
            selection,
            RecordingOverrides(recordAudio: recordAudio, recordCamera: recordCamera)
        )
    }

    private func refreshMetering() {
        guard recordAudio, AppSettings.shared.audioSource == .microphone else {
            levelMonitor.stop()
            return
        }
        levelMonitor.start(device: AppSettings.shared.selectedAudioDevice)
    }

    private func openScreenCaptureSettings() {
        guard let url = SystemSettingsLink.screenCapturePrivacy,
              NSWorkspace.shared.open(url) else {
            settingsError = RecordingDialogText.openSystemSettingsFailed
            return
        }
        settingsError = nil
    }

    private func refresh() async {
        isLoading = true
        let content = await onRefresh()
        displays = content.displays
        windows = content.windows
        excludedApplications = content.excludedApplications
        displayThumbnails = [:]
        windowThumbnails = [:]
        // Replace a selected window with the refreshed ScreenCaptureKit
        // snapshot so resizing and other metadata changes reach the recorder.
        if case .window(let selected) = selection {
            selection = windows
                .first(where: { $0.windowID == selected.windowID })
                .map { .window($0) }
        }
        if case .display(let displayID) = selection,
           !displays.contains(where: { $0.displayID == displayID }) {
            selection = nil
        }
        await loadThumbnails()
    }

    /// Captures all thumbnails concurrently. Each child task runs on the
    /// main actor, but the SCScreenshotManager calls suspend, so the actual
    /// captures overlap instead of loading one by one.
    private func loadThumbnails() async {
        let size = thumbnailSize
        let boxedExcludedApplications = UncheckedSendable(value: excludedApplications)

        await withTaskGroup(of: UncheckedSendable<(Int, NSImage)>?.self) { group in
            for (index, display) in displays.enumerated() {
                let boxed = UncheckedSendable(value: display)
                group.addTask {
                    guard let image = await ThumbnailCapture.captureDisplay(
                        boxed.value,
                        excludingApplications: boxedExcludedApplications.value,
                        maxSize: size
                    ) else {
                        return nil
                    }
                    return UncheckedSendable(value: (index, image))
                }
            }
            for await result in group {
                guard !Task.isCancelled else { return }
                if let result {
                    displayThumbnails[result.value.0] = result.value.1
                }
            }
        }

        for batch in ThumbnailLoading.batches(count: windows.count) {
            await withTaskGroup(of: UncheckedSendable<(CGWindowID, NSImage)>?.self) { group in
                for index in batch {
                    let boxed = UncheckedSendable(value: windows[index])
                    group.addTask {
                        guard let image = await ThumbnailCapture.captureWindow(
                            boxed.value,
                            maxSize: size
                        ) else {
                            return nil
                        }
                        return UncheckedSendable(value: (boxed.value.windowID, image))
                    }
                }
                for await result in group {
                    guard !Task.isCancelled else { return }
                    if let result {
                        windowThumbnails[result.value.0] = result.value.1
                    }
                }
            }
        }

        guard !Task.isCancelled else { return }
        isLoading = false
    }
    
    private func windowTitle(for window: SCWindow) -> String {
        RecordingDialogLogic.windowTitle(
            appName: window.owningApplication?.applicationName,
            windowTitle: window.title
        )
    }
    
    private func appIcon(for window: SCWindow) -> NSImage? {
        guard let bundleID = window.owningApplication?.bundleIdentifier else {
            return nil
        }
        return AppIconCache.icon(bundleID: bundleID)
    }
}

struct ThumbnailCard: View {
    let image: NSImage?
    let title: String
    var appIcon: NSImage? = nil
    let isSelected: Bool
    let isLoading: Bool
    let action: () -> Void
    var onDoubleClick: (() -> Void)? = nil

    /// A real button rather than stacked tap gestures: those made every
    /// single click wait to see whether a second one followed, and left the
    /// card unreachable from the keyboard.
    var body: some View {
        Button(action: action) {
            card
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
        .simultaneousGesture(
            TapGesture(count: 2).onEnded { onDoubleClick?() }
        )
    }

    private var card: some View {
        VStack(spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color(nsColor: .controlBackgroundColor))
                    .frame(height: 100)
                
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxHeight: 96)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                } else if isLoading {
                    ProgressView()
                        .scaleEffect(0.6)
                } else {
                    Image(systemName: "rectangle.dashed")
                        .font(.largeTitle)
                        .foregroundColor(.secondary)
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 3)
            )
            
            HStack(spacing: 4) {
                if let appIcon {
                    Image(nsImage: appIcon)
                        .resizable()
                        .frame(width: 14, height: 14)
                }
                Text(title)
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .foregroundColor(isSelected ? .accentColor : .primary)
        }
        .contentShape(Rectangle())
    }
}
