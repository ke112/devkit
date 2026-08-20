import AppKit
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
                == [.imageOverlay, .simulatorManagement, .appStoreRelease]
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
