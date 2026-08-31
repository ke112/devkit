import AppKit
import AVFoundation
import Testing
@testable import devkit

struct DevKitTests {
    @Test func deviceReleaseYearGroupsDevicesReleasedInTheSameYear() {
        #expect(SimulatorManager.deviceReleaseYear(from: "iPhone 17 Pro Max") == 2026)
        #expect(SimulatorManager.deviceReleaseYear(from: "iPad mini (A17 Pro)") == 2024)
        #expect(SimulatorManager.deviceReleaseYear(from: "iPad Pro 11-inch (M4)") == 2024)
        #expect(SimulatorManager.deviceReleaseYear(from: "iPad Air 13-inch (M3)") == 2025)
    }

    @Test func resolutionPixelCountUsesPhysicalResolution() {
        #expect(
            SimulatorManager.resolutionPixelCount(from: "2064*2752")
                > SimulatorManager.resolutionPixelCount(from: "2048*2732")
        )
    }

    @Test func compositeImageRetainsBottomImagePixelSize() throws {
        let bottomImage = makeImage(width: 40, height: 20, color: .red)
        let topImage = makeImage(width: 10, height: 10, color: .blue)

        let data = try CompositeImageRenderer.pngData(
            bottomImage: bottomImage,
            topImage: topImage,
            topOpacity: 0.5
        )
        let output = try #require(NSBitmapImageRep(data: data))

        #expect(output.pixelsWide == 40)
        #expect(output.pixelsHigh == 20)
    }

    @Test func compositeImageUsesLargerTopImagePixelSizeWithoutScaling() throws {
        let bottomImage = makeImage(width: 40, height: 20, color: .red)
        let topImage = makeImage(width: 80, height: 60, color: .blue)

        let data = try CompositeImageRenderer.pngData(
            bottomImage: bottomImage,
            topImage: topImage,
            topOpacity: 0.5
        )
        let output = try #require(NSBitmapImageRep(data: data))

        #expect(output.pixelsWide == 80)
        #expect(output.pixelsHigh == 60)
    }

    @Test func compositeLayoutKeepsNativeTopSizeAcrossOddAndEvenWidths() {
        let layout = CompositeImageRenderer.layout(
            bottomSize: ImagePixelSize(width: 357, height: 774),
            topSize: ImagePixelSize(width: 1_206, height: 2_622),
            transform: TopImageTransform()
        )

        #expect(layout.pixelSize == ImagePixelSize(width: 1_206, height: 2_622))
    }

    @Test func compositeLayoutUsesScreenPointsAcrossDifferentBackingScales() {
        let layout = CompositeImageRenderer.layout(
            bottomSize: ImagePixelSize(width: 357, height: 774),
            bottomBackingScale: 1,
            topSize: ImagePixelSize(width: 1_206, height: 2_622),
            topBackingScale: 3,
            transform: TopImageTransform()
        )

        #expect(layout.bottomRect.size == CGSize(width: 357, height: 774))
        #expect(layout.topRect.size == CGSize(width: 402, height: 874))
        #expect(layout.logicalBounds.size == CGSize(width: 402, height: 874))
        #expect(layout.pixelSize == ImagePixelSize(width: 1_206, height: 2_622))
    }

    @Test func imageBackingScaleDetectsCommonScreenshotConventions() {
        #expect(
            CompositeImageRenderer.suggestedBackingScale(
                for: ImagePixelSize(width: 1_206, height: 2_622),
                named: "Simulator Screenshot - iPhone 17 Pro.png"
            ) == .three
        )
        #expect(
            CompositeImageRenderer.suggestedBackingScale(
                for: ImagePixelSize(width: 357, height: 774),
                named: "screenshot.png"
            ) == .one
        )
        #expect(
            CompositeImageRenderer.suggestedBackingScale(
                for: ImagePixelSize(width: 1_440, height: 3_120),
                named: "screen-xxxhdpi.png"
            ) == .four
        )
    }

    @Test func imageBackingScalePrefersExplicitNameOverImageMetadata() {
        let image = makeImage(width: 120, height: 240, color: .blue)
        image.size = CGSize(width: 60, height: 120)

        #expect(
            CompositeImageRenderer.suggestedBackingScale(
                for: image,
                named: "icon@3x.png"
            ) == .three
        )
    }

    @Test func compositeImagePreservesLogicalPointSizeInExportMetadata() throws {
        let bottomImage = makeImage(width: 40, height: 80, color: .red)
        let topImage = makeImage(width: 120, height: 240, color: .blue)

        let data = try CompositeImageRenderer.pngData(
            bottomImage: bottomImage,
            topImage: topImage,
            topOpacity: 0.5,
            bottomBackingScale: 1,
            topBackingScale: 3
        )
        let output = try #require(NSBitmapImageRep(data: data))

        #expect(output.pixelsWide == 120)
        #expect(output.pixelsHigh == 240)
        #expect(output.size == CGSize(width: 40, height: 80))
    }

    @Test func compositeLayoutExpandsToIncludeMovedTopImage() {
        let layout = CompositeImageRenderer.layout(
            bottomSize: ImagePixelSize(width: 20, height: 20),
            topSize: ImagePixelSize(width: 10, height: 10),
            transform: TopImageTransform(
                scale: 1,
                offset: CGSize(width: 20, height: 20)
            )
        )

        #expect(layout.logicalBounds == CGRect(x: 0, y: 0, width: 35, height: 35))
        #expect(layout.pixelSize == ImagePixelSize(width: 35, height: 35))
    }

    @Test func compositeLayoutKeepsBottomImageAsMinimumBounds() {
        let layout = CompositeImageRenderer.layout(
            bottomSize: ImagePixelSize(width: 100, height: 80),
            topSize: ImagePixelSize(width: 20, height: 20),
            transform: TopImageTransform(scale: 0.5)
        )

        #expect(layout.logicalBounds == CGRect(x: 0, y: 0, width: 100, height: 80))
    }

    @Test func compositeImageLeavesUncoveredUnionAreaTransparent() throws {
        let bottomImage = makeImage(width: 20, height: 20, color: .red)
        let topImage = makeImage(width: 10, height: 10, color: .blue)

        let data = try CompositeImageRenderer.pngData(
            bottomImage: bottomImage,
            topImage: topImage,
            topOpacity: 1,
            transform: TopImageTransform(
                scale: 1,
                offset: CGSize(width: 20, height: 20)
            )
        )
        let output = try #require(NSBitmapImageRep(data: data))
        let uncoveredColor = try #require(output.colorAt(x: 30, y: 10))

        #expect(output.pixelsWide == 35)
        #expect(output.pixelsHigh == 35)
        #expect(uncoveredColor.alphaComponent == 0)
    }

    @Test func compositeOutputLimitsRejectOversizedImages() {
        #expect(
            CompositeImageOutputLimits.validationMessage(
                for: ImagePixelSize(width: 8_000, height: 8_000)
            ) == nil
        )
        #expect(
            CompositeImageOutputLimits.validationMessage(
                for: ImagePixelSize(width: 8_001, height: 8_000)
            ) != nil
        )
        #expect(
            CompositeImageOutputLimits.validationMessage(
                for: ImagePixelSize(width: 16_385, height: 1)
            ) != nil
        )
    }

    @Test func compositeImageAppliesTopImageOpacity() throws {
        let bottomImage = makeImage(width: 20, height: 20, color: .red)
        let topImage = makeImage(width: 20, height: 20, color: .blue)

        let transparentData = try CompositeImageRenderer.pngData(
            bottomImage: bottomImage,
            topImage: topImage,
            topOpacity: 0
        )
        let opaqueData = try CompositeImageRenderer.pngData(
            bottomImage: bottomImage,
            topImage: topImage,
            topOpacity: 1
        )
        let transparentOutput = try #require(NSBitmapImageRep(data: transparentData))
        let opaqueOutput = try #require(NSBitmapImageRep(data: opaqueData))
        let transparentColor = try #require(transparentOutput.colorAt(x: 10, y: 10))
        let opaqueColor = try #require(opaqueOutput.colorAt(x: 10, y: 10))

        #expect(transparentColor.redComponent > transparentColor.blueComponent)
        #expect(opaqueColor.blueComponent > opaqueColor.redComponent)
    }

    @Test func previewViewportKeepsCanvasEdgeWithinViewportCenter() {
        #expect(
            PreviewViewportBoundary.clampedCanvasCenterOffset(
                CGSize(width: 600, height: -500),
                canvasSize: CGSize(width: 800, height: 600)
            ) == CGSize(width: 400, height: -300)
        )
        #expect(
            PreviewViewportBoundary.clampedCanvasCenterOffset(
                CGSize(width: 120, height: -80),
                canvasSize: CGSize(width: 800, height: 600)
            ) == CGSize(width: 120, height: -80)
        )
    }

    @Test func homeFeaturePreferencesPreserveOrderAndVisibility() throws {
        let suiteName = "DevKitTests.HomeFeaturePreferences.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = [
            HomeFeatureSetting(feature: .imageOverlay, isVisible: false),
            HomeFeatureSetting(feature: .simulatorManagement, isVisible: true),
        ]

        HomeFeaturePreferences.save(settings, to: defaults)

        #expect(HomeFeaturePreferences.load(from: defaults) == [
            HomeFeatureSetting(feature: .imageOverlay, isVisible: false),
            HomeFeatureSetting(feature: .simulatorManagement, isVisible: true),
            HomeFeatureSetting(feature: .appStoreRelease, isVisible: true),
            HomeFeatureSetting(feature: .tinyPNG, isVisible: true),
            HomeFeatureSetting(feature: .webPConversion, isVisible: true),
            HomeFeatureSetting(feature: .mediaCompression, isVisible: true),
        ])
    }

    @Test func homeFeaturePreferencesAppendMissingFeaturesOnce() {
        let settings = HomeFeaturePreferences.normalized([
            HomeFeatureSetting(feature: .imageOverlay, isVisible: false),
            HomeFeatureSetting(feature: .imageOverlay, isVisible: true),
        ])

        #expect(settings == [
            HomeFeatureSetting(feature: .imageOverlay, isVisible: false),
            HomeFeatureSetting(feature: .simulatorManagement, isVisible: true),
            HomeFeatureSetting(feature: .appStoreRelease, isVisible: true),
            HomeFeatureSetting(feature: .tinyPNG, isVisible: true),
            HomeFeatureSetting(feature: .webPConversion, isVisible: true),
            HomeFeatureSetting(feature: .mediaCompression, isVisible: true),
        ])
    }

    @Test func homeFeaturePreferencesMoveFeatureToTargetPosition() {
        let settings = HomeFeaturePreferences.moving(
            .imageOverlay,
            to: .simulatorManagement,
            in: HomeFeaturePreferences.defaultSettings
        )

        #expect(
            settings.map(\.feature)
                == [.imageOverlay, .simulatorManagement, .appStoreRelease, .tinyPNG, .webPConversion, .mediaCompression]
        )
    }

    @Test func mediaCompressionScannersPreserveNestedPathsAndDeduplicate() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "DevKitTests-MediaCompression-\(UUID().uuidString)", directoryHint: .isDirectory)
        let nested = directory.appending(path: "nested", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        try Data([0x00]).write(to: directory.appending(path: "one.jpg"))
        try Data([0x00]).write(to: nested.appending(path: "two.png"))
        try Data([0x00]).write(to: directory.appending(path: "notes.txt"))

        let compressor = MediaImageCompressor()
        let result = compressor.collectImages(from: [directory, nested])

        #expect(Set(result.map(\.url.lastPathComponent)) == Set(["one.jpg", "two.png"]))
        #expect(
            Dictionary(uniqueKeysWithValues: result.map { ($0.url.lastPathComponent, $0.relativeDir) })
                == ["one.jpg": nil, "two.png": "nested"]
        )
    }

    @Test func mediaCompressionCopiesImageAtTargetBoundary() throws {
        let sourceDirectory = FileManager.default.temporaryDirectory
            .appending(path: "DevKitTests-MediaCompression-\(UUID().uuidString)", directoryHint: .isDirectory)
        let outputDirectory = sourceDirectory.appending(path: "output", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sourceDirectory) }

        let image = NSImage(size: NSSize(width: 2, height: 2))
        image.lockFocus()
        NSColor.systemBlue.setFill()
        NSRect(origin: .zero, size: image.size).fill()
        image.unlockFocus()
        guard let data = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: data),
              let pngData = bitmap.representation(using: .png, properties: [:]) else {
            throw CocoaError(.coderReadCorrupt)
        }
        let sourceURL = sourceDirectory.appending(path: "sample.png")
        try pngData.write(to: sourceURL)

        let result = try MediaImageCompressor().compressImage(
            at: sourceURL,
            relativeDir: nil,
            config: MediaImageCompressionConfig(
                targetBytes: Int64(pngData.count),
                outputFormat: .auto,
                batchDirectory: outputDirectory
            )
        )

        #expect(result.kind == .copiedUnderSize)
        #expect(try Data(contentsOf: result.destination) == pngData)
    }

    @Test func mediaVideoQualityUsesQualityPresets() {
        #expect(
            MediaVideoCompressor.exportPreset(for: .high)
                == AVAssetExportPresetHighestQuality
        )
        #expect(
            MediaVideoCompressor.exportPreset(for: .medium)
                == AVAssetExportPresetMediumQuality
        )
        #expect(
            MediaVideoCompressor.exportPreset(for: .low)
                == AVAssetExportPresetLowQuality
        )
    }

    @Test func mediaCompressionUsesDevKitOutputDirectory() {
        let baseDirectory = URL(fileURLWithPath: "/tmp/DevKitOutputBase", isDirectory: true)

        #expect(
            MediaImageCompressor.makeBatchDirectory(under: baseDirectory)
                == baseDirectory.appending(path: "DevKit", directoryHint: .isDirectory)
        )
        #expect(
            MediaVideoCompressor.makeBatchDirectory(under: baseDirectory)
                == baseDirectory.appending(path: "DevKit", directoryHint: .isDirectory)
        )
    }

    @Test func tinyPNGScannerRejectsOnlyImagesAboveTheFiveMBLimit() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "DevKitTests-TinyPNG-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let limit = Int(TinyPNGInputScanner.maxUploadBytes)
        try Data(repeating: 0, count: limit - 1)
            .write(to: directory.appending(path: "below.png"))
        try Data(repeating: 0, count: limit)
            .write(to: directory.appending(path: "equal.jpg"))
        try Data(repeating: 0, count: limit + 1)
            .write(to: directory.appending(path: "above.webp"))

        #expect(
            TinyPNGInputScanner.summary(for: directory)
                == TinyPNGSelectionSummary(imageCount: 3, oversizedCount: 1)
        )
    }

    @Test func tinyPNGMinimumCompressionSizeUsesStrictlyLessThanBoundary() {
        let minimumBytes = Int64(100 * 1024)
        let result = TinyPNGScanResult(images: [
            TinyPNGScannedImage(url: URL(fileURLWithPath: "/tmp/below.png"), byteCount: minimumBytes - 1),
            TinyPNGScannedImage(url: URL(fileURLWithPath: "/tmp/equal.png"), byteCount: minimumBytes),
            TinyPNGScannedImage(url: URL(fileURLWithPath: "/tmp/above.png"), byteCount: minimumBytes + 1),
        ])

        let summary = result.summary(minimumCompressionBytes: minimumBytes)

        #expect(summary.belowMinimumCount == 1)
        #expect(summary.oversizedCount == 0)
    }

    @Test func tinyPNGMinimumCompressionSizePersistsLocallyAndRefreshesWaitingItems() throws {
        let suiteName = "DevKitTests-TinyPNG-Preferences-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let model = TinyPNGModel(preferencesDefaults: defaults)
        let minimumBytes = Int64(100 * 1024)
        model.imageItems = [
            TinyPNGImageItem(
                id: URL(fileURLWithPath: "/tmp/below.png"),
                relativePath: "below.png",
                byteCount: minimumBytes - 1,
                status: .waiting
            ),
            TinyPNGImageItem(
                id: URL(fileURLWithPath: "/tmp/equal.png"),
                relativePath: "equal.png",
                byteCount: minimumBytes,
                status: .waiting
            ),
        ]

        #expect(model.minimumCompressionSizeKB == 100)
        model.minimumCompressionSizeKB = 125

        #expect(model.imageItems[0].status == .skipped)
        #expect(model.imageItems[1].status == .skipped)
        #expect(model.selectionSummary?.belowMinimumCount == 2)

        let restored = TinyPNGModel(preferencesDefaults: defaults)
        #expect(restored.minimumCompressionSizeKB == 125)

        model.minimumCompressionSizeKB = Int.max
        #expect(model.minimumCompressionSizeKB == TinyPNGModel.maximumMinimumCompressionSizeKB)
    }

    @Test func tinyPNGDefaultsToReplacingOriginals() {
        let model = TinyPNGModel()

        #expect(model.replaceOriginals)
    }

    @Test func tinyPNGFolderScanCanRunOffTheMainActor() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "DevKitTests-TinyPNG-Background-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        for index in 0..<512 {
            try Data([UInt8(index % 255)])
                .write(to: directory.appending(path: "image-\(index).png"))
        }

        let result = await Task.detached(priority: .userInitiated) {
            TinyPNGInputScanner.scan(directory)
        }.value

        #expect(
            result.summary
                == TinyPNGSelectionSummary(imageCount: 512, oversizedCount: 0, belowMinimumCount: 512)
        )
    }

    @Test func tinyPNGProgressCountsCompletedAndSkippedImages() {
        let model = TinyPNGModel()
        model.selectionSummary = TinyPNGSelectionSummary(imageCount: 4, oversizedCount: 1)
        model.imageItems = [
            TinyPNGImageItem(
                id: URL(fileURLWithPath: "/tmp/one.png"),
                relativePath: "one.png",
                byteCount: 1,
                status: .success
            ),
            TinyPNGImageItem(
                id: URL(fileURLWithPath: "/tmp/two.png"),
                relativePath: "two.png",
                byteCount: 1,
                status: .skipped
            ),
            TinyPNGImageItem(
                id: URL(fileURLWithPath: "/tmp/three.png"),
                relativePath: "three.png",
                byteCount: 1,
                status: .uploading
            ),
            TinyPNGImageItem(
                id: URL(fileURLWithPath: "/tmp/four.png"),
                relativePath: "four.png",
                byteCount: 1,
                status: .waiting
            ),
        ]

        #expect(model.completedImageCount == 2)
        #expect(model.completionPercentage == 50)
    }

    @Test func tinyPNGCompressionStatsReportTotalReduction() {
        let model = TinyPNGModel()
        model.imageItems = [
            TinyPNGImageItem(
                id: URL(fileURLWithPath: "/tmp/one.png"),
                relativePath: "one.png",
                byteCount: 1_000,
                status: .success,
                compressedByteCount: 700,
                compressionPercentage: 30
            ),
            TinyPNGImageItem(
                id: URL(fileURLWithPath: "/tmp/two.png"),
                relativePath: "two.png",
                byteCount: 3_000,
                status: .success,
                compressedByteCount: 1_500,
                compressionPercentage: 50
            ),
        ]

        let stats = model.compressionStats

        #expect(stats?.beforeBytes == 4_000)
        #expect(stats?.afterBytes == 2_200)
        #expect(stats?.savedPercentage == 45)
    }

    @Test func webPScannerCollectsSupportedImagesAndTagsWebPSources() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "DevKitTests-WebP-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        for name in ["photo.png", "photo.jpg", "capture.heic", "frame.gif", "icon.webp", "notes.txt"] {
            try Data([0x00]).write(to: directory.appending(path: name))
        }
        try FileManager.default.createDirectory(
            at: directory.appending(path: "nested", directoryHint: .isDirectory),
            withIntermediateDirectories: true
        )
        try Data([0x00]).write(to: directory.appending(path: "nested/deep.tiff"))

        let result = WebPInputScanner.scan(directory)

        #expect(result.images.count == 6)
        #expect(result.images.filter(\.isWebP).map(\.url.lastPathComponent) == ["icon.webp"])
        #expect(WebPInputScanner.accepts(directory))
        #expect(WebPInputScanner.accepts(directory.appending(path: "photo.png")))
        #expect(!WebPInputScanner.accepts(directory.appending(path: "notes.txt")))
        #expect(!WebPInputScanner.accepts(directory.appending(path: "missing.png")))
    }

    @Test func webPModelPersistsQualityAndNormalizesBounds() throws {
        let suiteName = "DevKitTests-WebP-Preferences-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let model = WebPConversionModel(preferencesDefaults: defaults)

        #expect(model.quality == 80)
        #expect(model.minimumCompressionSizeKB == 100)
        #expect(model.maximumSideLength == 0)
        #expect(model.replaceOriginals)

        model.quality = 150
        #expect(model.quality == 100)
        model.quality = 0
        #expect(model.quality == 1)
        model.quality = 75
        model.maximumSideLength = 1024
        model.minimumCompressionSizeKB = -5
        #expect(model.minimumCompressionSizeKB == 0)

        let restored = WebPConversionModel(preferencesDefaults: defaults)
        #expect(restored.quality == 75)
        #expect(restored.maximumSideLength == 1024)
    }

    @Test func webPMinimumSizeChangeRefreshesWaitingItemsButKeepsWebPSkipped() throws {
        let suiteName = "DevKitTests-WebP-Refresh-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let model = WebPConversionModel(preferencesDefaults: defaults)
        let minimumBytes = Int64(100 * 1024)
        model.imageItems = [
            WebPImageItem(
                id: URL(fileURLWithPath: "/tmp/below.png"),
                relativePath: "below.png",
                byteCount: minimumBytes - 1,
                status: .waiting
            ),
            WebPImageItem(
                id: URL(fileURLWithPath: "/tmp/equal.png"),
                relativePath: "equal.png",
                byteCount: minimumBytes,
                status: .waiting
            ),
            WebPImageItem(
                id: URL(fileURLWithPath: "/tmp/existing.webp"),
                relativePath: "existing.webp",
                byteCount: minimumBytes * 10,
                status: .skipped
            ),
        ]

        model.minimumCompressionSizeKB = 100

        #expect(model.imageItems[0].status == .skipped)
        #expect(model.imageItems[1].status == .waiting)
        #expect(model.imageItems[2].status == .skipped)
        #expect(model.selectionSummary == WebPSelectionSummary(imageCount: 3, alreadyWebPCount: 1, belowMinimumCount: 1))
    }

    @Test func webPProgressAndStatsCountSkippedImagesAsUnchanged() {
        let model = WebPConversionModel()
        model.imageItems = [
            WebPImageItem(
                id: URL(fileURLWithPath: "/tmp/one.png"),
                relativePath: "one.png",
                byteCount: 1_000,
                status: .success,
                convertedByteCount: 600,
                conversionPercentage: 40
            ),
            WebPImageItem(
                id: URL(fileURLWithPath: "/tmp/two.gif"),
                relativePath: "two.gif",
                byteCount: 2_000,
                status: .skipped,
                convertedByteCount: 2_000,
                conversionPercentage: 0
            ),
            WebPImageItem(
                id: URL(fileURLWithPath: "/tmp/three.jpg"),
                relativePath: "three.jpg",
                byteCount: 1_000,
                status: .converting
            ),
        ]

        #expect(model.completedImageCount == 2)
        #expect(model.completionPercentage == 67)
        #expect(model.conversionStats == nil)

        model.imageItems[2].status = .success
        model.imageItems[2].convertedByteCount = 300
        model.imageItems[2].conversionPercentage = 70

        let stats = model.conversionStats
        #expect(stats?.beforeBytes == 4_000)
        #expect(stats?.afterBytes == 2_900)
        #expect(abs((stats?.savedPercentage ?? 0) - 27.5) < 0.001)
    }

    @Test func dependencyBootstrapBundledScriptRunsInCheckModeWithoutSideEffects() async throws {
        let scriptURL = try #require(
            Bundle.main.url(
                forResource: DependencyBootstrap.scriptResourceName,
                withExtension: "sh"
            )
        )

        let result = try await StreamingProcess.run(
            executableURL: URL(fileURLWithPath: "/bin/bash"),
            arguments: [scriptURL.path, "--check"],
            currentDirectoryURL: FileManager.default.temporaryDirectory
        ) { _ in }

        // 0 = 全部就绪；1 = 有缺失。--check 只检测，不会触发安装。
        #expect(result.terminationStatus == 0 || result.terminationStatus == 1)
    }

    @Test func defaultTopTransformAlignsTopImageWithBottomCanvasForSameAspectScreenshots() {
        let bottomSize = ImagePixelSize(width: 1_086, height: 2_360)
        let topSize = ImagePixelSize(width: 1_206, height: 2_622)

        let transform = CompositeImageRenderer.defaultTopTransform(
            bottomSize: bottomSize,
            bottomBackingScale: 3,
            topSize: topSize,
            topBackingScale: 3
        )

        #expect(transform.scale == min(
            CGFloat(bottomSize.width) / CGFloat(topSize.width),
            CGFloat(bottomSize.height) / CGFloat(topSize.height)
        ))
        #expect(transform.offset == .zero)

        let layout = CompositeImageRenderer.layout(
            bottomSize: bottomSize,
            bottomBackingScale: 3,
            topSize: topSize,
            topBackingScale: 3,
            transform: transform
        )

        #expect(layout.pixelSize == bottomSize)
    }

    @Test func defaultTopTransformKeepsNativeScaleForIdenticalImages() {
        let transform = CompositeImageRenderer.defaultTopTransform(
            bottomSize: ImagePixelSize(width: 1_206, height: 2_622),
            bottomBackingScale: 3,
            topSize: ImagePixelSize(width: 1_206, height: 2_622),
            topBackingScale: 3
        )

        #expect(transform == TopImageTransform())
    }

    @Test func imageOverlayExportFilenameUsesComparisonPrefixAndTimestamp() {
        var components = DateComponents()
        components.year = 2026
        components.month = 8
        components.day = 28
        components.hour = 0
        components.minute = 40
        components.second = 51

        let date = Calendar.current.date(from: components)!

        #expect(ImageOverlayExportName.make(for: date) == "图片对比效果-20260828-004051")
    }

    @Test func edgeAlignmentDetectsFlushRightAndBottomEdges() {
        let layout = CompositeImageRenderer.layout(
            bottomSize: ImagePixelSize(width: 100, height: 80),
            bottomBackingScale: 1,
            topSize: ImagePixelSize(width: 50, height: 50),
            topBackingScale: 1,
            transform: TopImageTransform(offset: CGSize(width: 25, height: 15))
        )

        let alignment = CompositeImageRenderer.edgeAlignment(of: layout, tolerance: 0.5)

        #expect(alignment.right)
        #expect(alignment.bottom)
        #expect(!alignment.left)
        #expect(!alignment.top)
        #expect(alignment.isAligned)
    }

    @Test func edgeAlignmentRejectsOffsetEdgesWithinTolerance() {
        let layout = CompositeImageRenderer.layout(
            bottomSize: ImagePixelSize(width: 100, height: 80),
            bottomBackingScale: 1,
            topSize: ImagePixelSize(width: 50, height: 50),
            topBackingScale: 1,
            transform: TopImageTransform(offset: CGSize(width: 8, height: 8))
        )

        #expect(
            CompositeImageRenderer.edgeAlignment(of: layout, tolerance: 0.5)
                == CompositeEdgeAlignment(left: false, right: false, top: false, bottom: false)
        )
        #expect(
            CompositeImageRenderer.edgeAlignment(of: layout, tolerance: 20).isAligned
        )
    }

    @Test func edgeAlignmentMatchesEveryEdgeWhenImagesFullyAlign() {
        let bottomSize = ImagePixelSize(width: 1_086, height: 2_360)
        let topSize = ImagePixelSize(width: 1_206, height: 2_622)
        let transform = CompositeImageRenderer.defaultTopTransform(
            bottomSize: bottomSize,
            bottomBackingScale: 3,
            topSize: topSize,
            topBackingScale: 3
        )
        let layout = CompositeImageRenderer.layout(
            bottomSize: bottomSize,
            bottomBackingScale: 3,
            topSize: topSize,
            topBackingScale: 3,
            transform: transform
        )

        #expect(
            CompositeImageRenderer.edgeAlignment(of: layout, tolerance: 0.5)
                == CompositeEdgeAlignment(left: true, right: true, top: true, bottom: true)
        )
    }

    @Test func appStoreReleaseConfigurationPreservesEveryField() throws {
        let data = Data(
            """
            {
              "auth": {
                "issuer_id": "issuer",
                "key_id": "key",
                "private_key_path": "~/AuthKey.p8"
              },
              "app": {
                "app_id": "123",
                "bundle_id": "ai.example.app",
                "platform": "IOS",
                "version_string": "2.1.0",
                "default_name": "Example"
              },
              "import": {
                "localizations_root": "../localizations",
                "feishu_sheet_url": "https://example.com/sheet",
                "lark_identity": "auto",
                "disabled_locales": ["fr"],
                "locale_map": {"英语": "en-US"}
              },
              "upload": {
                "localizations_root": "../localizations",
                "screenshots_root": "~/Screenshots",
                "locale_screenshot_dir_map": {"en-US": "English"},
                "disabled_locales": ["fr"],
                "default_screenshot_display_type": "APP_IPHONE_67",
                "allow_create_localizations": true,
                "clear_existing_screenshots": true,
                "continue_on_locale_error": false,
                "poll_interval_seconds": 5,
                "poll_timeout_seconds": 300
              }
            }
            """.utf8
        )

        let configuration = try JSONDecoder().decode(
            AppStoreReleaseConfiguration.self,
            from: data
        )
        let encoded = try JSONEncoder().encode(configuration)
        let decoded = try JSONDecoder().decode(
            AppStoreReleaseConfiguration.self,
            from: encoded
        )

        #expect(decoded == configuration)
        #expect(decoded.app.versionString == "2.1.0")
        #expect(decoded.importSettings.localeMap == ["英语": "en-US"])
        #expect(decoded.upload.pollTimeoutSeconds == 300)
    }

    @Test func appStoreReleaseResolvesLocalizationDirectoryFromConfigDirectory() {
        let configURL = URL(
            fileURLWithPath: "/Users/test/Library/Application Support/DevKit/AppStoreRelease/config.json"
        )

        let resolved = AppStoreReleaseConfigurationFile.resolvedDirectory(
            "../localizations",
            relativeTo: configURL
        )

        #expect(
            resolved.path
                == "/Users/test/Library/Application Support/DevKit/localizations"
        )
    }

    @Test func appStoreReleaseFirstUseCreatesIndependentEmptyConfiguration() throws {
        let storageURL = FileManager.default.temporaryDirectory
            .appending(path: "DevKitTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: storageURL) }

        let prepared = try AppStoreReleaseConfigurationFile.prepareConfiguration(
            storageDirectory: storageURL
        )

        #expect(prepared.isFirstUse)
        #expect(prepared.configuration == .empty)
        #expect(
            FileManager.default.fileExists(
                atPath: AppStoreReleaseConfigurationFile
                    .configURL(storageDirectory: storageURL).path
            )
        )

        let reopened = try AppStoreReleaseConfigurationFile.prepareConfiguration(
            storageDirectory: storageURL
        )
        #expect(!reopened.isFirstUse)
    }

    @Test func importedRelativeMaterialPathsBecomeDevKitRelativePaths() {
        var configuration = AppStoreReleaseConfiguration.empty
        configuration.importSettings.localizationsRoot = "../localizations"
        configuration.upload.localizationsRoot = "../localizations"
        configuration.upload.screenshotsRoot = "screenshots"

        let normalized = AppStoreReleaseConfigurationFile.normalizedImportedConfiguration(
            configuration
        )

        #expect(normalized.importSettings.localizationsRoot == "localizations")
        #expect(normalized.upload.localizationsRoot == "localizations")
        #expect(normalized.upload.screenshotsRoot == "screenshots")
    }

    @Test func appStoreReleaseUsesIOSAndSharedMaterialSettings() {
        var configuration = AppStoreReleaseConfiguration.empty
        configuration.app.platform = "MAC_OS"
        configuration.importSettings.localizationsRoot = "/tmp/materials"
        configuration.importSettings.disabledLocales = ["fr-FR"]
        configuration.upload.localizationsRoot = "/tmp/other-materials"
        configuration.upload.disabledLocales = ["ja"]

        let normalized = AppStoreReleaseConfigurationFile.normalizedForApp(configuration)

        #expect(normalized.app.platform == "IOS")
        #expect(normalized.upload.localizationsRoot == "/tmp/materials")
        #expect(normalized.upload.disabledLocales == ["fr-FR"])
    }

    @Test func appStoreReleaseRequiresExistingScreenshotDirectory() throws {
        let storageURL = FileManager.default.temporaryDirectory
            .appending(path: "DevKitTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: storageURL) }
        try FileManager.default.createDirectory(
            at: storageURL.appending(path: "screenshots", directoryHint: .isDirectory),
            withIntermediateDirectories: true
        )
        let configURL = storageURL.appending(path: "config.json")

        #expect(
            AppStoreReleaseConfigurationFile.existingDirectory(
                "screenshots",
                relativeTo: configURL
            )?.path == storageURL.appending(path: "screenshots").path
        )
        #expect(
            AppStoreReleaseConfigurationFile.existingDirectory(
                "missing",
                relativeTo: configURL
            ) == nil
        )
        #expect(
            AppStoreReleaseConfigurationFile.existingDirectory(
                "",
                relativeTo: configURL
            ) == nil
        )
    }

    @Test func appStoreVersionsDecodeStatusAndReleaseInformation() throws {
        let data = Data(
            """
            {
              "versions": [
                {
                  "id": "version-id",
                  "versionString": "2.1.0",
                  "platform": "IOS",
                  "appStoreState": "READY_FOR_SALE",
                  "createdDate": "2026-08-16T23:45:24-07:00",
                  "releaseType": "AFTER_APPROVAL",
                  "earliestReleaseDate": null
                }
              ]
            }
            """.utf8
        )

        let response = try JSONDecoder().decode(AppStoreVersionsResponse.self, from: data)
        let version = try #require(response.versions.first)

        #expect(version.versionString == "2.1.0")
        #expect(version.stateDisplayName == "可供销售")
        #expect(version.releaseTypeDisplayName == "审核通过后")
    }

    @Test func appStoreVersionValidationAcceptsAppleNumericVersionFormat() {
        #expect(AppStoreVersion.isValidVersionString("2.1.0"))
        #expect(AppStoreVersion.isValidVersionString("2"))
        #expect(!AppStoreVersion.isValidVersionString("2.beta"))
        #expect(!AppStoreVersion.isValidVersionString("1.2.3.4"))
    }

    @Test func appStoreVersionExtractsMissingExpectedVersionFromUploadFailure() {
        let output = "{\"error\": \"找不到 version_string=2.3.0 的 IOS 版本。\"}"

        #expect(AppStoreVersion.missingVersion(in: output, expectedVersion: "2.3.0") == "2.3.0")
        #expect(AppStoreVersion.missingVersion(in: output, expectedVersion: "2.2.0") == nil)
        #expect(AppStoreVersion.missingVersion(in: "认证失败", expectedVersion: "2.3.0") == nil)
    }

    @Test func streamingProcessReturnsCompleteOutput() async throws {
        let result = try await StreamingProcess.run(
            executableURL: URL(fileURLWithPath: "/bin/echo"),
            arguments: ["missing-version-output"],
            currentDirectoryURL: FileManager.default.temporaryDirectory
        ) { _ in }

        #expect(result.terminationStatus == 0)
        #expect(result.output == "missing-version-output\n")
    }

    @Test func streamingProcessCancellationTerminatesChildProcess() async throws {
        let cancellation = StreamingProcessCancellation()
        let task = Task {
            try await StreamingProcess.run(
                executableURL: URL(fileURLWithPath: "/bin/sleep"),
                arguments: ["5"],
                currentDirectoryURL: FileManager.default.temporaryDirectory,
                cancellation: cancellation,
                onOutput: { _ in }
            )
        }

        try await Task.sleep(nanoseconds: 100_000_000)
        cancellation.cancel()
        let result = try await task.value

        #expect(result.terminationStatus != 0)
    }

    private func makeImage(width: Int, height: Int, color: NSColor) -> NSImage {
        let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width,
            pixelsHigh: height,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        )!
        bitmap.size = NSSize(width: width, height: height)

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        color.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        NSGraphicsContext.restoreGraphicsState()

        let image = NSImage(size: bitmap.size)
        image.addRepresentation(bitmap)
        return image
    }
}
