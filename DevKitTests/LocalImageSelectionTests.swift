import AppKit
import Testing
@testable import devkit

@MainActor
struct LocalImageSelectionTests {
    @Test func bothToolsPreserveSizeOrderingAndThresholdOverrides() async throws {
        let defaults = try #require(UserDefaults(suiteName: "LocalSelection-\(UUID().uuidString)"))
        let a = URL(fileURLWithPath: "/tmp/a.png")
        let b = URL(fileURLWithPath: "/tmp/b.png")
        let small = URL(fileURLWithPath: "/tmp/small.png")
        let luban = LubanCompressionModel(preferencesDefaults: defaults)
        luban.imageItems = [
            LubanImageItem(id: a, relativePath: "a.png", byteCount: 2048, status: .waiting),
            LubanImageItem(id: b, relativePath: "b.png", byteCount: 2048, status: .waiting),
            LubanImageItem(id: small, relativePath: "small.png", byteCount: 1, status: .waiting)
        ]
        luban.minimumCompressionSizeKB = 1
        await checkSelectionOrder(luban, a: a, b: b, small: small)
        luban.minimumCompressionSizeKB = 100
        #expect(luban.imageItems.map(\.status) == [.skipped, .waiting, .waiting])

        let webp = WebPConversionModel(preferencesDefaults: defaults)
        webp.imageItems = [
            WebPImageItem(id: a, relativePath: "a.png", byteCount: 2048, status: .waiting),
            WebPImageItem(id: b, relativePath: "b.png", byteCount: 2048, status: .waiting),
            WebPImageItem(id: small, relativePath: "small.png", byteCount: 1, status: .waiting)
        ]
        webp.minimumCompressionSizeKB = 1
        await checkSelectionOrder(webp, a: a, b: b, small: small)
        webp.minimumCompressionSizeKB = 100
        #expect(webp.imageItems.map(\.status) == [.skipped, .waiting, .waiting])
    }

    private func checkSelectionOrder<M: ImageCompressionSelectionModel>(
        _ model: M, a: URL, b: URL, small: URL
    ) async {
        #expect(model.displayGroups[1].tasks.map(\.id) == [small])
        await model.setCompressionEnabled(false, for: b)
        await model.setCompressionEnabled(false, for: a)
        #expect(model.displayGroups[1].tasks.map(\.id) == [a, b, small])
        await model.setCompressionEnabled(true, for: b)
        await model.setCompressionEnabled(true, for: small)
        #expect(model.displayGroups[0].tasks.map(\.id) == [b, small])
        #expect(model.displayGroups[1].tasks.map(\.id) == [a])
    }

    @Test func existingWebPStaysSkippedWithItsSwitchDisabled() async throws {
        let defaults = try #require(UserDefaults(suiteName: "WebPSelection-\(UUID().uuidString)"))
        let model = WebPConversionModel(preferencesDefaults: defaults)
        let source = URL(fileURLWithPath: "/tmp/existing.webp")
        model.imageItems = [WebPImageItem(id: source, relativePath: "existing.webp", byteCount: 1024, status: .skipped)]
        await model.setCompressionEnabled(true, for: source)
        #expect(model.imageItems[0].status == .skipped)
        #expect(model.displayGroups[1].tasks[0].compressionEnabled == false)
        #expect(!model.displayGroups[1].tasks[0].compressionToggleAllowed)
        #expect(model.displayGroups[1].title == "已跳过转换")
    }

    @Test(arguments: [false, true]) func webPInputRootsMatchDirectoryURLsAndPathAliases(canonicalRoot: Bool) async throws {
        let directory = URL(fileURLWithPath: "/tmp/WebPInputs-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.png")
        try Data("original".utf8).write(to: source)
        let defaults = try #require(UserDefaults(suiteName: "WebPInputs-\(UUID().uuidString)"))
        let model = WebPConversionModel(preferencesDefaults: defaults)
        let input = canonicalRoot ? directory.resolvingSymlinksInPath() : directory
        #expect(model.select(urls: [input]))
        while model.isScanning { await Task.yield() }
        #expect(model.canRun)
        #expect(model.inputURLsForPendingItems() == model.selectedURLs)
        // Simulate the importer retaining one alias while scanner URLs use the other.
        model.imageItems = [WebPImageItem(id: source.resolvingSymlinksInPath(), relativePath: "source.png",
                                         byteCount: 8, status: .waiting)]
        #expect(model.inputURLsForPendingItems() == model.selectedURLs)
        model.imageItems[0].status = .success
        #expect(model.inputURLsForPendingItems().isEmpty)
    }

    @Test func webPAutomaticSkipsFollowThresholdAfterRunWhileNonShrinkingResultsStayOff() throws {
        let defaults = try #require(UserDefaults(suiteName: "WebPSkipEvents-\(UUID().uuidString)"))
        let model = WebPConversionModel(preferencesDefaults: defaults)
        model.minimumCompressionSizeKB = 1
        let small = URL(fileURLWithPath: "/tmp/auto-small.png")
        let attempted = URL(fileURLWithPath: "/tmp/attempted.png")
        model.imageItems = [
            WebPImageItem(id: small, relativePath: "auto-small.png", byteCount: 8, status: .skipped),
            WebPImageItem(id: attempted, relativePath: "attempted.png", byteCount: 2048, status: .working)
        ]
        for (url, bytes) in [(small, Int64(8)), (attempted, Int64(2048))] {
            model.applyProcessEvent(ImageCompressionProcessEvent(
                src: url.path, dst: nil, ok: false, before: bytes, after: bytes,
                skipped: true, elapsed: 0, error: "原文件保持不变"
            ))
        }
        #expect(model.imageItems[0].compressionOverride == nil)
        #expect(model.imageItems[1].compressionOverride == false)
        model.minimumCompressionSizeKB = 0
        #expect(model.imageItems.map(\.status) == [.waiting, .skipped])
    }

    @Test(arguments: [false, true]) func outputResetRestoresFormatWithoutOverwritingAnotherFile(webp: Bool) async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.png")
        let result = directory.appendingPathComponent(webp ? "output.webp" : "output.jpg")
        let collision = directory.appendingPathComponent("output.png")
        let original = Data("original-png-bytes".utf8)
        try original.write(to: source)
        try Data("compressed".utf8).write(to: result)
        try Data("keep-other-output".utf8).write(to: collision)
        if webp {
            let model = WebPConversionModel()
            model.imageItems = [WebPImageItem(id: source, relativePath: "source.png", byteCount: 18,
                                             status: .success, destinationPath: result.path)]
            try await checkOutputReset(model, source: source, result: result, original: original)
        } else {
            let model = LubanCompressionModel()
            model.imageItems = [LubanImageItem(id: source, relativePath: "source.png", byteCount: 18,
                                              status: .success, destinationPath: result.path)]
            try await checkOutputReset(model, source: source, result: result, original: original)
        }
        #expect(try Data(contentsOf: collision) == Data("keep-other-output".utf8))
    }

    private func checkOutputReset<M: ImageCompressionSelectionModel>(
        _ model: M, source: URL, result: URL, original: Data
    ) async throws {
        await model.resetResult(for: source)
        #expect(model.alertMessage == nil)
        #expect(model.imageItems[0].status == .skipped)
        #expect(model.imageItems[0].compressionOverride == false)
        #expect(!FileManager.default.fileExists(atPath: result.path))
        if let path = model.imageItems[0].destinationPath {
            let restored = URL(fileURLWithPath: path)
            #expect(restored.lastPathComponent == "output_2.png")
            #expect(try Data(contentsOf: restored) == original)
        } else {
            Issue.record("Reset should keep the restored original destination")
        }
        #expect(try Data(contentsOf: source) == original)
        await model.setCompressionEnabled(true, for: source)
        #expect(model.imageItems[0].status == .waiting)
    }

    @Test(arguments: [false, true]) func webPReplacementResetRestoresDeletedSourceOrProtectsRecreatedFile(conflict: Bool) async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.png")
        let result = directory.appendingPathComponent("source_2.webp")
        let existingWebP = directory.appendingPathComponent("source.webp")
        let original = Data("original-png-bytes".utf8)
        try original.write(to: source)
        let snapshots = ImageCompressionOriginals()
        let snapshot = try await snapshots.capture(at: source)
        try FileManager.default.removeItem(at: source)
        try Data("compressed".utf8).write(to: result)
        try Data("existing-webp".utf8).write(to: existingWebP)
        if conflict { try Data("recreated-source".utf8).write(to: source) }
        let model = WebPConversionModel()
        model.imageItems = [WebPImageItem(
            id: source, relativePath: "source.png", byteCount: Int64(original.count), status: .success,
            destinationPath: result.path, previewOriginalURL: snapshot, resultReplacedOriginal: true
        )]
        // The global switch may have changed since this result was created.
        model.replaceOriginals = false
        await model.resetResult(for: source)
        if conflict {
            #expect(model.alertMessage != nil)
            #expect(model.imageItems[0].status == .success)
            #expect(try Data(contentsOf: source) == Data("recreated-source".utf8))
            #expect(try Data(contentsOf: result) == Data("compressed".utf8))
        } else {
            #expect(model.alertMessage == nil)
            #expect(model.imageItems[0].status == .skipped)
            #expect(try Data(contentsOf: source) == original)
            #expect(!FileManager.default.fileExists(atPath: result.path))
        }
        #expect(try Data(contentsOf: existingWebP) == Data("existing-webp".utf8))
        withExtendedLifetime(snapshots) {}
    }

    @Test func lubanManualExclusionCopiesOriginalAndPreservesCompletedResultsOnNextRun() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let excluded = directory.appendingPathComponent("photo.jpg")
        let bitmap = try #require(NSBitmapImageRep(data: pngFixture()))
        let jpeg = try #require(bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.9]))
        try jpeg.write(to: excluded)
        let source = directory.appendingPathComponent("photo.png")
        try pngFixture().write(to: source)
        let defaults = try #require(UserDefaults(suiteName: "LubanExecution-\(UUID().uuidString)"))
        let model = LubanCompressionModel(preferencesDefaults: defaults, outputBaseDirectory: directory)
        model.minimumCompressionSizeKB = 0
        model.select(urls: [excluded, source])
        while model.isScanning { await Task.yield() }
        await model.setCompressionEnabled(false, for: excluded)
        await (try #require(model.run())).value
        let completed = try #require(model.imageItems.first { $0.id == source })
        #expect(completed.status == .success)
        #expect(URL(fileURLWithPath: try #require(completed.destinationPath)).lastPathComponent == "photo_2.jpg")
        let skipped = try #require(model.imageItems.first { $0.id == excluded })
        #expect(skipped.status == .skipped)
        #expect(try Data(contentsOf: URL(fileURLWithPath: #require(skipped.destinationPath))) == Data(contentsOf: excluded))
        #expect(!model.canRun)
        // A manually enabled image below the threshold still participates.
        await model.setCompressionEnabled(true, for: excluded)
        model.minimumCompressionSizeKB = 1000
        #expect(model.isCompressionEnabled(for: try #require(model.imageItems.first { $0.id == excluded })))
        await (try #require(model.run())).value
        #expect(model.imageItems.first { $0.id == source } == completed)
        #expect(model.imageItems.first { $0.id == excluded }?.status == .success)
    }

    private func pngFixture() throws -> Data {
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

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
