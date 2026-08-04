//
//  CompositeImageRenderer.swift
//  DevKit
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers

enum CompositeImageRenderer {
    static func pngData(
        bottomImage: NSImage,
        topImage: NSImage,
        topOpacity: Double
    ) throws -> Data {
        guard let bottomCGImage = bottomImage.cgImage(
            forProposedRect: nil,
            context: nil,
            hints: nil
        ) else {
            throw RenderError.invalidBottomImage
        }

        let width = bottomCGImage.width
        let height = bottomCGImage.height
        guard width > 0, height > 0,
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
              ),
              let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
            throw RenderError.cannotCreateCanvas
        }

        let canvasSize = NSSize(width: width, height: height)
        let canvasRect = NSRect(origin: .zero, size: canvasSize)
        bitmap.size = canvasSize

        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }

        NSGraphicsContext.current = context
        context.imageInterpolation = .high
        bottomImage.draw(
            in: canvasRect,
            from: .zero,
            operation: .copy,
            fraction: 1,
            respectFlipped: true,
            hints: nil
        )

        let topRect = aspectFitRect(for: topImage.size, inside: canvasRect)
        topImage.draw(
            in: topRect,
            from: .zero,
            operation: .sourceOver,
            fraction: min(max(topOpacity, 0), 1),
            respectFlipped: true,
            hints: nil
        )

        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            throw RenderError.cannotEncodePNG
        }
        return data
    }

    private static func aspectFitRect(for imageSize: NSSize, inside bounds: NSRect) -> NSRect {
        guard imageSize.width > 0, imageSize.height > 0 else {
            return .zero
        }

        let scale = min(
            bounds.width / imageSize.width,
            bounds.height / imageSize.height
        )
        let size = NSSize(
            width: imageSize.width * scale,
            height: imageSize.height * scale
        )
        return NSRect(
            x: bounds.midX - size.width / 2,
            y: bounds.midY - size.height / 2,
            width: size.width,
            height: size.height
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
    case invalidBottomImage
    case cannotCreateCanvas
    case cannotEncodePNG

    var errorDescription: String? {
        switch self {
        case .invalidBottomImage:
            "无法读取底图像素。"
        case .cannotCreateCanvas:
            "无法创建图片画布。"
        case .cannotEncodePNG:
            "无法生成 PNG 图片。"
        }
    }
}
