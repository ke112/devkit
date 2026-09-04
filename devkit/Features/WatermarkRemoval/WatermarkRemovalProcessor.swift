import AppKit
import CoreGraphics
import Vision

enum WatermarkRemovalError: LocalizedError {
    case invalidImage
    case invalidSelection
    case cannotCreateBitmap
    case cannotEncodePNG
    case noWatermarkDetected

    var errorDescription: String? {
        switch self {
        case .invalidImage:
            "无法读取图片像素。"
        case .invalidSelection:
            "请选择需要修复的水印区域。"
        case .cannotCreateBitmap:
            "无法创建图片处理画布。"
        case .cannotEncodePNG:
            "无法生成 PNG 图片。"
        case .noWatermarkDetected:
            "未识别到重复文字水印，请改用手动框选。"
        }
    }
}

enum WatermarkRemovalProcessor {
    private struct TextObservation {
        let key: String
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

        var selectedIDs = Set<String>()
        var selectedObservations: [TextObservation] = []
        for group in numericGroups {
            let distinct = distinctObservations(group)
            guard distinct.count >= 3,
                  hasWideSpatialSpread(distinct) else { continue }
            for observation in distinct {
                let id = observation.boundingBox.debugDescription + observation.key
                if selectedIDs.insert(id).inserted { selectedObservations.append(observation) }
            }
        }

        let selections = selectedObservations.map {
            expandedPixelRect(from: $0.boundingBox, width: sourceImage.width, height: sourceImage.height)
        }
        guard !selections.isEmpty else {
            throw WatermarkRemovalError.noWatermarkDetected
        }

        var result = image
        for selection in selections {
            try Task.checkCancellation()
            result = try removeWatermark(from: result, selection: selection)
        }
        return AutomaticResult(image: result, detectedRegionCount: selections.count)
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
                        y: (tileRect.minY + observation.boundingBox.minY * tileRect.height) / CGFloat(height),
                        width: observation.boundingBox.width * tileRect.width / CGFloat(width),
                        height: observation.boundingBox.height * tileRect.height / CGFloat(height)
                    )
                    guard box.height >= 0.012,
                          box.width / max(box.height, 0.001) <= 4 else { continue }
                    observations.append(TextObservation(key: key, numericToken: numericToken(candidate.string), boundingBox: box))
                }
            }
        }
        return observations
    }

    private static func distinctObservations(_ observations: [TextObservation]) -> [TextObservation] {
        var result: [TextObservation] = []
        for observation in observations {
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
        let horizontalPadding = max(8, boxWidth * 0.35)
        let verticalPadding = max(8, boxHeight * 0.55)
        return CGRect(
            x: x - horizontalPadding,
            y: y - verticalPadding,
            width: boxWidth + horizontalPadding * 2,
            height: boxHeight + verticalPadding * 2
        )
    }

    /// Removes a rectangular watermark using pixels sampled from the surrounding area.
    /// The selection uses a top-left origin in source-image pixel coordinates.
    static func removeWatermark(from image: NSImage, selection: CGRect) throws -> NSImage {
        guard let sourceImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw WatermarkRemovalError.invalidImage
        }

        let width = sourceImage.width
        let height = sourceImage.height
        let imageBounds = CGRect(x: 0, y: 0, width: width, height: height)
        let clippedSelection = selection.standardized.intersection(imageBounds)
        guard clippedSelection.width >= 1, clippedSelection.height >= 1 else {
            throw WatermarkRemovalError.invalidSelection
        }

        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw WatermarkRemovalError.cannotCreateBitmap
        }
        context.interpolationQuality = .high
        context.draw(sourceImage, in: imageBounds)
        guard let rawData = context.data else {
            throw WatermarkRemovalError.cannotCreateBitmap
        }

        let source = Array(UnsafeBufferPointer(start: rawData.assumingMemoryBound(to: UInt8.self), count: width * height * 4))
        var output = source
        let x0 = max(0, Int(floor(clippedSelection.minX)))
        let x1 = min(width, Int(ceil(clippedSelection.maxX)))
        let y0 = max(0, Int(floor(clippedSelection.minY)))
        let y1 = min(height, Int(ceil(clippedSelection.maxY)))

        for topY in y0..<y1 {
            try Task.checkCancellation()
            for x in x0..<x1 {
                let distanceFromLeft = x - x0
                let distanceFromRight = x1 - 1 - x
                let distanceFromTop = topY - y0
                let distanceFromBottom = y1 - 1 - topY
                var horizontalSamples: [(x: Int, y: Int)] = []
                var verticalSamples: [(x: Int, y: Int)] = []

                func appendSample(
                    x sampleX: Int,
                    y sampleY: Int,
                    into samples: inout [(x: Int, y: Int)]
                ) {
                    guard sampleX >= 0, sampleX < width, sampleY >= 0, sampleY < height,
                          !(sampleX >= x0 && sampleX < x1 && sampleY >= y0 && sampleY < y1) else { return }
                    samples.append((sampleX, sampleY))
                }

                appendSample(x: x0 - 1 - distanceFromLeft, y: topY, into: &horizontalSamples)
                appendSample(x: x1 + distanceFromRight, y: topY, into: &horizontalSamples)
                appendSample(x: x, y: y0 - 1 - distanceFromTop, into: &verticalSamples)
                appendSample(x: x, y: y1 + distanceFromBottom, into: &verticalSamples)
                let samples = preferredSamples(
                    horizontal: horizontalSamples,
                    vertical: verticalSamples,
                    source: source,
                    width: width,
                    height: height
                )
                guard !samples.isEmpty else { continue }

                var channels = [CGFloat](repeating: 0, count: 4)
                for sample in samples {
                    let sourceIndex = ((height - 1 - sample.y) * width + sample.x) * 4
                    for channel in 0..<4 { channels[channel] += CGFloat(source[sourceIndex + channel]) }
                }

                let outputIndex = ((height - 1 - topY) * width + x) * 4
                for channel in 0..<4 {
                    output[outputIndex + channel] = UInt8((channels[channel] / CGFloat(samples.count)).rounded().clamped(to: 0...255))
                }
            }
        }

        output.withUnsafeBytes { bytes in
            context.data?.copyMemory(from: bytes.baseAddress!, byteCount: output.count)
        }
        guard let result = context.makeImage() else {
            throw WatermarkRemovalError.cannotCreateBitmap
        }
        return NSImage(cgImage: result, size: image.size)
    }

    private static func preferredSamples(
        horizontal: [(x: Int, y: Int)],
        vertical: [(x: Int, y: Int)],
        source: [UInt8],
        width: Int,
        height: Int
    ) -> [(x: Int, y: Int)] {
        guard !horizontal.isEmpty else { return vertical }
        guard !vertical.isEmpty else { return horizontal }
        guard horizontal.count > 1, vertical.count > 1 else {
            return horizontal.count >= vertical.count ? horizontal : vertical
        }

        func colorDistance(_ lhs: (x: Int, y: Int), _ rhs: (x: Int, y: Int)) -> Int {
            let leftIndex = ((height - 1 - lhs.y) * width + lhs.x) * 4
            let rightIndex = ((height - 1 - rhs.y) * width + rhs.x) * 4
            return (0..<3).reduce(0) { partialResult, channel in
                partialResult + abs(Int(source[leftIndex + channel]) - Int(source[rightIndex + channel]))
            }
        }

        return colorDistance(horizontal[0], horizontal[1]) <= colorDistance(vertical[0], vertical[1])
            ? horizontal
            : vertical
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

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}

private extension CGRect {
    var area: CGFloat { max(0, width) * max(0, height) }
}
