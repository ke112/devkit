import AppKit
import CoreImage
import Testing

@testable import devkit

struct IDPhotoTests {
    @Test(arguments: IDPhotoBackground.allCases)
    func compositePreservesPersonAndReplacesBackground(background: IDPhotoBackground) throws {
        let extent = CGRect(x: 0, y: 0, width: 60, height: 80)
        let source = CIImage(color: CIColor(red: 0, green: 1, blue: 0)).cropped(to: extent)
        let mask = CIImage(color: .white).cropped(to: CGRect(x: 0, y: 0, width: 15, height: 40))
            .composited(
                over: CIImage(color: .black).cropped(to: CGRect(x: 0, y: 0, width: 30, height: 40)))
        let result = IDPhotoProcessor.composite(source: source, mask: mask, background: background)
        var pixels = [UInt8](repeating: 0, count: 60 * 80 * 4)
        CIContext().render(
            result, toBitmap: &pixels, rowBytes: 60 * 4, bounds: extent, format: .RGBA8,
            colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        let person = pixel(in: pixels, width: 60, x: 5, y: 20)
        let outside = pixel(in: pixels, width: 60, x: 55, y: 20)
        #expect(person.red == 0 && person.green == 255 && person.blue == 0 && person.alpha == 255)
        let expected = background.components
        #expect(abs(Int(outside.red) - Int((expected.red * 255).rounded())) <= 1)
        #expect(abs(Int(outside.green) - Int((expected.green * 255).rounded())) <= 1)
        #expect(abs(Int(outside.blue) - Int((expected.blue * 255).rounded())) <= 1)
        #expect(outside.alpha == (background == .transparent ? 0 : 255))
    }

    @Test func transparentPNGPreservesSoftMaskAlpha() throws {
        let extent = CGRect(x: 0, y: 0, width: 8, height: 8)
        let source = CIImage(color: CIColor(red: 0, green: 1, blue: 0)).cropped(to: extent)
        let mask = CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5)).cropped(to: extent)
        let output = IDPhotoProcessor.composite(source: source, mask: mask, background: .transparent)
        let data = try #require(
            CIContext().pngRepresentation(
                of: output, format: .RGBA8,
                colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!))
        let decoded = try #require(CIImage(data: data))
        var pixels = [UInt8](repeating: 0, count: 8 * 8 * 4)
        CIContext().render(
            decoded, toBitmap: &pixels, rowBytes: 8 * 4, bounds: extent, format: .RGBA8,
            colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        let edge = pixel(in: pixels, width: 8, x: 4, y: 4)
        #expect(edge.alpha > 0 && edge.alpha < 255)
        #expect(edge.red == 0 && edge.blue == 0 && edge.green > 0)
    }

    @Test func transparentPreviewGridUsesTheFittedImageFrame() {
        #expect(
            IDPhotoPreviewLayout.fittedSize(
                imageSize: CGSize(width: 2_316, height: 3_088),
                containerSize: CGSize(width: 600, height: 600))
                == CGSize(width: 450, height: 600))
    }

    @Test func backgroundOptionsRemainIndependent() {
        #expect(IDPhotoBackground.allCases == [.red, .blue, .white, .gray, .transparent])
        #expect(IDPhotoBackground.transparent.components.red == 0)
        #expect(IDPhotoBackground.gray.components.red == 217.0 / 255)
    }

    @Test func invalidInputIsRejected() {
        #expect(throws: IDPhotoError.invalidImage) {
            try IDPhotoProcessor.makePhotos(from: Data([0, 1, 2]))
        }
    }

    @Test func blankImageIsRejected() throws {
        let source = CIImage(color: .white).cropped(to: CGRect(x: 0, y: 0, width: 240, height: 320))
        let data = try #require(
            CIContext().pngRepresentation(
                of: source, format: .RGBA8,
                colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!))
        #expect(throws: IDPhotoError.noPerson) { try IDPhotoProcessor.makePhotos(from: data) }
    }

    private func pixel(
        in pixels: [UInt8], width: Int, x: Int, y: Int
    ) -> (red: UInt8, green: UInt8, blue: UInt8, alpha: UInt8) {
        let index = (y * width + x) * 4
        return (pixels[index], pixels[index + 1], pixels[index + 2], pixels[index + 3])
    }
}
