import AVFoundation
import Foundation

struct MediaCollectedVideo: Sendable {
    let url: URL
    let relativeDir: String?
}

final class MediaVideoCompressor: @unchecked Sendable {
    nonisolated static let supportedExtensions: Set<String> = ["mp4", "mov", "m4v"]

    nonisolated static func makeBatchDirectory(under baseDirectory: URL) -> URL {
        return baseDirectory
            .appending(path: "DevKit", directoryHint: .isDirectory)
    }

    nonisolated func collectVideos(from urls: [URL]) -> [MediaCollectedVideo] {
        var collected: [MediaCollectedVideo] = []
        for url in urls {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { continue }
            if isDirectory.boolValue {
                collected.append(contentsOf: collectVideos(in: url, root: url))
            } else if Self.isSupportedVideo(url) {
                collected.append(MediaCollectedVideo(url: url, relativeDir: nil))
            }
        }
        var seen = Set<String>()
        return collected
            .filter { seen.insert($0.url.standardizedFileURL.path).inserted }
            .sorted { $0.url.path < $1.url.path }
    }

    struct Result: Sendable {
        let destination: URL
        let originalBytes: Int64
        let compressedBytes: Int64
        let duration: Double
        let isCopiedFallback: Bool
    }

    nonisolated func compressVideo(
        at sourceURL: URL,
        relativeDir: String?,
        config: MediaVideoCompressionConfig,
        progressHandler: @escaping @Sendable (Float) -> Void
    ) async throws -> Result {
        guard Self.isSupportedVideo(sourceURL) else { throw MediaCompressorError.unsupportedFile }
        let originalBytes = try fileSize(of: sourceURL)
        let asset = AVURLAsset(url: sourceURL)
        let duration = try await CMTimeGetSeconds(asset.load(.duration))
        let outputDirectory = try makeOutputDirectory(batch: config.batchDirectory, relativeDir: relativeDir)
        let destination = uniqueURL(for: sourceURL, in: outputDirectory, fileExtension: "mp4")
        guard let session = AVAssetExportSession(
            asset: asset,
            presetName: Self.exportPreset(for: config.preset)
        ) else {
            throw MediaCompressorError.videoExportFailed("无法创建导出会话。")
        }
        session.shouldOptimizeForNetworkUse = true

        let monitor = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(200))
                progressHandler(session.progress)
                if session.progress >= 1 { break }
            }
        }
        do {
            try await session.export(to: destination, as: .mp4)
        } catch {
            monitor.cancel()
            try? FileManager.default.removeItem(at: destination)
            throw MediaCompressorError.videoExportFailed(error.localizedDescription)
        }
        monitor.cancel()

        let compressedBytes = try fileSize(of: destination)
        if compressedBytes >= originalBytes {
            try FileManager.default.removeItem(at: destination)
            try FileManager.default.copyItem(at: sourceURL, to: destination)
            return Result(destination: destination, originalBytes: originalBytes, compressedBytes: originalBytes, duration: duration, isCopiedFallback: true)
        }
        return Result(destination: destination, originalBytes: originalBytes, compressedBytes: compressedBytes, duration: duration, isCopiedFallback: false)
    }

    nonisolated static func isSupportedVideo(_ url: URL) -> Bool {
        supportedExtensions.contains(url.pathExtension.lowercased())
    }

    nonisolated private func collectVideos(in directory: URL, root: URL) -> [MediaCollectedVideo] {
        guard let enumerator = FileManager.default.enumerator(
            at: directory, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]
        ) else { return [] }
        return enumerator.compactMap { value in
            guard let url = value as? URL, Self.isSupportedVideo(url) else { return nil }
            let relativeComponents = url.deletingLastPathComponent().standardizedFileURL.pathComponents
                .dropFirst(root.standardizedFileURL.pathComponents.count)
            let relativeDir = relativeComponents.isEmpty ? nil : relativeComponents.joined(separator: "/")
            return MediaCollectedVideo(url: url, relativeDir: relativeDir)
        }
    }

    nonisolated private func makeOutputDirectory(batch: URL, relativeDir: String?) throws -> URL {
        let directory = relativeDir.map { batch.appending(path: $0, directoryHint: .isDirectory) } ?? batch
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            return directory
        } catch {
            throw MediaCompressorError.cannotWriteDetail("创建目录失败：\(directory.path) - \(error.localizedDescription)")
        }
    }

    nonisolated private func uniqueURL(for source: URL, in directory: URL, fileExtension: String? = nil) -> URL {
        let base = source.deletingPathExtension().lastPathComponent
        let ext = fileExtension ?? source.pathExtension.lowercased()
        var candidate = directory.appending(path: "\(base).\(ext)")
        var index = 1
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = directory.appending(path: "\(base)_\(index).\(ext)")
            index += 1
        }
        return candidate
    }

    nonisolated static func exportPreset(for preset: MediaVideoPreset) -> String {
        // These presets control codec/bitrate quality. Resolution presets alone can
        // increase the bitrate of already-compressed source videos.
        switch preset {
        case .high: return AVAssetExportPresetHighestQuality
        case .medium: return AVAssetExportPresetMediumQuality
        case .low: return AVAssetExportPresetLowQuality
        }
    }

    nonisolated private func fileSize(of url: URL) throws -> Int64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.size] as? NSNumber)?.int64Value ?? 0
    }
}
