import SwiftUI
import ScreenCaptureKit

enum RecordingSelection: Equatable {
    case display(Int)
    case window(SCWindow)
    
    static func == (lhs: RecordingSelection, rhs: RecordingSelection) -> Bool {
        switch (lhs, rhs) {
        case (.display(let l), .display(let r)): return l == r
        case (.window(let l), .window(let r)): return l.windowID == r.windowID
        default: return false
        }
    }
}

struct RecordingDialog: View {
    let availableDisplays: [SCDisplay]
    let availableWindows: [SCWindow]
    let onStart: (RecordingSelection) -> Void
    let onCancel: () -> Void
    
    @State private var selection: RecordingSelection?
    @State private var displayThumbnails: [Int: NSImage] = [:]
    @State private var windowThumbnails: [CGWindowID: NSImage] = [:]
    @State private var isLoading = true
    @State private var searchText = ""
    
    private var filteredWindows: [SCWindow] {
        guard !searchText.isEmpty else { return availableWindows }
        let query = searchText.lowercased()
        return availableWindows.filter { window in
            let appName = window.owningApplication?.applicationName ?? ""
            let title = window.title ?? ""
            return appName.lowercased().contains(query) || title.lowercased().contains(query)
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
            
            if !availableDisplays.isEmpty {
                Text("Displays")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(0..<availableDisplays.count, id: \.self) { index in
                            ThumbnailCard(
                                image: displayThumbnails[index],
                                title: availableDisplays.count == 1 ? "Display" : "Display \(index + 1)",
                                isSelected: selection == .display(index),
                                isLoading: isLoading
                            ) {
                                selection = .display(index)
                            }
                            .frame(width: 160)
                        }
                    }
                    .padding(.horizontal, 16)
                }
                .frame(height: 130)
            }
            
            if !availableWindows.isEmpty {
                HStack {
                    Text("Windows")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    Spacer()
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
                                isLoading: isLoading
                            ) {
                                selection = .window(window)
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 16)
                }
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
    
    private func loadThumbnails() async {
        for (index, display) in availableDisplays.enumerated() {
            if let image = await ThumbnailCapture.captureDisplay(display, maxSize: thumbnailSize) {
                displayThumbnails[index] = image
            }
        }
        
        for window in availableWindows {
            let windowID = window.windowID
            if let image = await ThumbnailCapture.captureWindow(window, maxSize: thumbnailSize) {
                windowThumbnails[windowID] = image
            }
        }
        isLoading = false
    }
    
    private func windowTitle(for window: SCWindow) -> String {
        let appName = window.owningApplication?.applicationName ?? "Unknown"
        if let title = window.title, !title.isEmpty, title != appName {
            return title
        }
        return appName
    }
    
    private func appIcon(for window: SCWindow) -> NSImage? {
        guard let bundleID = window.owningApplication?.bundleIdentifier,
              let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            return nil
        }
        return NSWorkspace.shared.icon(forFile: appURL.path)
    }
}

struct ThumbnailCard: View {
    let image: NSImage?
    let title: String
    var appIcon: NSImage? = nil
    let isSelected: Bool
    let isLoading: Bool
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
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
        }
        .buttonStyle(.plain)
    }
}
