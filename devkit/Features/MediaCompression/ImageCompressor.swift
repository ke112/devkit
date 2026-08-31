import AppKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

struct MediaCollectedImage: Sendable {
    let url: URL
    let relativeDir: String?
}

final class MediaImageCompressor: @unchecked Sendable {
    nonisolated static let supportedExtensions: Set<String> = [
        "png", "jpg", "jpeg", "heic", "heif", "webp", "tiff", "tif", "bmp", "gif", "tga", "psd",
    ]

    static func makeBatchDirectory(under baseDirectory: URL) -> URL {
        return baseDirectory
            .appending(path: "DevKit", directoryHint: .isDirectory)
    }

    nonisolated func collectImages(from urls: [URL]) -> [MediaCollectedImage] {
        var collected: [MediaCollectedImage] = []
        for url in urls {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { continue }
            if isDirectory.boolValue {
                collected.append(contentsOf: collectImages(in: url, root: url))
            } else if Self.isSupportedImage(url) {
                collected.append(MediaCollectedImage(url: url, relativeDir: nil))
            }
        }

        var seen = Set<String>()
        return collected
            .filter { seen.insert($0.url.standardizedFileURL.path).inserted }
            .sorted { $0.url.path < $1.url.path }
    }

    enum ResultKind: Equatable, Sendable {
        case compressed
        case copiedUnderSize
        case copiedFallback
    }

    struct Result: Sendable {
        let destination: URL
        let originalBytes: Int64
        let compressedBytes: Int64
        let originalSize: CGSize
        let compressedSize: CGSize
        let usedFormat: String
        let kind: ResultKind
    }

    nonisolated private static let writableTypes: Set<String> =
        (CGImageDestinationCopyTypeIdentifiers() as? [String]).map(Set.init) ?? []

    nonisolated func compressImage(
        at sourceURL: URL,
        relativeDir: String?,
        config: MediaImageCompressionConfig
    ) throws -> Result {
        guard Self.isSupportedImage(sourceURL) else { throw MediaCompressorError.unsupportedFile }
        let originalBytes = try fileSize(of: sourceURL)
        let sourceImage = try loadCGImage(from: sourceURL)
        let originalSize = CGSize(width: sourceImage.width, height: sourceImage.height)
        let outputDirectory = try makeOutputDirectory(batch: config.batchDirectory, relativeDir: relativeDir)

        if originalBytes <= config.targetBytes {
            let destination = uniqueURL(for: sourceURL, in: outputDirectory)
            try FileManager.default.copyItem(at: sourceURL, to: destination)
            return Result(
                destination: destination,
                originalBytes: originalBytes,
                compressedBytes: originalBytes,
                originalSize: originalSize,
                compressedSize: originalSize,
                usedFormat: sourceURL.pathExtension.uppercased(),
                kind: .copiedUnderSize
            )
        }

        for candidate in formatPipeline(for: config.outputFormat, sourceURL: sourceURL)
            where Self.writableTypes.contains(candidate.uti) {
            if let encoded = try attemptCompression(
                image: sourceImage,
                destinationType: candidate.uti as CFString,
                targetBytes: config.targetBytes
            ) {
                let destination = uniqueURL(for: sourceURL, in: outputDirectory, fileExtension: fileExtension(for: candidate.uti))
                try encoded.write(to: destination, options: .atomic)
                let compressedImage = try? loadCGImage(from: destination)
                return Result(
                    destination: destination,
                    originalBytes: originalBytes,
                    compressedBytes: Int64(encoded.count),
                    originalSize: originalSize,
                    compressedSize: compressedImage.map { CGSize(width: $0.width, height: $0.height) } ?? originalSize,
                    usedFormat: candidate.name,
                    kind: .compressed
                )
            }
        }

        let destination = uniqueURL(for: sourceURL, in: outputDirectory)
        try FileManager.default.copyItem(at: sourceURL, to: destination)
        return Result(
            destination: destination,
            originalBytes: originalBytes,
            compressedBytes: originalBytes,
            originalSize: originalSize,
            compressedSize: originalSize,
            usedFormat: sourceURL.pathExtension.uppercased(),
            kind: .copiedFallback
        )
    }

    nonisolated static func isSupportedImage(_ url: URL) -> Bool {
        supportedExtensions.contains(url.pathExtension.lowercased())
    }

    nonisolated func loadCGImage(from url: URL) throws -> CGImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw MediaCompressorError.cannotReadImage
        }
        return image
    }

    private struct FormatCandidate {
        let name: String
        let uti: String
    }

    nonisolated private func formatPipeline(for format: MediaOutputFormat, sourceURL: URL) -> [FormatCandidate] {
        switch format {
        case .jpeg: return [FormatCandidate(name: "JPEG", uti: UTType.jpeg.identifier)]
        case .png: return [FormatCandidate(name: "PNG", uti: UTType.png.identifier)]
        case .heic: return [FormatCandidate(name: "HEIC", uti: UTType.heic.identifier)]
        case .auto:
            let sourceType = sourceType(for: sourceURL)
            let lossless: Set<String> = [
                UTType.png.identifier, UTType.bmp.identifier, UTType.tiff.identifier,
                UTType.gif.identifier, "com.truevision.tga-image", "com.adobe.photoshop-image",
            ]
            var candidates = [FormatCandidate(name: fileExtension(for: sourceType), uti: sourceType)]
            if lossless.contains(sourceType) {
                candidates.append(FormatCandidate(name: "HEIC", uti: UTType.heic.identifier))
                candidates.append(FormatCandidate(name: "JPEG", uti: UTType.jpeg.identifier))
            }
            return candidates
        }
    }

    nonisolated private func attemptCompression(image: CGImage, destinationType: CFString, targetBytes: Int64) throws -> Data? {
        if let original = try qualitySearch(image: image, destinationType: destinationType, targetBytes: targetBytes) {
            return original
        }

        // Binary-search the scale instead of trying 22 fixed sizes; this keeps large batches responsive.
        var lower: CGFloat = 0.05
        var upper: CGFloat = 0.95
        var best: Data?
        for _ in 0..<8 {
            let scale = (lower + upper) / 2
            let resized = resize(image, scale: scale)
            if let candidate = try qualitySearch(image: resized, destinationType: destinationType, targetBytes: targetBytes) {
                best = candidate
                lower = scale
            } else {
                upper = scale
            }
        }
        return best
    }

    nonisolated private func qualitySearch(image: CGImage, destinationType: CFString, targetBytes: Int64) throws -> Data? {
        if destinationType == UTType.png.identifier as CFString {
            let data = try encode(image: image, type: destinationType, quality: nil)
            return Int64(data.count) <= targetBytes ? data : nil
        }

        var low: CGFloat = 0.01
        var high: CGFloat = 1
        var best: Data?
        for _ in 0..<16 {
            let data = try encode(image: image, type: destinationType, quality: (low + high) / 2)
            if Int64(data.count) <= targetBytes {
                best = data
                low = (low + high) / 2
            } else {
                high = (low + high) / 2
            }
        }
        return best
    }

    nonisolated private func encode(image: CGImage, type: CFString, quality: CGFloat?) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, type, 1, nil) else {
            throw MediaCompressorError.cannotCreateDestination
        }
        var options: [CFString: Any] = [:]
        if let quality { options[kCGImageDestinationLossyCompressionQuality] = quality }
        CGImageDestinationAddImage(destination, image, options as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw MediaCompressorError.cannotCreateDestination }
        return data as Data
    }

    nonisolated private func resize(_ image: CGImage, scale: CGFloat) -> CGImage {
        let width = max(Int(CGFloat(image.width) * scale), 1)
        let height = max(Int(CGFloat(image.height) * scale), 1)
        let colorSpace = image.colorSpace ?? CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return image }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage() ?? image
    }

    nonisolated private func sourceType(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "png": UTType.png.identifier
        case "heic", "heif": UTType.heic.identifier
        case "jpg", "jpeg": UTType.jpeg.identifier
        case "webp": "org.webmproject.webp"
        case "tiff", "tif": UTType.tiff.identifier
        case "bmp": UTType.bmp.identifier
        case "gif": UTType.gif.identifier
        case "tga": "com.truevision.tga-image"
        case "psd": "com.adobe.photoshop-image"
        default: UTType.jpeg.identifier
        }
    }

    nonisolated private func fileExtension(for uti: String) -> String {
        switch uti {
        case UTType.heic.identifier: "heic"
        case UTType.png.identifier: "png"
        case UTType.tiff.identifier: "tiff"
        case UTType.bmp.identifier: "bmp"
        case UTType.gif.identifier: "gif"
        case "org.webmproject.webp": "webp"
        case "com.truevision.tga-image": "tga"
        case "com.adobe.photoshop-image": "psd"
        default: "jpg"
        }
    }

    nonisolated private func collectImages(in directory: URL, root: URL) -> [MediaCollectedImage] {
        guard let enumerator = FileManager.default.enumerator(
            at: directory, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]
        ) else { return [] }
        return enumerator.compactMap { value in
            guard let url = value as? URL, Self.isSupportedImage(url) else { return nil }
            let relativeComponents = url.deletingLastPathComponent().standardizedFileURL.pathComponents
                .dropFirst(root.standardizedFileURL.pathComponents.count)
            let relativeDir = relativeComponents.isEmpty ? nil : relativeComponents.joined(separator: "/")
            return MediaCollectedImage(url: url, relativeDir: relativeDir)
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
        let resolvedExtension = fileExtension ?? source.pathExtension.lowercased()
        var candidate = directory.appending(path: "\(base).\(resolvedExtension)")
        var index = 1
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = directory.appending(path: "\(base)_\(index).\(resolvedExtension)")
            index += 1
        }
        return candidate
    }

    nonisolated private func fileSize(of url: URL) throws -> Int64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.size] as? NSNumber)?.int64Value ?? 0
    }
}
