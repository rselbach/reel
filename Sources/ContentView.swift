import SwiftUI

struct ContentView: View {
    @EnvironmentObject var screenRecorder: ScreenRecorder

    var body: some View {
        VStack(spacing: 20) {
            Text("Mili Screen Recorder")
                .font(.largeTitle)
                .fontWeight(.bold)

            if !screenRecorder.hasPermission {
                VStack(spacing: 12) {
                    Text("Screen recording permission required")
                        .foregroundColor(.secondary)
                    Text("Add Mili in System Settings → Privacy & Security → Screen Recording")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                    HStack {
                        Button("Open System Settings") {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
                        }
                        Button("Check Again") {
                            Task {
                                await screenRecorder.requestPermission()
                            }
                        }
                    }
                }
            } else {
                recordingControls
            }

            if let error = screenRecorder.errorMessage {
                Text(error)
                    .foregroundColor(.red)
                    .font(.caption)
            }
        }
        .padding(40)
        .frame(minWidth: 400, minHeight: 300)
        .task {
            await screenRecorder.requestPermission()
        }
    }

    @ViewBuilder
    private var recordingControls: some View {
        if screenRecorder.isRecording {
            VStack(spacing: 12) {
                HStack {
                    Circle()
                        .fill(.red)
                        .frame(width: 12, height: 12)
                    Text("Recording...")
                        .foregroundColor(.secondary)
                }

                Button("Stop Recording") {
                    Task {
                        await screenRecorder.stopRecording()
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
            }
        } else {
            VStack(spacing: 12) {
                Picker("Display", selection: $screenRecorder.selectedDisplayIndex) {
                    ForEach(0..<screenRecorder.availableDisplays.count, id: \.self) { index in
                        Text("Display \(index + 1)").tag(index)
                    }
                }
                .frame(width: 200)

                Button("Start Recording") {
                    Task {
                        await screenRecorder.startRecording()
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(screenRecorder.availableDisplays.isEmpty)
            }
        }
    }
}
