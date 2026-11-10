import AppKit
import Luban
import Testing
@testable import devkit

@MainActor
struct ImageCompressionContinuationTests {
    @Test func allToolsShareContinuationAvailability() throws {
        let defaults = try #require(UserDefaults(suiteName: "Continuation-\(UUID().uuidString)"))
        try checkAvailability(TinyPNGModel(preferencesDefaults: defaults))
        try checkAvailability(LubanCompressionModel(preferencesDefaults: defaults))
        try checkAvailability(WebPConversionModel(preferencesDefaults: defaults))
    }

    private func checkAvailability<M: ImageCompressionSelectionModel>(_ model: M) throws {
        let source = URL(fileURLWithPath: "/tmp/original.png")
        model.selectedURLs = [source]
        var item = model.makeSelectionItem(ImageScannedImage(url: source, byteCount: 1024), relativePath: "original.png")
        item.status = .success
        item.destinationPath = "/tmp/result.webp"
        model.imageItems = [item]
        #expect(model.canRun)
        #expect(model.startButtonLabel == "继续压缩")
        #expect(model.displayGroups[0].tasks[0].canContinueCompression)
        model.isRunning = true
        #expect(!model.canRun)
        #expect(model.continueCompression(for: source) == nil)
        model.isRunning = false
        model.imageItems[0].status = .skipped
        #expect(!model.displayGroups[1].tasks[0].canContinueCompression)
    }

    @Test(arguments: [false, true])
    func singleThenBatchUsesLatestResultAndResetKeepsFirstOriginal(replacement: Bool) async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("original.png")
        let second = directory.appendingPathComponent("other.png")
        let original = try imageData(width: 64, format: .png)
        try original.write(to: source)
        try original.write(to: second)
        let snapshots = ImageCompressionOriginals()
        let snapshot = try await snapshots.capture(at: source)
        let result = replacement ? source : directory.appendingPathComponent("result.jpg")
        // Different pixels and dimensions prove that the result, rather than the original, is encoded.
        let firstResult = try imageData(width: 128, format: .jpeg)
        try firstResult.write(to: result)
        let expectedURL = try await Luban.compress(result, to: directory.appendingPathComponent("expected.jpg"))
        let expected = try Data(contentsOf: expectedURL)
        #expect(expected.count < firstResult.count)
        let defaults = try #require(UserDefaults(suiteName: "Continuation-\(UUID().uuidString)"))
        let model = LubanCompressionModel(preferencesDefaults: defaults)
        model.selectedURLs = [source, second]
        model.imageItems = [
            LubanImageItem(id: source, relativePath: "original.png", byteCount: Int64(original.count),
                           status: .success, compressedByteCount: Int64(firstResult.count),
                           destinationPath: result.path, previewOriginalURL: snapshot,
                           resultReplacedOriginal: replacement),
            LubanImageItem(id: second, relativePath: "other.png", byteCount: Int64(original.count), status: .waiting)
        ]
        // Continuation ignores the current threshold and retains the completed result's replacement mode.
        model.minimumCompressionSizeKB = 1000
        model.replaceOriginals = !replacement
        let otherItem = model.imageItems[1]
        await (try #require(model.continueCompression(for: source))).value
        #expect(model.alertMessage == nil)
        #expect(try Data(contentsOf: result) == expected)
        #expect(model.imageItems[1] == otherItem)
        #expect(model.imageItems[0].byteCount == Int64(original.count))
        #expect(model.imageItems[0].resultReplacedOriginal == replacement)
        #expect(model.imageItems[0].previewOriginalURL == snapshot)
        #expect(model.imageItems[0].destinationPath == result.path)
        let firstCompleted = model.imageItems[0]
        let expectedAgainURL = try await Luban.compress(result, to: directory.appendingPathComponent("expected-again.jpg"))
        let expectedAgain = try Data(contentsOf: expectedAgainURL)
        await (try #require(model.run())).value
        #expect(model.alertMessage == nil)
        #expect(try Data(contentsOf: result) == (expectedAgain.count < expected.count ? expectedAgain : expected))
        #expect(model.imageItems[0].id == firstCompleted.id)
        #expect(model.imageItems[0].resultByteCount == Int64(try Data(contentsOf: result).count))
        await model.resetResult(for: source)
        #expect(model.alertMessage == nil)
        #expect(model.imageItems[0].status == .skipped)
        let restored = URL(fileURLWithPath: try #require(model.imageItems[0].destinationPath))
        #expect(try Data(contentsOf: restored) == original)
        #expect(try Data(contentsOf: source) == original)
        withExtendedLifetime(snapshots) {}
    }

    @Test(arguments: [false, true])
    func failureAndCancellationPreserveSuccessfulResult(cancel: Bool) async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("original.png")
        let result = directory.appendingPathComponent("result.jpg")
        let bytes = Data("invalid-image-but-previous-success".utf8)
        try bytes.write(to: source)
        try bytes.write(to: result)
        let defaults = try #require(UserDefaults(suiteName: "Continuation-\(UUID().uuidString)"))
        let model = LubanCompressionModel(preferencesDefaults: defaults)
        model.selectedURLs = [source]
        let item = LubanImageItem(id: source, relativePath: "original.png", byteCount: 1000,
                                 status: .success, compressedByteCount: Int64(bytes.count), destinationPath: result.path)
        model.imageItems = [item]
        let worker = try #require(model.continueCompression())
        if cancel { model.stop() }
        await worker.value
        #expect(model.imageItems == [item])
        #expect(try Data(contentsOf: result) == bytes)
        #expect(model.canRun)
        #expect(!model.isRunning)
        #expect(!model.isStopping)
        #expect(cancel ? model.alertMessage == nil : model.alertMessage != nil)
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Continuation-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func imageData(width: Int, format: NSBitmapImageRep.FileType) throws -> Data {
        let bitmap = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: width, bitsPerSample: 8,
            samplesPerPixel: 3, hasAlpha: false, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0
        ))
        let pixels = try #require(bitmap.bitmapData)
        var seed: UInt32 = 42
        for index in 0..<(bitmap.bytesPerRow * bitmap.pixelsHigh) {
            seed = seed &* 1_664_525 &+ 1_013_904_223
            pixels[index] = UInt8(truncatingIfNeeded: seed >> 16)
        }
        return try #require(bitmap.representation(using: format, properties: [.compressionFactor: 1.0]))
    }
}
