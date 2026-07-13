import SwiftUI
import ScreenCaptureKit

enum RecordingSelection: Equatable {
    case display(Int)
    case window(SCWindow)
    case region

    static func == (lhs: RecordingSelection, rhs: RecordingSelection) -> Bool {
        switch (lhs, rhs) {
        case (.display(let l), .display(let r)): return l == r
        case (.window(let l), .window(let r)): return l.windowID == r.windowID
        case (.region, .region): return true
        default: return false
        }
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
        return title
    }

    static func windowMatchesSearch(appName: String?, windowTitle: String?, query: String) -> Bool {
        guard !query.isEmpty else { return true }
        let normalizedQuery = query.lowercased()
        return (appName ?? "").lowercased().contains(normalizedQuery) ||
            (windowTitle ?? "").lowercased().contains(normalizedQuery)
    }
}

/// Read-only snapshot wrapper for fanning ScreenCaptureKit objects (and the
/// NSImages made from them) out to concurrent thumbnail tasks. SCDisplay/
/// SCWindow/NSImage are not Sendable, but these are immutable snapshots that
/// are only read.
private struct UncheckedSendable<T>: @unchecked Sendable {
    let value: T
}

struct RecordingDialog: View {
    let onStart: (RecordingSelection) -> Void
    let onCancel: () -> Void
    let onRefresh: @MainActor () async -> (displays: [SCDisplay], windows: [SCWindow])

    @State private var displays: [SCDisplay]
    @State private var windows: [SCWindow]
    @State private var selection: RecordingSelection?
    @State private var displayThumbnails: [Int: NSImage] = [:]
    @State private var windowThumbnails: [CGWindowID: NSImage] = [:]
    @State private var isLoading = true
    @State private var searchText = ""

    init(
        availableDisplays: [SCDisplay],
        availableWindows: [SCWindow],
        onStart: @escaping (RecordingSelection) -> Void,
        onCancel: @escaping () -> Void,
        onRefresh: @escaping @MainActor () async -> (displays: [SCDisplay], windows: [SCWindow])
    ) {
        self.onStart = onStart
        self.onCancel = onCancel
        self.onRefresh = onRefresh
        _displays = State(initialValue: availableDisplays)
        _windows = State(initialValue: availableWindows)
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
    private let columns = [GridItem(.adaptive(minimum: 160, maximum: 200), spacing: 12)]
    
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
                            ThumbnailCard(
                                image: displayThumbnails[index],
                                title: RecordingDialogLogic.displayTitle(
                                    index: index,
                                    displayCount: displays.count
                                ),
                                isSelected: selection == .display(index),
                                isLoading: isLoading,
                                action: { selection = .display(index) },
                                onDoubleClick: { onStart(.display(index)) }
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
                    onStart(.region)
                } label: {
                    Label("Select Area to Record...", systemImage: "rectangle.dashed")
                }
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)

            if !windows.isEmpty {
                HStack {
                    Text("Windows")
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
                    .help("Refresh displays and windows")
                    TextField("Search", text: $searchText)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 150)
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                
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
                                onDoubleClick: { onStart(.window(window)) }
                            )
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 16)
                }
            }

            if displays.isEmpty && windows.isEmpty {
                VStack(spacing: 6) {
                    Text("No recordable displays or windows found")
                        .font(.subheadline)
                    Text("Check screen recording permission and try again.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.vertical, 16)
            }
            
            Divider()
            
            HStack {
                Button("Cancel") {
                    onCancel()
                }
                .keyboardShortcut(.cancelAction)
                
                Spacer()
                
                Button("Start Recording") {
                    if let selection {
                        onStart(selection)
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selection == nil)
            }
            .padding(16)
        }
        .frame(width: 540, height: 480)
        .task {
            await loadThumbnails()
        }
    }
    
    private func refresh() async {
        isLoading = true
        let content = await onRefresh()
        displays = content.displays
        windows = content.windows
        displayThumbnails = [:]
        windowThumbnails = [:]
        // Drop a selection that no longer exists after the refresh.
        if case .window(let selected) = selection,
           !windows.contains(where: { $0.windowID == selected.windowID }) {
            selection = nil
        }
        if case .display(let index) = selection, index >= displays.count {
            selection = nil
        }
        await loadThumbnails()
    }

    /// Captures all thumbnails concurrently. Each child task runs on the
    /// main actor, but the SCScreenshotManager calls suspend, so the actual
    /// captures overlap instead of loading one by one.
    private func loadThumbnails() async {
        let size = thumbnailSize

        await withTaskGroup(of: UncheckedSendable<(Int, NSImage)>?.self) { group in
            for (index, display) in displays.enumerated() {
                let boxed = UncheckedSendable(value: display)
                group.addTask {
                    guard let image = await ThumbnailCapture.captureDisplay(boxed.value, maxSize: size) else {
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

        await withTaskGroup(of: UncheckedSendable<(CGWindowID, NSImage)>?.self) { group in
            for window in windows {
                let boxed = UncheckedSendable(value: window)
                group.addTask {
                    guard let image = await ThumbnailCapture.captureWindow(boxed.value, maxSize: size) else {
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
        guard let bundleID = window.owningApplication?.bundleIdentifier,
              let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            return nil
        }
        return NSWorkspace.shared.icon(forFile: appURL.path())
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
    
    var body: some View {
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
        .onTapGesture(count: 2) {
            onDoubleClick?()
        }
        .onTapGesture(count: 1) {
            action()
        }
    }
}
