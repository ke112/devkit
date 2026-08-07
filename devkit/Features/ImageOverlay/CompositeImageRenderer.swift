//
//  CompositeImageRenderer.swift
//  DevKit
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ImagePixelSize: Equatable {
    let width: Int
    let height: Int

    var cgSize: CGSize {
        CGSize(width: width, height: height)
    }
}

enum ImageBackingScale: Double, CaseIterable, Identifiable {
    case one = 1
    case oneAndHalf = 1.5
    case two = 2
    case three = 3
    case four = 4

    var id: Double { rawValue }
    var value: CGFloat { CGFloat(rawValue) }

    var label: String {
        rawValue.formatted(.number.precision(.fractionLength(rawValue == 1.5 ? 1 : 0))) + "x"
    }
}

struct TopImageTransform: Equatable {
    var scale: CGFloat = 1
    var offset: CGSize = .zero
}

struct CompositeImageLayout: Equatable {
    let logicalBounds: CGRect
    let bottomRect: CGRect
    let topRect: CGRect
    let outputScale: CGFloat

    var pixelSize: ImagePixelSize {
        ImagePixelSize(
            width: Int((logicalBounds.width * outputScale).rounded()),
            height: Int((logicalBounds.height * outputScale).rounded())
        )
    }

    var outputCenterFromBottomCenter: CGSize {
        CGSize(
            width: logicalBounds.midX - bottomRect.width / 2,
            height: logicalBounds.midY - bottomRect.height / 2
        )
    }

    var topCenterFromBottomCenter: CGSize {
        CGSize(
            width: topRect.midX - bottomRect.midX,
            height: topRect.midY - bottomRect.midY
        )
    }
}

enum CompositeImageOutputLimits {
    static let maximumDimension = 16_384
    static let maximumPixelCount = 64_000_000

    static func validationMessage(for size: ImagePixelSize) -> String? {
        if size.width > maximumDimension || size.height > maximumDimension {
            return "单边不能超过 \(maximumDimension) px"
        }

        let pixelCount = size.width.multipliedReportingOverflow(by: size.height)
        if pixelCount.overflow || pixelCount.partialValue > maximumPixelCount {
            return "总像素不能超过 64 MP"
        }
        return nil
    }
}

enum CompositeImageRenderer {
    static func pixelSize(for image: NSImage) throws -> ImagePixelSize {
        guard let cgImage = image.cgImage(
            forProposedRect: nil,
            context: nil,
            hints: nil
        ) else {
            throw RenderError.invalidImage
        }
        return ImagePixelSize(width: cgImage.width, height: cgImage.height)
    }

    static func suggestedBackingScale(
        for image: NSImage,
        named name: String
    ) -> ImageBackingScale {
        guard let pixelSize = try? pixelSize(for: image) else { return .one }
        if let explicitScale = explicitBackingScale(named: name) {
            return explicitScale
        }

        let horizontalScale = CGFloat(pixelSize.width) / max(1, image.size.width)
        let verticalScale = CGFloat(pixelSize.height) / max(1, image.size.height)
        if abs(horizontalScale - verticalScale) < 0.01,
           let representedScale = nearestBackingScale(to: horizontalScale),
           abs(representedScale.value - horizontalScale) < 0.01,
           representedScale != .one {
            return representedScale
        }

        return suggestedBackingScale(for: pixelSize, named: name)
    }

    static func suggestedBackingScale(
        for pixelSize: ImagePixelSize,
        named name: String
    ) -> ImageBackingScale {
        if let explicitScale = explicitBackingScale(named: name) {
            return explicitScale
        }

        let lowercaseName = name.lowercased()
        let shortEdge = min(pixelSize.width, pixelSize.height)
        let longEdge = max(pixelSize.width, pixelSize.height)
        if lowercaseName.contains("simulator screenshot") {
            if lowercaseName.contains("iphone") {
                return shortEdge >= 1_000 ? .three : .two
            }
            if lowercaseName.contains("ipad") {
                return .two
            }
        }

        guard shortEdge > 600,
              CGFloat(longEdge) / CGFloat(shortEdge) >= 1.6
        else {
            return .one
        }

        let phoneScales = ImageBackingScale.allCases.filter { scale in
            let logicalShortEdge = CGFloat(shortEdge) / scale.value
            return logicalShortEdge >= 320 && logicalShortEdge <= 480
        }
        return phoneScales.min { lhs, rhs in
            abs(CGFloat(shortEdge) / lhs.value - 390)
                < abs(CGFloat(shortEdge) / rhs.value - 390)
        } ?? .one
    }

    private static func explicitBackingScale(named name: String) -> ImageBackingScale? {
        let lowercaseName = name.lowercased()
        let namedScales: [(markers: [String], scale: ImageBackingScale)] = [
            (["@4x", "xxxhdpi"], .four),
            (["@3x", "xxhdpi"], .three),
            (["@2x", "xhdpi"], .two),
            (["hdpi"], .oneAndHalf),
            (["mdpi"], .one)
        ]
        return namedScales.first { entry in
            entry.markers.contains(where: lowercaseName.contains)
        }?.scale
    }

    static func layout(
        bottomSize: ImagePixelSize,
        bottomBackingScale: CGFloat = 1,
        topSize: ImagePixelSize,
        topBackingScale: CGFloat = 1,
        transform: TopImageTransform
    ) -> CompositeImageLayout {
        let bottomBackingScale = max(0.01, bottomBackingScale)
        let topBackingScale = max(0.01, topBackingScale)
        let outputScale = max(bottomBackingScale, topBackingScale)
        let bottomRect = CGRect(
            origin: .zero,
            size: CGSize(
                width: CGFloat(bottomSize.width) / bottomBackingScale,
                height: CGFloat(bottomSize.height) / bottomBackingScale
            )
        )
        let topSize = CGSize(
            width: max(1 / outputScale, CGFloat(topSize.width) / topBackingScale * transform.scale),
            height: max(1 / outputScale, CGFloat(topSize.height) / topBackingScale * transform.scale)
        )
        let topRect = CGRect(
            x: quantized(
                bottomRect.midX - topSize.width / 2 + transform.offset.width,
                scale: outputScale
            ),
            y: quantized(
                bottomRect.midY - topSize.height / 2 + transform.offset.height,
                scale: outputScale
            ),
            width: topSize.width,
            height: topSize.height
        )
        let minimumX = floor(min(bottomRect.minX, topRect.minX) * outputScale) / outputScale
        let minimumY = floor(min(bottomRect.minY, topRect.minY) * outputScale) / outputScale
        let maximumX = ceil(max(bottomRect.maxX, topRect.maxX) * outputScale) / outputScale
        let maximumY = ceil(max(bottomRect.maxY, topRect.maxY) * outputScale) / outputScale

        return CompositeImageLayout(
            logicalBounds: CGRect(
                x: minimumX,
                y: minimumY,
                width: maximumX - minimumX,
                height: maximumY - minimumY
            ),
            bottomRect: bottomRect,
            topRect: topRect,
            outputScale: outputScale
        )
    }

    static func pngData(
        bottomImage: NSImage,
        topImage: NSImage,
        topOpacity: Double,
        bottomBackingScale: CGFloat = 1,
        topBackingScale: CGFloat = 1,
        transform: TopImageTransform = TopImageTransform()
    ) throws -> Data {
        guard let bottomCGImage = bottomImage.cgImage(
            forProposedRect: nil,
            context: nil,
            hints: nil
        ) else {
            throw RenderError.invalidBottomImage
        }
        guard let topCGImage = topImage.cgImage(
            forProposedRect: nil,
            context: nil,
            hints: nil
        ) else {
            throw RenderError.invalidTopImage
        }

        let layout = layout(
            bottomSize: ImagePixelSize(
                width: bottomCGImage.width,
                height: bottomCGImage.height
            ),
            bottomBackingScale: bottomBackingScale,
            topSize: ImagePixelSize(
                width: topCGImage.width,
                height: topCGImage.height
            ),
            topBackingScale: topBackingScale,
            transform: transform
        )
        let outputSize = layout.pixelSize
        if let message = CompositeImageOutputLimits.validationMessage(for: outputSize) {
            throw RenderError.outputTooLarge(message)
        }

        guard outputSize.width > 0, outputSize.height > 0,
              let bitmap = NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: outputSize.width,
                pixelsHigh: outputSize.height,
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 0,
                bitsPerPixel: 0
              ),
              let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
            throw RenderError.cannotCreateCanvas
        }

        let outputHeight = CGFloat(outputSize.height)
        bitmap.size = outputSize.cgSize

        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }

        NSGraphicsContext.current = context
        context.cgContext.clear(
            CGRect(origin: .zero, size: outputSize.cgSize)
        )
        context.imageInterpolation = .high

        draw(
            bottomCGImage,
            in: pixelRect(
                normalizedRect(layout.bottomRect, within: layout.logicalBounds),
                scale: layout.outputScale
            ),
            outputHeight: outputHeight,
            operation: .copy,
            opacity: 1
        )
        draw(
            topCGImage,
            in: pixelRect(
                normalizedRect(layout.topRect, within: layout.logicalBounds),
                scale: layout.outputScale
            ),
            outputHeight: outputHeight,
            operation: .sourceOver,
            opacity: min(max(topOpacity, 0), 1)
        )

        bitmap.size = layout.logicalBounds.size
        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            throw RenderError.cannotEncodePNG
        }
        return data
    }

    private static func nearestBackingScale(to value: CGFloat) -> ImageBackingScale? {
        ImageBackingScale.allCases.min {
            abs($0.value - value) < abs($1.value - value)
        }
    }

    private static func quantized(_ value: CGFloat, scale: CGFloat) -> CGFloat {
        (value * scale).rounded() / scale
    }

    private static func pixelRect(_ rect: CGRect, scale: CGFloat) -> CGRect {
        CGRect(
            x: rect.minX * scale,
            y: rect.minY * scale,
            width: rect.width * scale,
            height: rect.height * scale
        )
    }

    private static func normalizedRect(_ rect: CGRect, within bounds: CGRect) -> CGRect {
        CGRect(
            x: rect.minX - bounds.minX,
            y: rect.minY - bounds.minY,
            width: rect.width,
            height: rect.height
        )
    }

    private static func draw(
        _ cgImage: CGImage,
        in topLeftRect: CGRect,
        outputHeight: CGFloat,
        operation: NSCompositingOperation,
        opacity: CGFloat
    ) {
        let image = NSImage(
            cgImage: cgImage,
            size: NSSize(width: cgImage.width, height: cgImage.height)
        )
        image.draw(
            in: NSRect(
                x: topLeftRect.minX,
                y: outputHeight - topLeftRect.maxY,
                width: topLeftRect.width,
                height: topLeftRect.height
            ),
            from: .zero,
            operation: operation,
            fraction: opacity,
            respectFlipped: true,
            hints: nil
        )
    }
}

struct PNGFileDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.png] }

    let data: Data

    init(data: Data) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        self.data = data
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

private enum RenderError: LocalizedError {
    case invalidImage
    case invalidBottomImage
    case invalidTopImage
    case cannotCreateCanvas
    case cannotEncodePNG
    case outputTooLarge(String)

    var errorDescription: String? {
        switch self {
        case .invalidImage:
            "无法读取图片像素。"
        case .invalidBottomImage:
            "无法读取底图像素。"
        case .invalidTopImage:
            "无法读取上层图片像素。"
        case .cannotCreateCanvas:
            "无法创建图片画布。"
        case .cannotEncodePNG:
            "无法生成 PNG 图片。"
        case .outputTooLarge(let message):
            "导出尺寸过大：\(message)。"
        }
    }
}
