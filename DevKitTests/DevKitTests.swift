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
