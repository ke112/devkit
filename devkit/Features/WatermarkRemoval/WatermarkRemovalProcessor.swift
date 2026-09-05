import AppKit
import CoreGraphics
import Vision

enum WatermarkRemovalError: LocalizedError {
    case invalidImage
    case cannotCreateBitmap
    case cannotEncodePNG
    case noWatermarkDetected
    case unsupportedBackground

    var errorDescription: String? {
        switch self {
        case .invalidImage:
            "无法读取图片像素。"
        case .cannotCreateBitmap:
            "无法创建图片处理画布。"
        case .cannotEncodePNG:
            "无法生成 PNG 图片。"
        case .noWatermarkDetected:
            "未识别到可自动修复的重复数字水印。原图未修改。"
        case .unsupportedBackground:
            "水印区域的背景或笔画无法可靠分离，未生成修复结果。原图未修改。"
        }
    }
}

enum WatermarkRemovalProcessor {
    private struct TextObservation {
        let numericToken: String?
        let boundingBox: CGRect
    }

    struct AutomaticResult {
        let image: NSImage
        let detectedRegionCount: Int
    }

    /// Detects repeated text with Vision and repairs every matching occurrence.
    static func removeDetectedWatermarks(from image: NSImage) throws -> AutomaticResult {
        guard let sourceImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw WatermarkRemovalError.invalidImage
        }

        let observations = try recognizeText(in: sourceImage)
        var numericGroups: [[TextObservation]] = []
        for observation in observations {
            guard let numericToken = observation.numericToken else { continue }
            if let groupIndex = numericGroups.firstIndex(where: { group in
                group.contains { $0.numericToken.map { numericTokensMatch($0, numericToken) } == true }
            }) {
                numericGroups[groupIndex].append(observation)
            } else {
                numericGroups.append([observation])
            }
        }

        var regionGroups: [[CGRect]] = []
        for group in numericGroups {
            if let token = group.first?.numericToken,
               numericGroups.contains(where: { other in
                   guard let longer = other.first?.numericToken, longer.count == token.count + 1 else { return false }
                   return numericTokensMatch(String(longer.prefix(token.count)), token)
                       && distinctObservations(other).count >= 3
               }) { continue }
            let distinct = distinctObservations(group)
            guard distinct.count >= 3,
                  hasWideSpatialSpread(distinct) else { continue }
            regionGroups.append(distinct.map {
                expandedPixelRect(from: $0.boundingBox, width: sourceImage.width, height: sourceImage.height)
            })
        }

        guard !regionGroups.isEmpty else {
            throw WatermarkRemovalError.noWatermarkDetected
        }

        return try repairRepeatedWatermarks(from: image, regionGroups: regionGroups)
    }

    static func normalizedText(_ text: String) -> String {
        text.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    static func numericToken(_ text: String) -> String? {
        let normalized = normalizedText(text)
        let token = normalized.filter(\.isNumber)
        guard normalized.count <= 12,
              token.count >= 3,
              token.count * 2 >= normalized.count else { return nil }
        return token
    }

    static func numericTokensMatch(_ lhs: String, _ rhs: String) -> Bool {
        guard lhs.count == rhs.count, lhs.count >= 3 else { return false }
        return zip(lhs, rhs).filter { $0 != $1 }.count <= 1
    }

    private static func recognizeText(in image: CGImage) throws -> [TextObservation] {
        var observations: [TextObservation] = []
        let width = image.width
        let height = image.height
        let tileCount = 8
        let overlapX = width / 16
        let overlapY = height / 16

        for row in 0..<tileCount {
            try Task.checkCancellation()
            for column in 0..<tileCount {
                let tileRect = CGRect(
                    x: max(0, column * width / tileCount - overlapX),
                    y: max(0, row * height / tileCount - overlapY),
                    width: min(width, (column + 1) * width / tileCount + overlapX) - max(0, column * width / tileCount - overlapX),
                    height: min(height, (row + 1) * height / tileCount + overlapY) - max(0, row * height / tileCount - overlapY)
                )
                guard let tile = image.cropping(to: tileRect),
                      let upscaled = upscale(tile, factor: 4) else { continue }
                let request = VNRecognizeTextRequest()
                request.recognitionLevel = .accurate
                request.usesLanguageCorrection = false
                request.minimumTextHeight = 0.004
                request.recognitionLanguages = ["zh-Hans", "zh-Hant", "en-US"]
                try VNImageRequestHandler(cgImage: upscaled, orientation: .up).perform([request])
                for observation in request.results ?? [] {
                    guard let candidate = observation.topCandidates(1).first,
                          candidate.confidence >= 0.2 else { continue }
                    let key = normalizedText(candidate.string)
                    guard key.count >= 2 else { continue }
                    let box = CGRect(
                        x: (tileRect.minX + observation.boundingBox.minX * tileRect.width) / CGFloat(width),
                        y: (CGFloat(height) - tileRect.maxY + observation.boundingBox.minY * tileRect.height) / CGFloat(height),
                        width: observation.boundingBox.width * tileRect.width / CGFloat(width),
                        height: observation.boundingBox.height * tileRect.height / CGFloat(height)
                    )
                    guard box.height * CGFloat(height) >= 4,
                          box.width * CGFloat(width) / max(box.height * CGFloat(height), 1) <= 12 else { continue }
                    observations.append(TextObservation(numericToken: numericToken(candidate.string), boundingBox: box))
                }
            }
        }
        return observations
    }

    private static func distinctObservations(_ observations: [TextObservation]) -> [TextObservation] {
        var result: [TextObservation] = []
        for observation in observations.sorted(by: { $0.boundingBox.area > $1.boundingBox.area }) {
            guard !result.contains(where: { intersectionOverUnion($0.boundingBox, observation.boundingBox) > 0.5 }) else {
                continue
            }
            result.append(observation)
        }
        return result
    }

    private static func intersectionOverUnion(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        let intersection = lhs.intersection(rhs)
        guard !intersection.isNull, intersection.width > 0, intersection.height > 0 else { return 0 }
        let union = lhs.area + rhs.area - intersection.area
        return union > 0 ? intersection.area / union : 0
    }

    private static func hasWideSpatialSpread(_ observations: [TextObservation]) -> Bool {
        guard let first = observations.first else { return false }
        let centers = observations.map { CGPoint(x: $0.boundingBox.midX, y: $0.boundingBox.midY) }
        return centers.contains {
            abs($0.x - first.boundingBox.midX) > 0.08 || abs($0.y - first.boundingBox.midY) > 0.08
        }
    }

    private static func upscale(_ image: CGImage, factor: CGFloat) -> CGImage? {
        let width = max(1, Int(CGFloat(image.width) * factor))
        let height = max(1, Int(CGFloat(image.height) * factor))
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    private static func expandedPixelRect(from normalizedBox: CGRect, width: Int, height: Int) -> CGRect {
        let x = normalizedBox.minX * CGFloat(width)
        let y = (1 - normalizedBox.maxY) * CGFloat(height)
        let boxWidth = normalizedBox.width * CGFloat(width)
        let boxHeight = normalizedBox.height * CGFloat(height)
        let horizontalPadding: CGFloat = 2
        let verticalPadding: CGFloat = 2
        return CGRect(
            x: x - horizontalPadding,
            y: y - verticalPadding,
            width: boxWidth + horizontalPadding * 2,
            height: boxHeight + verticalPadding * 2
        )
    }

    static func repairRepeatedWatermarks(from image: NSImage, regionGroups: [[CGRect]]) throws -> AutomaticResult {
        guard !regionGroups.isEmpty else { throw WatermarkRemovalError.noWatermarkDetected }
        return try RepeatedWatermarkRepair.repair(image: image, regionGroups: regionGroups)
    }

    static func pngData(for image: NSImage) throws -> Data {
        guard let bitmap = image.representations.compactMap({ $0 as? NSBitmapImageRep }).first
                ?? image.cgImage(forProposedRect: nil, context: nil, hints: nil).map({ NSBitmapImageRep(cgImage: $0) }) else {
            throw WatermarkRemovalError.invalidImage
        }
        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            throw WatermarkRemovalError.cannotEncodePNG
        }
        return data
    }
}

private extension CGRect {
    var area: CGFloat { max(0, width) * max(0, height) }
}
