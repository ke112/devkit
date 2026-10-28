import Foundation

/// Shared exclusions apply to directories, recursive scans and directly selected images.
enum ImageCompressionInputRules {
    nonisolated private static let excludedDirectoryNames: Set<String> = ["build", "tmp", "deriveddata", "packages"]

    nonisolated static func excludesDirectory(named name: String) -> Bool {
        excludedDirectoryNames.contains(name.lowercased())
    }

    nonisolated static func excludes(_ url: URL) -> Bool {
        excludesAncestors(of: url.standardizedFileURL)
            || excludesAncestors(of: url.resolvingSymlinksInPath().standardizedFileURL)
    }

    nonisolated private static func excludesAncestors(of source: URL) -> Bool {
        var directory = ImageTaskScanner.isDirectory(source)
            ? source : source.deletingLastPathComponent().standardizedFileURL
        let temporaryRoots = Set([
            FileManager.default.temporaryDirectory.standardizedFileURL.path,
            FileManager.default.temporaryDirectory.resolvingSymlinksInPath().standardizedFileURL.path,
            URL(fileURLWithPath: "/tmp", isDirectory: true).standardizedFileURL.path,
            URL(fileURLWithPath: "/tmp", isDirectory: true).resolvingSymlinksInPath().standardizedFileURL.path
        ])
        while true {
            // System temporary roots may contain an entire chosen project; only its own tmp folders are excluded.
            if temporaryRoots.contains(directory.path) { return false }
            if excludedDirectoryNames.contains(directory.lastPathComponent.lowercased()) { return true }
            if directory.path == "/" { return false }
            let parent = directory.deletingLastPathComponent().standardizedFileURL
            if parent.pathComponents.count >= directory.pathComponents.count { return false }
            directory = parent
        }
    }
}
