import Foundation
import Darwin

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

    static func restore(
        originalURL: URL, sourceURL: URL, destinationURL: URL,
        replacesOriginal: Bool, securityScopedRoots: [URL]
    ) async throws -> URL {
        try await Task.detached(priority: .userInitiated) {
            let access = securityScopedRoots.map { $0.startAccessingSecurityScopedResource() }
            defer {
                for (root, granted) in zip(securityScopedRoots, access) where granted {
                    root.stopAccessingSecurityScopedResource()
                }
            }
            let files = FileManager.default
            let destination = destinationURL.resolvingSymlinksInPath()
            let source = sourceURL.resolvingSymlinksInPath()
            let original = originalURL.resolvingSymlinksInPath()
            guard destination != original else {
                throw CaptureError(message: "缺少可恢复的原图副本，处理结果已保留。")
            }
            let restoresSource = replacesOriginal || source == destination
            var target = restoresSource ? source : destination.deletingPathExtension()
                .appendingPathExtension(source.pathExtension)
            // Format conversion must restore the original extension, without overwriting another output.
            if !restoresSource, target != destination {
                let preferred = target
                var suffix = 2
                while files.fileExists(atPath: target.path) {
                    target = preferred.deletingLastPathComponent().appendingPathComponent(
                        "\(preferred.deletingPathExtension().lastPathComponent)_\(suffix).\(preferred.pathExtension)"
                    )
                    suffix += 1
                }
            }
            let temporary = target.deletingLastPathComponent()
                .appendingPathComponent(".devkit-reset-\(UUID().uuidString)")
            defer { try? files.removeItem(at: temporary) }
            try files.copyItem(at: original, to: temporary)
            if target == destination {
                // Prepare on the destination volume, then replace atomically with permissions intact.
                guard rename(temporary.path, target.path) == 0 else {
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
                }
            } else {
                if restoresSource, files.fileExists(atPath: target.path) {
                    // A previous partial restore may have succeeded before result removal failed.
                    guard try Data(contentsOf: target, options: .mappedIfSafe)
                        == Data(contentsOf: original, options: .mappedIfSafe) else {
                        throw CaptureError(message: "原图路径已有不同内容，已保留该文件和处理结果。")
                    }
                } else {
                    try files.moveItem(at: temporary, to: target)
                }
                // A converted source may have been deleted; restore it before discarding its result.
                try files.removeItem(at: destination)
            }
            return target
        }.value
    }

    private struct CaptureError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }
}
