import SwiftUI

struct AboutView: View {
    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Unknown"
    }

    private var buildNumber: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "Unknown"
    }

    private var gitCommit: String {
        Bundle.main.object(forInfoDictionaryKey: "GitCommit") as? String ?? "dev"
    }

    private var commitURL: URL? {
        let commit = gitCommit
        guard commit != "dev" else { return nil }
        return URL(string: "https://github.com/rselbach/reel/commit/\(commit)")
    }

    var body: some View {
        VStack(spacing: 16) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 128, height: 128)

            Text("Reel")
                .font(.title)
                .fontWeight(.bold)

            Text("A simple screen recorder for macOS")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                GridRow {
                    Text("Version")
                        .foregroundStyle(.secondary)
                        .gridColumnAlignment(.trailing)
                    Text(appVersion)
                }
                GridRow {
                    Text("Build")
                        .foregroundStyle(.secondary)
                    Text(buildNumber)
                }
                GridRow {
                    Text("Commit")
                        .foregroundStyle(.secondary)
                    if let url = commitURL {
                        Link(gitCommit, destination: url)
                    } else {
                        Text(gitCommit)
                    }
                }
            }
            .padding(.top, 8)

            HStack(spacing: 12) {
                Button("GitHub") {
                    if let url = URL(string: "https://github.com/rselbach/reel") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
            .padding(.top, 8)
        }
        .padding(32)
        .frame(width: 320)
    }
}

#Preview {
    AboutView()
}
