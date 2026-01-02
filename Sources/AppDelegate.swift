import AppKit
import SwiftUI

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var screenRecorder: ScreenRecorder!
    private var settingsWindow: NSWindow?
    private var recordingDialogWindow: NSWindow?
    private var previewWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        screenRecorder = ScreenRecorder()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "record.circle", accessibilityDescription: "Reel")
        }

        AppSettings.shared.checkLaunchAtLoginStatus()
        setupHotkey()

        Task { @MainActor in
            await screenRecorder.requestPermission()
            rebuildMenu()
        }
    }

    private func setupHotkey() {
        HotkeyManager.shared.onToggleRecording = { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                if self.screenRecorder.isRecording {
                    await self.screenRecorder.stopRecording()
                    self.rebuildMenu()
                    if AppSettings.shared.showPreviewAfterRecording,
                       let url = self.screenRecorder.lastRecordedURL {
                        self.showPreview(for: url)
                    }
                } else {
                    await self.screenRecorder.startRecording()
                    self.rebuildMenu()
                }
            }
        }

        if HotkeyManager.shared.hasAccessibilityPermission() {
            HotkeyManager.shared.start()
        }
    }

    func rebuildMenu() {
        let menu = NSMenu()

        if !screenRecorder.hasPermission {
            let permItem = NSMenuItem(title: "Screen Recording Permission Required", action: nil, keyEquivalent: "")
            permItem.isEnabled = false
            menu.addItem(permItem)

            menu.addItem(NSMenuItem(title: "Open System Settings...", action: #selector(openSettings), keyEquivalent: ","))
            menu.addItem(NSMenuItem(title: "Check Permission", action: #selector(checkPermission), keyEquivalent: ""))
        } else {
            if screenRecorder.isRecording {
                let recordingItem = NSMenuItem(title: "● Recording...", action: nil, keyEquivalent: "")
                recordingItem.isEnabled = false
                menu.addItem(recordingItem)

                menu.addItem(NSMenuItem(title: "Stop Recording", action: #selector(stopRecording), keyEquivalent: "s"))
            } else {
                menu.addItem(NSMenuItem(title: "Start Recording...", action: #selector(showRecordingDialog), keyEquivalent: "r"))
            }
        }

        if !HotkeyManager.shared.hasAccessibilityPermission() {
            menu.addItem(NSMenuItem.separator())
            let accessItem = NSMenuItem(title: "Enable Keyboard Shortcuts...", action: #selector(requestAccessibility), keyEquivalent: "")
            menu.addItem(accessItem)
        }

        if let error = screenRecorder.errorMessage {
            menu.addItem(NSMenuItem.separator())
            let errorItem = NSMenuItem(title: error, action: nil, keyEquivalent: "")
            errorItem.isEnabled = false
            menu.addItem(errorItem)
        }

        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Settings...", action: #selector(openPreferences), keyEquivalent: ","))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit Reel", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        statusItem.menu = menu
    }

    @objc private func openSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
    }

    @objc private func checkPermission() {
        Task { @MainActor in
            await screenRecorder.requestPermission()
            rebuildMenu()
        }
    }

    @objc private func stopRecording() {
        Task { @MainActor in
            await screenRecorder.stopRecording()
            rebuildMenu()
            if AppSettings.shared.showPreviewAfterRecording,
               let url = screenRecorder.lastRecordedURL {
                showPreview(for: url)
            }
        }
    }

    private func showPreview(for url: URL) {
        let previewView = PostRecordingView(
            videoURL: url,
            onDismiss: { [weak self] in
                self?.previewWindow?.close()
                self?.previewWindow = nil
            },
            onRevealInFinder: {
                NSWorkspace.shared.selectFile(url.path(), inFileViewerRootedAtPath: "")
            },
            onDelete: { [weak self] in
                do {
                    try FileManager.default.removeItem(at: url)
                } catch {
                    let alert = NSAlert()
                    alert.messageText = "Could not delete recording"
                    alert.informativeText = error.localizedDescription
                    alert.alertStyle = .warning
                    alert.runModal()
                    return
                }
                self?.previewWindow?.close()
                self?.previewWindow = nil
            }
        )

        let hostingController = NSHostingController(rootView: previewView)
        let window = NSWindow(contentViewController: hostingController)
        window.title = "Recording Preview"
        window.styleMask = [.titled, .closable, .resizable]
        window.center()
        window.isReleasedWhenClosed = false

        previewWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func showRecordingDialog() {
        if recordingDialogWindow != nil {
            recordingDialogWindow?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        
        Task { @MainActor in
            await screenRecorder.refreshWindows()
            
            let dialogView = RecordingDialog(
                availableDisplays: screenRecorder.availableDisplays,
                availableWindows: screenRecorder.availableWindows,
                onStart: { [weak self] selection in
                    guard let self else { return }
                    self.recordingDialogWindow?.close()
                    self.recordingDialogWindow = nil
                    self.startRecording(selection: selection)
                },
                onCancel: { [weak self] in
                    self?.recordingDialogWindow?.close()
                    self?.recordingDialogWindow = nil
                }
            )
            
            let hostingController = NSHostingController(rootView: dialogView)
            let window = NSWindow(contentViewController: hostingController)
            window.title = "New Recording"
            window.styleMask = [.titled, .closable]
            window.center()
            window.isReleasedWhenClosed = false
            
            recordingDialogWindow = window
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }
    
    private func startRecording(selection: RecordingSelection) {
        Task { @MainActor in
            switch selection {
            case .display(let index):
                screenRecorder.selectedDisplayIndex = index
                screenRecorder.recordingMode = .display
            case .window(let window):
                screenRecorder.selectedWindow = window
                screenRecorder.recordingMode = .window
            }
            
            guard await CountdownOverlay().show() else { return }
            await screenRecorder.startRecording()
            rebuildMenu()
        }
    }

    @objc private func requestAccessibility() {
        HotkeyManager.shared.requestAccessibilityPermission()

        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            if HotkeyManager.shared.hasAccessibilityPermission() {
                HotkeyManager.shared.start()
            }
            self?.rebuildMenu()
        }
    }

    @objc private func openPreferences() {
        if settingsWindow == nil {
            let settingsView = SettingsView()
            let hostingController = NSHostingController(rootView: settingsView)

            let window = NSWindow(contentViewController: hostingController)
            window.title = "Reel Settings"
            window.styleMask = [.titled, .closable]
            window.center()
            window.isReleasedWhenClosed = false

            settingsWindow = window
        }

        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func updateIcon(isRecording: Bool) {
        if let button = statusItem.button {
            let symbolName = isRecording ? "record.circle.fill" : "record.circle"
            button.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: "Reel")
            button.contentTintColor = isRecording ? .red : nil
        }
        rebuildMenu()
    }
}
