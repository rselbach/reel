import ScreenCaptureKit
import SwiftUI

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

/// The three kinds of thing the picker records, one tab each.
enum RecordingPickerMode: CaseIterable, Identifiable {
    case display
    case window
    case area

    var id: Self { self }

    var title: String {
        switch self {
        case .display: return "Display"
        case .window: return "Window"
        case .area: return "Area"
        }
    }

    /// The tab that shows a selection.
    init(selection: RecordingSelection?) {
        switch selection {
        case .window:
            self = .window
        case .region, .lastRegion:
            self = .area
        case .display, .none:
            self = .display
        }
    }
}

enum RecordingDialogText {
    static let search = "Search"
    static let refreshHelp = "Refresh displays and windows"
    static let refresh = "Refresh"
    static let noWindows = "No open windows found."
    static let noWindowsHint = "Open a window, then refresh."
    static let noSearchResults = "No windows match your search."
    static let selectArea = "Select Area..."
    static let startRecording = "Start Recording"
    static let newArea = "New Area"
    static let newAreaHint = "Drag across the screen to choose an area, then press Return to start recording."
    static let lastAreaHint = "Records the same part of the screen as last time."
    static let modeLabel = "Record"
    static let forThisRecording = "For this recording"
    static let recordCamera = "Camera"

    static func recordAudio(source: AppSettings.AudioSource) -> String {
        source.displayName
    }
}

enum RecordingDialogLogic {
    /// Each display's own name, as System Settings shows it, numbered only
    /// when two displays share one. A display macOS does not name falls
    /// back to "Display" and its position.
    static func displayTitles(names: [String?]) -> [String] {
        let titles = names.enumerated().map { index, name in
            guard let name, !name.isEmpty else {
                return names.count == 1 ? "Display" : "Display \(index + 1)"
            }
            return name
        }
        return titles.enumerated().map { index, title in
            guard titles.filter({ $0 == title }).count > 1 else { return title }
            let ordinal = titles[..<index].filter { $0 == title }.count + 1
            return "\(title) \(ordinal)"
        }
    }

    /// The names macOS gives the displays, in the order listed.
    @MainActor
    static func screenNames(for displayIDs: [CGDirectDisplayID]) -> [String?] {
        displayIDs.map { displayID in
            NSScreen.screens.first { $0.displayID == displayID }?.localizedName
        }
    }

    /// What the menu's quick-record item calls a display. With only one,
    /// "Record Entire Screen" says more than its model name.
    static func quickRecordDisplayLabel(titles: [String], index: Int) -> String? {
        guard titles.indices.contains(index) else { return nil }
        return titles.count == 1 ? "Entire Screen" : titles[index]
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
        "Last Area (\(Int(size.width.rounded())) × \(Int(size.height.rounded())) px)"
    }

    /// A new area is drawn before anything records, so the button says so.
    static func startTitle(for selection: RecordingSelection?) -> String {
        selection == .region ? RecordingDialogText.selectArea : RecordingDialogText.startRecording
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
        return (appName ?? "").lowercased().contains(normalizedQuery)
            || (windowTitle ?? "").lowercased().contains(normalizedQuery)
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
        guard
            let appURL = NSWorkspace.shared.urlForApplication(
                withBundleIdentifier: bundleID
            )
        else {
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
    let onGrantAccess: () -> Void
    let onRefresh:
        @MainActor () async -> (
            displays: [SCDisplay],
            windows: [SCWindow],
            excludedApplications: [SCRunningApplication]
        )
    /// Output pixel size of the remembered area, when there is one to reuse.
    let lastRegionOutputSize: CGSize?

    @State private var displays: [SCDisplay]
    @State private var windows: [SCWindow]
    @State private var excludedApplications: [SCRunningApplication]
    @State private var mode: RecordingPickerMode
    // Each tab keeps its own pick, so switching tabs never loses one.
    @State private var selectedDisplayID: CGDirectDisplayID?
    @State private var selectedWindow: SCWindow?
    @State private var reusesLastArea: Bool
    @State private var displayThumbnails: [Int: NSImage] = [:]
    @State private var windowThumbnails: [CGWindowID: NSImage] = [:]
    @State private var isLoading = true
    @State private var searchText = ""
    @State private var recordAudio: Bool
    @State private var recordCamera: Bool
    @StateObject private var levelMonitor = AudioLevelMonitor()
    /// Arrow keys reach onMoveCommand only through a focused view.
    @FocusState private var isPickerFocused: Bool
    @Environment(\.displayScale) private var displayScale

    init(
        availableDisplays: [SCDisplay],
        availableWindows: [SCWindow],
        excludedApplications: [SCRunningApplication],
        initialSelection: RecordingSelection?,
        lastRegionOutputSize: CGSize?,
        initialOverrides: RecordingOverrides,
        onStart: @escaping (RecordingSelection, RecordingOverrides) -> Void,
        onCancel: @escaping () -> Void,
        onGrantAccess: @escaping () -> Void,
        onRefresh:
            @escaping @MainActor () async -> (
                displays: [SCDisplay],
                windows: [SCWindow],
                excludedApplications: [SCRunningApplication]
            )
    ) {
        self.onStart = onStart
        self.onCancel = onCancel
        self.onGrantAccess = onGrantAccess
        self.onRefresh = onRefresh
        self.lastRegionOutputSize = lastRegionOutputSize
        _recordAudio = State(initialValue: initialOverrides.recordAudio ?? false)
        _recordCamera = State(initialValue: initialOverrides.recordCamera ?? false)
        _displays = State(initialValue: availableDisplays)
        _windows = State(initialValue: availableWindows)
        _excludedApplications = State(initialValue: excludedApplications)
        let preselection = RecordingDialogLogic.validPreselection(
            initialSelection,
            displayIDs: availableDisplays.map(\.displayID),
            windowIDs: availableWindows.map(\.windowID)
        )
        _mode = State(initialValue: RecordingPickerMode(selection: preselection))
        var displayID = availableDisplays.first?.displayID
        var window: SCWindow?
        switch preselection {
        case .display(let id):
            displayID = id
        case .window(let preselectedWindow):
            window = preselectedWindow
        case .region, .lastRegion, .none:
            break
        }
        _selectedDisplayID = State(initialValue: displayID)
        _selectedWindow = State(initialValue: window)
        _reusesLastArea = State(initialValue: preselection == .lastRegion && lastRegionOutputSize != nil)
    }

    private var selection: RecordingSelection? {
        switch mode {
        case .display:
            return selectedDisplayID.map { .display($0) }
        case .window:
            return selectedWindow.map { .window($0) }
        case .area:
            return reusesLastArea && lastRegionOutputSize != nil ? .lastRegion : .region
        }
    }

    private var displayTitles: [String] {
        RecordingDialogLogic.displayTitles(names: RecordingDialogLogic.screenNames(for: displays.map(\.displayID)))
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
    private let displayThumbnailSize = CGSize(width: 240, height: 150)
    private static let gridMinimum: CGFloat = 160
    private static let gridSpacing: CGFloat = 12
    private static let gridWidth: CGFloat = 540 - 32
    private let columns = [
        GridItem(.adaptive(minimum: gridMinimum, maximum: 200), spacing: gridSpacing)
    ]

    /// Moves the arrow keys through the cards on the current tab.
    private func moveSelection(_ direction: MoveCommandDirection) {
        switch mode {
        case .display:
            let ids = displays.map(\.displayID)
            guard !ids.isEmpty else { return }
            let current = selectedDisplayID.flatMap { ids.firstIndex(of: $0) }
            let next = PickerNavigation.nextIndex(from: current, direction: direction, count: ids.count, columns: 2)
            selectedDisplayID = ids[next]
        case .window:
            let candidates = filteredWindows
            guard !candidates.isEmpty else { return }
            let current = selectedWindow.flatMap { selected in
                candidates.firstIndex { $0.windowID == selected.windowID }
            }
            let columns = PickerNavigation.columnCount(
                availableWidth: Self.gridWidth,
                minimum: Self.gridMinimum,
                spacing: Self.gridSpacing
            )
            let next = PickerNavigation.nextIndex(
                from: current,
                direction: direction,
                count: candidates.count,
                columns: columns
            )
            selectedWindow = candidates[next]
        case .area:
            guard lastRegionOutputSize != nil else { return }
            switch direction {
            case .left: reusesLastArea = false
            case .right: reusesLastArea = true
            default: return
            }
        }
    }

    var body: some View {
        Group {
            // ScreenCaptureKit lists no displays only when Reel cannot capture
            // at all, which in practice means the permission is not in effect.
            if displays.isEmpty {
                permissionNeeded
            } else {
                picker
            }
        }
        .frame(width: 540, height: 540)
        .task {
            await loadThumbnails()
        }
    }

    private var permissionNeeded: some View {
        VStack(spacing: 0) {
            Spacer()
            VStack(spacing: 16) {
                Image(systemName: "rectangle.dashed.badge.record")
                    .font(.system(size: 48))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text(PermissionText.required)
                    .font(.title3)
                    .fontWeight(.semibold)
                Text(PermissionText.pickerExplainer)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button(PermissionText.grantAccess, action: onGrantAccess)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 48)
            Spacer()
            Divider()
            HStack {
                Spacer()
                Button("Cancel") {
                    onCancel()
                }
                .keyboardShortcut(.cancelAction)
            }
            .padding(16)
        }
    }

    private var picker: some View {
        VStack(spacing: 0) {
            Picker(RecordingDialogText.modeLabel, selection: $mode) {
                ForEach(RecordingPickerMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .frame(maxWidth: .infinity)
            .overlay(alignment: .trailing) {
                if mode != .area {
                    refreshButton
                }
            }
            .padding(16)

            Group {
                switch mode {
                case .display:
                    displayGrid
                case .window:
                    windowList
                case .area:
                    areaOptions
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

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

                if recordAudio, AppSettings.shared.audioSource.capturesMicrophone {
                    AudioLevelMeter(level: levelMonitor.level)
                        .frame(width: 80)
                }

                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.top, 10)

            if recordAudio,
                AppSettings.shared.audioSource.capturesMicrophone,
                let error = levelMonitor.errorMessage
            {
                Text(error)
                    .font(.caption)
                    .foregroundColor(.orange)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
            }

            HStack {
                Spacer()

                Button("Cancel") {
                    onCancel()
                }
                .keyboardShortcut(.cancelAction)

                Button(RecordingDialogLogic.startTitle(for: selection)) {
                    if let selection {
                        start(selection)
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selection == nil)
            }
            .padding(16)
        }
        .focusable()
        .focusEffectDisabled()
        .focused($isPickerFocused)
        .onMoveCommand { moveSelection($0) }
        .onAppear {
            isPickerFocused = true
            refreshMetering()
        }
        .onDisappear { levelMonitor.stop() }
        .onChange(of: recordAudio) {
            refreshMetering()
        }
    }

    private var refreshButton: some View {
        Button {
            Task { await refresh() }
        } label: {
            Image(systemName: "arrow.clockwise")
        }
        .buttonStyle(.borderless)
        .disabled(isLoading)
        .help(RecordingDialogText.refreshHelp)
        .accessibilityLabel(RecordingDialogText.refresh)
    }

    private var displayGrid: some View {
        ScrollView {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 220, maximum: 250), spacing: Self.gridSpacing)],
                spacing: Self.gridSpacing
            ) {
                ForEach(0..<displays.count, id: \.self) { index in
                    let displayID = displays[index].displayID
                    ThumbnailCard(
                        image: displayThumbnails[index],
                        title: displayTitles[index],
                        isSelected: selectedDisplayID == displayID,
                        isLoading: isLoading,
                        thumbnailHeight: 150,
                        action: { selectedDisplayID = displayID },
                        onDoubleClick: { start(.display(displayID)) }
                    )
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
        }
    }

    @ViewBuilder
    private var windowList: some View {
        if windows.isEmpty {
            emptyState
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            VStack(spacing: 12) {
                TextField(RecordingDialogText.search, text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .padding(.horizontal, 16)

                if filteredWindows.isEmpty {
                    Text(RecordingDialogText.noSearchResults)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .padding(.horizontal, 16)
                } else {
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 12) {
                            ForEach(filteredWindows, id: \.windowID) { window in
                                ThumbnailCard(
                                    image: windowThumbnails[window.windowID],
                                    title: windowTitle(for: window),
                                    appIcon: appIcon(for: window),
                                    isSelected: selectedWindow?.windowID == window.windowID,
                                    isLoading: isLoading,
                                    action: { selectedWindow = window },
                                    onDoubleClick: { start(.window(window)) }
                                )
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.bottom, 16)
                    }
                }
            }
        }
    }

    private var areaOptions: some View {
        VStack(alignment: .leading, spacing: 16) {
            LazyVGrid(
                columns: [
                    GridItem(.flexible(), spacing: Self.gridSpacing),
                    GridItem(.flexible(), spacing: Self.gridSpacing),
                ],
                spacing: Self.gridSpacing
            ) {
                ThumbnailCard(
                    image: nil,
                    title: RecordingDialogText.newArea,
                    isSelected: !reusesLastArea || lastRegionOutputSize == nil,
                    isLoading: false,
                    placeholderSymbol: "rectangle.dashed",
                    thumbnailHeight: 150,
                    action: { reusesLastArea = false },
                    onDoubleClick: { start(.region) }
                )
                if let lastRegionOutputSize {
                    ThumbnailCard(
                        image: nil,
                        title: RecordingDialogLogic.lastAreaLabel(size: lastRegionOutputSize),
                        isSelected: reusesLastArea,
                        isLoading: false,
                        placeholderSymbol: "arrow.counterclockwise",
                        thumbnailHeight: 150,
                        action: { reusesLastArea = true },
                        onDoubleClick: { start(.lastRegion) }
                    )
                }
            }

            Text(selection == .lastRegion ? RecordingDialogText.lastAreaHint : RecordingDialogText.newAreaHint)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
    }

    /// Shown in place of the window grid when no windows are open.
    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(RecordingDialogText.noWindows)
                .font(.subheadline)
            Text(RecordingDialogText.noWindowsHint)
                .font(.caption)
                .foregroundColor(.secondary)
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
        guard recordAudio, AppSettings.shared.audioSource.capturesMicrophone else {
            levelMonitor.stop()
            return
        }
        levelMonitor.start(device: AppSettings.shared.selectedAudioDevice)
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
        if let selected = selectedWindow {
            selectedWindow = windows.first { $0.windowID == selected.windowID }
        }
        if let displayID = selectedDisplayID, !displays.contains(where: { $0.displayID == displayID }) {
            selectedDisplayID = displays.first?.displayID
        }
        await loadThumbnails()
    }

    /// Captures all thumbnails concurrently. Each child task runs on the
    /// main actor, but the SCScreenshotManager calls suspend, so the actual
    /// captures overlap instead of loading one by one.
    private func loadThumbnails() async {
        let size = thumbnailSize
        let displaySize = displayThumbnailSize
        let scale = displayScale
        let boxedExcludedApplications = UncheckedSendable(value: excludedApplications)

        await withTaskGroup(of: UncheckedSendable<(Int, NSImage)>?.self) { group in
            for (index, display) in displays.enumerated() {
                let boxed = UncheckedSendable(value: display)
                group.addTask {
                    guard
                        let image = await ThumbnailCapture.captureDisplay(
                            boxed.value,
                            excludingApplications: boxedExcludedApplications.value,
                            maxSize: displaySize,
                            scale: scale
                        )
                    else {
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
                        guard
                            let image = await ThumbnailCapture.captureWindow(
                                boxed.value,
                                maxSize: size,
                                scale: scale
                            )
                        else {
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
    var placeholderSymbol = "rectangle.dashed"
    var thumbnailHeight: CGFloat = 100
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
                // A faint fill rather than the control background, which
                // matches the window and left icon-only cards without a box.
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.primary.opacity(0.06))
                    .frame(height: thumbnailHeight)

                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxHeight: thumbnailHeight - 4)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                } else if isLoading {
                    ProgressView()
                        .scaleEffect(0.6)
                } else {
                    Image(systemName: placeholderSymbol)
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
