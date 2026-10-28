import AppKit
import Testing
@testable import devkit

nonisolated private final class ScanGate: @unchecked Sendable {
    let entered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)

    func waitUntilEntered() -> DispatchTimeoutResult {
        entered.wait(timeout: .now() + 5)
    }
}

struct CompressionSafetyTests {
    @Test @MainActor func lubanDirectoryScanPreservesRelativePathsAcrossTmpAlias() async throws {
        let directory = URL(fileURLWithPath: "/tmp/DevKitTests-Luban-\(UUID().uuidString)", isDirectory: true)
        let nested = directory.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data([1]).write(to: nested.appendingPathComponent("photo.jpg"))
        let model = LubanCompressionModel()
        model.select(urls: [directory])
        while model.isScanning { await Task.yield() }
        #expect(model.imageItems.map(\.relativePath) == ["nested/photo.jpg"])
    }

    @Test @MainActor func cancelledLubanScanCannotRestoreClearedSelection() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.png")
        try Data([1, 2, 3]).write(to: source)
        let gate = ScanGate()
        defer { gate.release.signal() }
        let model = LubanCompressionModel(scanImage: { url in
            gate.entered.signal()
            gate.release.wait()
            // A cancelled scanner may already have a result ready to deliver.
            return ImageScanResult(images: [ImageScannedImage(url: url, byteCount: 3)])
        })
        model.select(urls: [source])
        let started = await Task.detached { gate.waitUntilEntered() }.value
        #expect(started == .success)
        model.stop()
        model.clearSelection()
        gate.release.signal()
        // Allow the cancelled worker and its MainActor completion to finish.
        try await Task.sleep(for: .milliseconds(100))
        #expect(model.imageItems.isEmpty)
        #expect(model.selectedURLs.isEmpty)
        #expect(!model.isScanning)
        #expect(model.operationStatus == "请选择图片或文件夹")
    }

    @Test @MainActor func lubanSkippedImageIsCopiedWithOriginalBytesAndExtension() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let nested = directory.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let source = nested.appendingPathComponent("source.png")
        let original = Data([137, 80, 78, 71, 1, 2, 3])
        try original.write(to: source)
        let compressible = directory.appendingPathComponent("compressible.png")
        try pngFixture().write(to: compressible)
        let suiteName = "DevKitTests-Luban-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let model = LubanCompressionModel(preferencesDefaults: defaults, outputBaseDirectory: directory)
        model.minimumCompressionSizeKB = 1
        model.select(urls: [directory])
        while model.isScanning { await Task.yield() }
        let worker = try #require(model.run())
        await worker.value
        let output = try #require(model.outputDirectoryURL)
        #expect(!model.isRunning)
        let item = try #require(model.imageItems.first { $0.id.resolvingSymlinksInPath() == source.resolvingSymlinksInPath() })
        #expect(item.status == .skipped)
        let result = URL(fileURLWithPath: try #require(item.destinationPath))
        #expect(result.pathExtension == "png")
        #expect(result == output.appendingPathComponent("nested/source.png"))
        #expect(try Data(contentsOf: result) == original)
        #expect(try Data(contentsOf: source) == original)
        #expect(model.imageItems.first { $0.id.resolvingSymlinksInPath() == compressible.resolvingSymlinksInPath() }?.status == .success)
    }

    @Test @MainActor func lubanCompressionCannotOverwriteSkippedSameNamedJPEG() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let skipped = directory.appendingPathComponent("photo.jpg")
        let skippedBytes = Data("unchanged-jpeg".utf8)
        try skippedBytes.write(to: skipped)
        let pngBytes = try pngFixture()
        #expect(pngBytes.count > 1024)
        let compressed = directory.appendingPathComponent("photo.png")
        try pngBytes.write(to: compressed)
        let suiteName = "DevKitTests-Luban-Collision-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let model = LubanCompressionModel(preferencesDefaults: defaults, outputBaseDirectory: directory)
        model.minimumCompressionSizeKB = 1
        // Put compression first to ensure name reservation does not depend on processing order.
        model.select(urls: [compressed, skipped])
        while model.isScanning { await Task.yield() }
        let worker = try #require(model.run())
        await worker.value
        #expect(!model.isRunning)
        let completedItem = try #require(model.imageItems.first { $0.id.resolvingSymlinksInPath() == compressed.resolvingSymlinksInPath() })
        let skippedItem = try #require(model.imageItems.first { $0.id.resolvingSymlinksInPath() == skipped.resolvingSymlinksInPath() })
        #expect(completedItem.status == .success)
        #expect(skippedItem.status == .skipped)
        let result = URL(fileURLWithPath: try #require(completedItem.destinationPath))
        let preserved = URL(fileURLWithPath: try #require(skippedItem.destinationPath))
        #expect(result != preserved)
        #expect(result.lastPathComponent == "photo_2.jpg")
        #expect(preserved.lastPathComponent == "photo.jpg")
        #expect(try Data(contentsOf: preserved) == skippedBytes)
        #expect(NSImage(contentsOf: result) != nil)
        #expect(try Data(contentsOf: skipped) == skippedBytes)
        #expect(try Data(contentsOf: compressed) == pngBytes)
    }

    @MainActor private func pngFixture() throws -> Data {
        let bitmap = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 64, pixelsHigh: 64, bitsPerSample: 8,
            samplesPerPixel: 3, hasAlpha: false, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))
        let pixels = try #require(bitmap.bitmapData)
        var seed: UInt32 = 42
        for index in 0..<(bitmap.bytesPerRow * bitmap.pixelsHigh) {
            seed = seed &* 1_664_525 &+ 1_013_904_223
            pixels[index] = UInt8(truncatingIfNeeded: seed >> 16)
        }
        return try #require(bitmap.representation(using: .png, properties: [:]))
    }

    @Test func videoFallbackKeepsContainerExtensionAndAvoidsExistingFiles() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let output = directory.appendingPathComponent("output")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("video.mov")
        let existing = output.appendingPathComponent("video.mov")
        try Data("mov-container".utf8).write(to: source)
        try Data("existing".utf8).write(to: existing)
        let result = try MediaVideoCompressor().copyOriginal(at: source, into: output)
        #expect(result.pathExtension == "mov")
        #expect(result != existing)
        #expect(try Data(contentsOf: result) == Data(contentsOf: source))
        #expect(try Data(contentsOf: existing) == Data("existing".utf8))
    }

    @Test func cancelledVideoDoesNotCreateOutput() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let task = Task.detached {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await MediaVideoCompressor().compressVideo(
                at: directory.appendingPathComponent("missing.mov"), relativeDir: nil,
                config: MediaVideoCompressionConfig(preset: .medium, batchDirectory: directory),
                progressHandler: { _ in }
            )
        }
        do {
            _ = try await task.value
            Issue.record("Expected cancellation before opening the source or creating output")
        } catch is CancellationError {
            #expect(!FileManager.default.fileExists(atPath: directory.path))
        }
    }
}
