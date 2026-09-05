import AppKit

enum RepeatedWatermarkRepair {
    private struct Template {
        let width: Int
        let height: Int
        let opacity: [Double]
        let features: [(x: Int, y: Int, contrast: Int)]
        let peak: Double
        let backgroundCoverage: Double
    }

    private struct Match {
        let x: Int
        let y: Int
        let score: Double
    }

    static func repair(image: NSImage, regionGroups: [[CGRect]]) throws -> WatermarkRemovalProcessor.AutomaticResult {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw WatermarkRemovalError.invalidImage
        }
        let width = cgImage.width
        let height = cgImage.height
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        let colorSpace = cgImage.colorSpace.flatMap { $0.model == .rgb ? $0 : nil }
            ?? CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ), let data = context.data else { throw WatermarkRemovalError.cannotCreateBitmap }
        context.draw(cgImage, in: bounds)
        let source = Array(UnsafeBufferPointer(start: data.assumingMemoryBound(to: UInt8.self), count: width * height * 4))
        var luminance = [Int](repeating: 0, count: width * height)
        for index in luminance.indices {
            luminance[index] = (Int(source[index * 4]) + Int(source[index * 4 + 1]) + Int(source[index * 4 + 2])) / 3
        }
        let contrast = try localContrast(luminance, width: width, height: height)
        var output = source
        var repairedCount = 0
        for group in regionGroups where group.count >= 3 {
            try Task.checkCancellation()
            let templates = group.compactMap {
                makeTemplate(rect: $0.insetBy(dx: -12, dy: -8).integral.intersection(bounds),
                             source: source, luminance: luminance, contrast: contrast, width: width)
            }.sorted { $0.backgroundCoverage > $1.backgroundCoverage }
            guard let template = templates.first else { continue }
            let matches = try findMatches(template: template, source: source, contrast: contrast, width: width, height: height)
            guard matches.count >= 3 else { continue }
            for match in matches {
                try Task.checkCancellation()
                apply(template: template, match: match, source: source, output: &output, width: width, height: height)
            }
            repairedCount += matches.count
        }
        guard repairedCount > 0 else { throw WatermarkRemovalError.unsupportedBackground }
        try Task.checkCancellation()
        output.withUnsafeBytes { bytes in
            if let baseAddress = bytes.baseAddress { data.copyMemory(from: baseAddress, byteCount: output.count) }
        }
        guard let result = context.makeImage() else { throw WatermarkRemovalError.cannotCreateBitmap }
        return .init(image: NSImage(cgImage: result, size: image.size), detectedRegionCount: repairedCount)
    }

    private static func localContrast(_ values: [Int], width: Int, height: Int) throws -> [Int] {
        var horizontal = values
        for y in 0..<height {
            try Task.checkCancellation()
            for x in 0..<width {
                for dx in max(0, x - 2)...min(width - 1, x + 2) {
                    horizontal[y * width + x] = max(horizontal[y * width + x], values[y * width + dx])
                }
            }
        }
        var result = [Int](repeating: 0, count: values.count)
        for y in 0..<height {
            try Task.checkCancellation()
            for x in 0..<width {
                var maximum = values[y * width + x]
                for dy in max(0, y - 2)...min(height - 1, y + 2) {
                    maximum = max(maximum, horizontal[dy * width + x])
                }
                result[y * width + x] = maximum - values[y * width + x]
            }
        }
        return result
    }

    private static func makeTemplate(rect: CGRect, source: [UInt8], luminance: [Int], contrast: [Int], width: Int) -> Template? {
        guard !rect.isNull, rect.width >= 1, rect.height >= 1 else { return nil }
        var histogram = [Int](repeating: 0, count: 256)
        var darkPixels = 0
        for y in Int(rect.minY)..<Int(rect.maxY) {
            for x in Int(rect.minX)..<Int(rect.maxX) {
                let index = y * width + x
                let channels = (0..<3).map { Int(source[index * 4 + $0]) }
                guard channels.max()! - channels.min()! <= 8, source[index * 4 + 3] == 255 else { continue }
                histogram[luminance[index]] += 1
                if luminance[index] < 150 { darkPixels += 1 }
            }
        }
        guard let background = (180...255).filter({ histogram[$0] > 0 }).max(by: {
                  histogram[$0] + histogram[$0 - 1] < histogram[$1] + histogram[$1 - 1]
              }),
              Double(histogram[background] + histogram[background - 1]) / (rect.width * rect.height) >= 0.65,
              Double(darkPixels) / (rect.width * rect.height) < 0.01 else { return nil }
        var strokeBounds = CGRect.null
        var opacity = [Double](repeating: 0, count: Int(rect.width * rect.height))
        var peak = 0.0
        for y in 0..<Int(rect.height) {
            for x in 0..<Int(rect.width) {
                let index = (Int(rect.minY) + y) * width + Int(rect.minX) + x
                let channels = (0..<3).map { Int(source[index * 4 + $0]) }
                let difference = background - luminance[index]
                guard channels.max()! - channels.min()! <= 8,
                      difference > 0, difference <= 96, source[index * 4 + 3] == 255 else { continue }
                let alpha = Double(difference) / Double(background)
                opacity[y * Int(rect.width) + x] = alpha
                peak = max(peak, alpha)
                if difference >= 2 {
                    strokeBounds = strokeBounds.union(CGRect(x: x, y: y, width: 1, height: 1))
                }
            }
        }
        guard !strokeBounds.isNull, peak >= 2.0 / 255 else { return nil }
        strokeBounds = strokeBounds.insetBy(dx: -2, dy: -2).intersection(CGRect(origin: .zero, size: rect.size))
        let templateWidth = Int(strokeBounds.width)
        let templateHeight = Int(strokeBounds.height)
        var cropped = [Double](repeating: 0, count: templateWidth * templateHeight)
        var features: [(x: Int, y: Int, contrast: Int)] = []
        for y in 0..<templateHeight {
            for x in 0..<templateWidth {
                let localX = Int(strokeBounds.minX) + x
                let localY = Int(strokeBounds.minY) + y
                var alpha = opacity[localY * Int(rect.width) + localX]
                if alpha < 2.0 / Double(background) {
                    let hasStrokeNeighbor = (-1...1).contains { dy in
                        (-1...1).contains { dx in
                            let nx = localX + dx
                            let ny = localY + dy
                            return nx >= 0 && nx < Int(rect.width) && ny >= 0 && ny < Int(rect.height)
                                && opacity[ny * Int(rect.width) + nx] >= 2.0 / Double(background)
                        }
                    }
                    if !hasStrokeNeighbor { alpha = 0 }
                }
                cropped[y * templateWidth + x] = alpha
                let edge = contrast[(Int(rect.minY) + localY) * width + Int(rect.minX) + localX]
                if alpha >= peak * 0.4, edge >= 2 {
                    features.append((x, y, edge))
                }
            }
        }
        guard features.count >= 8 else { return nil }
        let sampled = stride(from: 0, to: features.count, by: max(1, features.count / 64)).map { features[$0] }
        return Template(width: templateWidth, height: templateHeight, opacity: cropped, features: sampled, peak: peak,
                        backgroundCoverage: Double(histogram[background] + histogram[background - 1]) / (rect.width * rect.height))
    }

    private static func findMatches(template: Template, source: [UInt8], contrast: [Int], width: Int, height: Int) throws -> [Match] {
        guard template.width <= width, template.height <= height else { return [] }
        func score(x: Int, y: Int, minimumMatchRatio: Double = 0.65) -> Double {
            var matched = 0
            var difference = 0.0
            for (number, feature) in template.features.enumerated() {
                let index = (y + feature.y) * width + x + feature.x
                let value = contrast[index]
                let pixel = index * 4
                let low = min(source[pixel], source[pixel + 1], source[pixel + 2])
                let high = max(source[pixel], source[pixel + 1], source[pixel + 2])
                if low >= 120, high - low < 30,
                   value >= max(1, feature.contrast / 3), value <= feature.contrast * 2 + 3 {
                    matched += 1
                    difference += min(1, Double(abs(value - feature.contrast)) / Double(max(3, feature.contrast)))
                } else {
                    difference += 1
                }
                if number == 15, matched < 5 { return 0 }
            }
            guard Double(matched) / Double(template.features.count) >= minimumMatchRatio else { return 0 }
            return 1 - difference / Double(template.features.count)
        }
        var candidates: [Match] = []
        for y in 0...(height - template.height) {
            try Task.checkCancellation()
            for x in 0...(width - template.width) {
                let value = score(x: x, y: y)
                if value >= 0.5 { candidates.append(Match(x: x, y: y, score: value)) }
            }
        }
        var matches: [Match] = []
        for candidate in candidates.sorted(by: { $0.score > $1.score }) {
            guard !matches.contains(where: { abs($0.x - candidate.x) < template.width / 2 + 1 && abs($0.y - candidate.y) < template.height / 2 + 1 }) else { continue }
            var best = candidate
            for y in max(0, candidate.y - 2)...min(height - template.height, candidate.y + 2) {
                for x in max(0, candidate.x - 2)...min(width - template.width, candidate.x + 2) {
                    let value = score(x: x, y: y)
                    if value > best.score { best = Match(x: x, y: y, score: value) }
                }
            }
            matches.append(best)
        }
        // Occluded instances need both a repeated spatial layout and visible matching strokes.
        // Layout alone never authorizes changing a predicted region.
        var displacements: [(x: Double, y: Double, count: Int)] = []
        for first in matches.indices {
            for second in matches.indices where second > first {
                var dx = Double(matches[second].x - matches[first].x)
                var dy = Double(matches[second].y - matches[first].y)
                if abs(dy) <= 3 { dy = 0 }
                if dy < 0 || (dy == 0 && dx < 0) { dx = -dx; dy = -dy }
                if let index = displacements.firstIndex(where: { abs($0.x - dx) <= 3 && abs($0.y - dy) <= 3 }) {
                    let count = Double(displacements[index].count)
                    displacements[index].x = (displacements[index].x * count + dx) / (count + 1)
                    displacements[index].y = (displacements[index].y * count + dy) / (count + 1)
                    displacements[index].count += 1
                } else {
                    displacements.append((dx, dy, 1))
                }
            }
        }
        let repeatedOffsets = displacements.filter { $0.count >= 3 }.sorted { $0.count > $1.count }.prefix(8)
        var predictions: [(x: Int, y: Int, neighbors: Set<Int>)] = []
        for (index, match) in matches.enumerated() {
            for offset in repeatedOffsets {
                for sign in [-1.0, 1.0] {
                    let x = match.x + Int((offset.x * sign).rounded())
                    let y = match.y + Int((offset.y * sign).rounded())
                    guard x >= 0, x + template.width <= width, y >= 0, y + template.height <= height,
                          !matches.contains(where: { abs($0.x - x) < template.width / 2 + 1 && abs($0.y - y) < template.height / 2 + 1 }) else { continue }
                    if let prediction = predictions.firstIndex(where: { abs($0.x - x) <= 4 && abs($0.y - y) <= 4 }) {
                        predictions[prediction].neighbors.insert(index)
                    } else {
                        predictions.append((x, y, [index]))
                    }
                }
            }
        }
        for prediction in predictions where prediction.neighbors.count >= 2 {
            try Task.checkCancellation()
            var best = Match(x: prediction.x, y: prediction.y, score: 0)
            for y in max(0, prediction.y - 3)...min(height - template.height, prediction.y + 3) {
                for x in max(0, prediction.x - 3)...min(width - template.width, prediction.x + 3) {
                    let value = score(x: x, y: y, minimumMatchRatio: 0.4)
                    if value > best.score { best = Match(x: x, y: y, score: value) }
                }
            }
            if best.score >= 0.3,
               !matches.contains(where: { abs($0.x - best.x) < template.width / 2 + 1 && abs($0.y - best.y) < template.height / 2 + 1 }) {
                matches.append(best)
            }
        }
        return matches
    }

    private static func apply(template: Template, match: Match, source: [UInt8], output: inout [UInt8], width: Int, height: Int) {
        func opacity(x: Int, y: Int) -> Double {
            guard x >= 0, x < template.width, y >= 0, y < template.height else { return 0 }
            return template.opacity[y * template.width + x]
        }
        for y in 0..<template.height {
            for x in 0..<template.width {
                let alpha = opacity(x: x, y: y)
                let nearbyAlpha = (-1...1).flatMap { dy in (-1...1).map { dx in opacity(x: x + dx, y: y + dy) } }.max() ?? 0
                guard nearbyAlpha > 0 else { continue }
                let pixelX = match.x + x
                let pixelY = match.y + y
                let index = (pixelY * width + pixelX) * 4
                guard source[index + 3] == 255 else { continue }
                // Interpolate only across locally agreeing, unmasked pairs. Otherwise undo the
                // shared translucent overlay, retaining the image detail underneath its strokes.
                var background: [Double]?
                for direction in [(1, 0), (0, 1), (1, 1), (1, -1)] {
                    var pair: [(x: Int, y: Int)] = []
                    for sign in [-1, 1] {
                        for distance in 2...12 {
                            let dx = direction.0 * distance * sign
                            let dy = direction.1 * distance * sign
                            guard pixelX + dx >= 0, pixelX + dx < width, pixelY + dy >= 0, pixelY + dy < height else { break }
                            guard opacity(x: x + dx, y: y + dy) == 0 else { continue }
                            pair.append((pixelX + dx, pixelY + dy))
                            break
                        }
                    }
                    guard pair.count == 2 else { continue }
                    let first = (pair[0].y * width + pair[0].x) * 4
                    let second = (pair[1].y * width + pair[1].x) * 4
                    guard (0..<3).allSatisfy({ abs(Int(source[first + $0]) - Int(source[second + $0])) <= 3 }) else { continue }
                    background = (0..<3).map { (Double(source[first + $0]) + Double(source[second + $0])) / 2 }
                    break
                }
                if let background {
                    let changes = (0..<3).map { background[$0] - Double(source[index + $0]) }
                    if changes.min()! >= 0, changes.max()! <= template.peak * 255 + 3,
                       changes.max()! - changes.min()! <= 8 {
                        for channel in 0..<3 { output[index + channel] = UInt8(min(255, background[channel].rounded())) }
                        continue
                    }
                }
                guard alpha > 0 else { continue }
                for channel in 0..<3 {
                    output[index + channel] = UInt8(min(255, (Double(source[index + channel]) / (1 - alpha)).rounded()))
                }
            }
        }
    }
}
