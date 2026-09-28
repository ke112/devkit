import AppKit
import Foundation

enum AppBuildInfo {
    static let commitHashResourceName = "GitCommitHash"

    static func commitShortHash(from bundle: Bundle = .main) -> String? {
        guard let resourceURL = bundle.url(
            forResource: commitHashResourceName,
            withExtension: "txt"
        ), let rawHash = try? String(contentsOf: resourceURL, encoding: .utf8) else {
            return nil
        }
        return normalizedCommitHash(rawHash)
    }

    static func normalizedCommitHash(_ rawHash: String) -> String? {
        let trimmedHash = rawHash.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedHash.isEmpty ? nil : trimmedHash
    }

    static func copyCommitShortHashToPasteboard(from bundle: Bundle = .main) -> Bool {
        guard let commitHash = commitShortHash(from: bundle) else {
            return false
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(commitHash, forType: .string)
        return true
    }
}
