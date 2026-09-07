import AppKit
import CoreImage
import Vision

nonisolated enum IDPhotoBackground: String, CaseIterable, Sendable {
    case red, blue, white, gray, transparent

    var title: String {
        switch self {
        case .red: "红色"
        case .blue: "蓝色"
        case .white: "白色"
        case .gray: "灰色"
        case .transparent: "透明"
        }
    }

    var components: (red: CGFloat, green: CGFloat, blue: CGFloat) {
        switch self {
        case .red: (1, 0, 0)
        case .blue: (0, 0.4, 1)
        case .white: (1, 1, 1)
        case .gray: (217.0 / 255, 217.0 / 255, 217.0 / 255)
        case .transparent: (0, 0, 0)
        }
    }
}

nonisolated enum IDPhotoError: LocalizedError {
    case invalidImage, noPerson, cannotRender, imageTooLarge

    var errorDescription: String? {
        switch self {
        case .invalidImage: "无法读取这张照片，请选择有效的图片。"
        case .noPerson: "未识别到人物，请选择人物清晰可见的照片。"
        case .cannotRender: "无法生成证件照，请重试。"
        case .imageTooLarge: "图片过大，请选择不超过 3200 万像素的照片。"
        }
    }
}

nonisolated enum IDPhotoProcessor {
    static func makePhotos(from data: Data) throws -> [IDPhotoBackground: Data] {
        try Task.checkCancellation()
        guard let input = CIImage(data: data, options: [.applyOrientationProperty: true]),
            input.extent.width > 0, input.extent.height > 0
        else { throw IDPhotoError.invalidImage }
        guard input.extent.width * input.extent.height <= 32_000_000 else {
            throw IDPhotoError.imageTooLarge
        }
        let source = input.transformed(
            by: CGAffineTransform(translationX: -input.extent.minX, y: -input.extent.minY))
        let context = CIContext()
        guard let image = context.createCGImage(source, from: source.extent) else {
            throw IDPhotoError.invalidImage
        }
        let request = VNGeneratePersonSegmentationRequest()
        request.qualityLevel = .accurate
        request.outputPixelFormat = kCVPixelFormatType_OneComponent8
        try VNImageRequestHandler(cgImage: image, orientation: .up).perform([request])
        try Task.checkCancellation()
        guard let buffer = request.results?.first?.pixelBuffer, containsPerson(buffer) else {
            throw IDPhotoError.noPerson
        }
        let mask = CIImage(cvPixelBuffer: buffer)
        var photos: [IDPhotoBackground: Data] = [:]
        for background in IDPhotoBackground.allCases {
            try Task.checkCancellation()
            let output = composite(source: source, mask: mask, background: background)
            guard
                let png = context.pngRepresentation(
                    of: output, format: .RGBA8,
                    colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
            else { throw IDPhotoError.cannotRender }
            photos[background] = png
        }
        return photos
    }

    static func composite(source: CIImage, mask: CIImage, background: IDPhotoBackground) -> CIImage {
        let scaledMask = mask.transformed(
            by: CGAffineTransform(
                scaleX: source.extent.width / mask.extent.width,
                y: source.extent.height / mask.extent.height
            )
        ).cropped(to: source.extent)
        let c = background.components
        let solid = CIImage(
            color: CIColor(
                red: c.red, green: c.green, blue: c.blue,
                alpha: background == .transparent ? 0 : 1)
        ).cropped(
            to: source.extent)
        return source.applyingFilter(
            "CIBlendWithMask",
            parameters: [
                kCIInputBackgroundImageKey: solid,
                kCIInputMaskImageKey: scaledMask,
            ]
        ).cropped(to: source.extent)
    }

    private static func containsPerson(_ buffer: CVPixelBuffer) -> Bool {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let address = CVPixelBufferGetBaseAddress(buffer) else { return false }
        let pixels = address.assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        for y in 0..<CVPixelBufferGetHeight(buffer) {
            for x in 0..<CVPixelBufferGetWidth(buffer) where pixels[y * stride + x] >= 128 { return true }
        }
        return false
    }
}
