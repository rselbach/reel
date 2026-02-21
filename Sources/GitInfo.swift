import Foundation

struct GitInfo {
    static func commitURL(for commit: String) -> URL? {
        guard let normalized = normalizedCommit(commit) else {
            return nil
        }

        var components = URLComponents()
        components.scheme = "https"
        components.host = "github.com"
        components.path = "/rselbach/reel/commit/\(normalized)"
        return components.url
    }

    static func normalizedCommit(_ commit: String) -> String? {
        let trimmed = commit.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.lowercased() != "dev" else { return nil }
        guard isValidCommitSHA(trimmed) else { return nil }
        return trimmed
    }

    static func isValidCommitSHA(_ commit: String) -> Bool {
        guard (7...40).contains(commit.count) else { return false }
        return commit.unicodeScalars.allSatisfy { CharacterSet.hexadecimalDigits.contains($0) }
    }
}
