import Foundation

/// Replacement jobs keep source bytes for comparison until the task list is released.
nonisolated final class ImageCompressionOriginals: Sendable {
    private let directoryURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("DevKitImageComparison-\(UUID().uuidString)", isDirectory: true)

    deinit {
        try? FileManager.default.removeItem(at: directoryURL)
    }

    func capture(at sourceURL: URL) async throws -> URL {
        let directoryURL = directoryURL
        return try await Task.detached(priority: .userInitiated) {
            let hasAccess = sourceURL.startAccessingSecurityScopedResource()
            defer {
                if hasAccess { sourceURL.stopAccessingSecurityScopedResource() }
            }
            do {
                let folder = directoryURL.appendingPathComponent(UUID().uuidString, isDirectory: true)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let copy = folder.appendingPathComponent(sourceURL.lastPathComponent)
                try FileManager.default.copyItem(at: sourceURL, to: copy)
                return copy
            } catch {
                throw CaptureError(message: "无法保留原图用于对比：\(sourceURL.lastPathComponent)。\(error.localizedDescription)")
            }
        }.value
    }

    private struct CaptureError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }
}
