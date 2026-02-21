import Foundation
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
        let commit = gitCommit.trimmingCharacters(in: .whitespacesAndNewlines)
        guard commit != "dev", isValidCommitSHA(commit) else { return nil }
        
        var components = URLComponents()
        components.scheme = "https"
        components.host = "github.com"
        components.path = "/rselbach/reel/commit/\(commit)"
        return components.url
    }

    private func isValidCommitSHA(_ commit: String) -> Bool {
        guard (7...40).contains(commit.count) else { return false }
        return commit.unicodeScalars.allSatisfy { CharacterSet.hexadecimalDigits.contains($0) }
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
