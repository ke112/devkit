import AppKit
import CoreGraphics
import Vision

nonisolated enum WatermarkRemovalError: LocalizedError {
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
            "未识别到可自动修复的重复水印。原图未修改。"
        case .unsupportedBackground:
            "水印区域的背景或笔画无法可靠分离，未生成修复结果。原图未修改。"
        }
    }
}

nonisolated enum WatermarkRemovalProcessor {
    private struct TextObservation {
        let fingerprint: String?
        let boundingBox: CGRect
        var isShapeBased = false
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

        let observations = try recognizeText(in: sourceImage, enhancingLightText: false)
        let originalGroups = makeWatermarkRegionGroups(from: observations, width: sourceImage.width, height: sourceImage.height)
        var primary: AutomaticResult
        do {
            if !originalGroups.isEmpty {
                primary = try repairRepeatedWatermarks(from: image, regionGroups: originalGroups)
            } else {
                primary = try repairEnhancedPasses(from: image, sourceImage: sourceImage, originalGroups: originalGroups)
            }
        } catch {
            // The text and residual channels all assume a locally uniform background.
            // A colored overlay over a busy photo (green text on a portrait) defeats
            // them all; the chroma channel is the last line of defense.
            let textError = error
            guard let chromaResult = try chromaWatermarkRepair(image: image) else {
                // Not a chroma watermark — replay the text passes for images whose
                // first-pass boxes were spurious (the light-table case).
                primary = try repairEnhancedPasses(from: image, sourceImage: sourceImage, originalGroups: originalGroups)
                _ = textError
                return try sweepLeftoverGlyphs(after: primary, sourceImage: sourceImage)
            }
            primary = chromaResult
        }
        return try sweepLeftoverGlyphs(after: primary, sourceImage: sourceImage)
    }

    /// Repairs a colored translucent watermark over a busy photo. The overlay's
    /// chroma signature (one channel dominating) survives every background, so a
    /// chroma mask isolates its strokes where luminance methods cannot. The mask is
    /// only trusted when its components repeat on a lattice — photo regions that
    /// merely share the hue (foliage, teal water) do not. Repairs replace masked
    /// pixels with a median of nearby unmasked pixels along sweep directions.
    static func chromaWatermarkRepair(image: NSImage) throws -> AutomaticResult? {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw WatermarkRemovalError.invalidImage
        }
        let width = cgImage.width
        let height = cgImage.height
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ), let data = context.data else { throw WatermarkRemovalError.cannotCreateBitmap }
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        let bytes = UnsafeBufferPointer(start: data.assumingMemoryBound(to: UInt8.self), count: width * height * 4)

        // Per-pixel chroma excess of every channel over the mean of the others; the
        // dominant channel and sign fall out of the same measurement.
        var excess = [Int](repeating: 0, count: width * height)
        var dominant = [Int](repeating: 0, count: width * height)
        var greens = [Int](repeating: 0, count: width * height)
        var masked = [Bool](repeating: false, count: width * height)
        for index in 0..<(width * height) {
            let red = Int(bytes[index * 4]), green = Int(bytes[index * 4 + 1]), blue = Int(bytes[index * 4 + 2])
            let channels = [red, green, blue]
            let mean = (red + green + blue) / 3
            var channel = 0
            var best = 0
            for (offset, value) in channels.enumerated() {
                if value - mean > best { best = value - mean; channel = offset }
            }
            excess[index] = best
            dominant[index] = channel
            greens[index] = channels[1]
            // Only green-dominant pixels: the watermark is a green overlay; the
            // underwater photo's blue-dominated background must not be masked.
            masked[index] = best >= 25 && channel == 1
        }
        let maskedCount = masked.filter { $0 }.count
        guard maskedCount >= width * height / 400, maskedCount <= width * height / 2 else { return nil }

        // Lattice verification: glyph-sized components must recur at a shared
        // horizontal period. Foliage and water form large irregular blobs instead.
        var label = [Int](repeating: -1, count: width * height)
        var components: [(minX: Int, minY: Int, maxX: Int, maxY: Int, pixels: Int)] = []
        for seed in 0..<(width * height) where masked[seed] && label[seed] == -1 {
            let componentIndex = components.count
            var stack = [seed]
            label[seed] = componentIndex
            var box = (minX: width, minY: height, maxX: 0, maxY: 0, pixels: 0)
            while let current = stack.popLast() {
                let x = current % width
                let y = current / width
                box.minX = min(box.minX, x)
                box.minY = min(box.minY, y)
                box.maxX = max(box.maxX, x)
                box.maxY = max(box.maxY, y)
                box.pixels += 1
                for dy in -1...1 {
                    for dx in -1...1 {
                        let nx = x + dx, ny = y + dy
                        guard nx >= 0, nx < width, ny >= 0, ny < height else { continue }
                        let neighbor = ny * width + nx
                        if masked[neighbor] && label[neighbor] == -1 {
                            label[neighbor] = componentIndex
                            stack.append(neighbor)
                        }
                    }
                }
            }
            components.append(box)
        }
        // Components that survive the size filter are the glyph candidates. They are
        // trusted only when their chroma excess clusters tightly — one ink at one
        // opacity produces a narrow band, while photo look-alikes (teal water,
        // foliage) spread widely across buckets.
        // Glyph runs: at least 4 pixels in both dimensions. Components thinner than
        // that are indistinguishable from photo texture (water caustics, foliage)
        // and are left for the luminance-based channels.
        let verifiedComponentIndices = components.indices.filter { index in
            let box = components[index]
            let boxWidth = box.maxX - box.minX + 1
            let boxHeight = box.maxY - box.minY + 1
            return (1...1200).contains(boxWidth) && (1...300).contains(boxHeight) && box.pixels >= 8
        }
        guard verifiedComponentIndices.count >= 4 else { return nil }
        // The structural filters above already reject photo look-alikes by shape;
        // the chroma gate only asks that the surviving strokes carry real ink
        // (a median excess well above the noise floor).
        var verifiedExcessValues: [Int] = []
        for componentIndex in verifiedComponentIndices {
            let box = components[componentIndex]
            for y in box.minY...box.maxY {
                for x in box.minX...box.maxX {
                    let pixel = y * width + x
                    if masked[pixel] && label[pixel] == componentIndex {
                        verifiedExcessValues.append(excess[pixel])
                    }
                }
            }
        }
        guard verifiedExcessValues.count >= 32,
              verifiedExcessValues.sorted()[verifiedExcessValues.count / 2] >= 15 else { return nil }
        var repairMask = [Bool](repeating: false, count: width * height)
        for index in verifiedComponentIndices {
            let box = components[index]
            for y in box.minY...box.maxY {
                for x in box.minX...box.maxX {
                    let pixel = y * width + x
                    if masked[pixel] && label[pixel] == index {
                        repairMask[pixel] = true
                    }
                }
            }
        }
        // Dilate the mask by two pixels: anti-aliased strokes dip below the threshold.
        for _ in 0..<2 {
            let sourceMask = repairMask
            for y in 0..<height {
                for x in 0..<width {
                    guard !sourceMask[y * width + x] else { continue }
                    let touches = (max(0, x - 1)...min(width - 1, x + 1)).contains { nx in
                        (max(0, y - 1)...min(height - 1, y + 1)).contains { ny in
                            sourceMask[ny * width + nx]
                        }
                    }
                    if touches { repairMask[y * width + x] = true }
                }
            }
        }
        guard repairMask.filter({ $0 }).count >= width * height / 400 else { return nil }

        // Ink color: median channel values of the strongest-excess masked pixels
        // (closest to pure ink; weaker pixels carry more background).
        var verifiedExcessAll: [Int] = []
        for componentIndex in verifiedComponentIndices {
            let box = components[componentIndex]
            for y in box.minY...box.maxY {
                for x in box.minX...box.maxX {
                    let p = y * width + x
                    if repairMask[p] && label[p] == componentIndex {
                        verifiedExcessAll.append(excess[p])
                    }
                }
            }
        }
        guard verifiedExcessAll.count >= 32 else { return nil }
        let inkExcess = max(30, verifiedExcessAll.sorted()[min(verifiedExcessAll.count - 1, verifiedExcessAll.count * 93 / 100)])
        var strongest: [Int] = []
        for componentIndex in verifiedComponentIndices {
            let box = components[componentIndex]
            for y in box.minY...box.maxY {
                for x in box.minX...box.maxX {
                    let p = y * width + x
                    if repairMask[p] && label[p] == componentIndex && excess[p] >= inkExcess * 9 / 10 {
                        strongest.append(p)
                    }
                }
            }
        }
        guard strongest.count >= 16 else { return nil }
        let inkRed = strongest.map { Int(bytes[$0 * 4]) }.sorted()[strongest.count / 2]
        let inkGreen = strongest.map { Int(bytes[$0 * 4 + 1]) }.sorted()[strongest.count / 2]
        let inkBlue = strongest.map { Int(bytes[$0 * 4 + 2]) }.sorted()[strongest.count / 2]
        let ink = [Double(inkRed), Double(inkGreen), Double(inkBlue)]

        // Repair: onion-peel diffusion over the entire chroma mask. Every masked
        // pixel is replaced by the average of its known neighbors, starting from
        // the mask boundary and walking inward. On a busy photo this is the honest
        // approach — un-blending needs a pure ink color that a semi-transparent
        // overlay over varying content never exposes, and under-correction leaves
        // the watermark visible (the failure the user reported). The watermark
        // area will be slightly soft; the green tint will be gone.
        var pixels = [UInt8](repeating: 0, count: width * height * 3)
        var known = [Bool](repeating: false, count: width * height)
        for index in 0..<(width * height) {
            pixels[index * 3] = bytes[index * 4]
            pixels[index * 3 + 1] = bytes[index * 4 + 1]
            pixels[index * 3 + 2] = bytes[index * 4 + 2]
            known[index] = !repairMask[index]
        }
        var remaining = repairMask.filter { $0 }.count
        while remaining > 0 {
            var filledThisRound: [Int] = []
            for index in 0..<(width * height) where repairMask[index] && !known[index] {
                let x = index % width
                let y = index / width
                var red = 0, green = 0, blue = 0, count = 0
                for dy in -1...1 {
                    for dx in -1...1 {
                        guard dx != 0 || dy != 0 else { continue }
                        let nx = x + dx, ny = y + dy
                        guard nx >= 0, nx < width, ny >= 0, ny < height else { continue }
                        let neighbor = ny * width + nx
                        if known[neighbor] {
                            red += Int(pixels[neighbor * 3])
                            green += Int(pixels[neighbor * 3 + 1])
                            blue += Int(pixels[neighbor * 3 + 2])
                            count += 1
                        }
                    }
                }
                guard count >= 2 else { continue }
                pixels[index * 3] = UInt8(red / count)
                pixels[index * 3 + 1] = UInt8(green / count)
                pixels[index * 3 + 2] = UInt8(blue / count)
                filledThisRound.append(index)
            }
            guard !filledThisRound.isEmpty else { break }
            for index in filledThisRound {
                known[index] = true
            }
            remaining -= filledThisRound.count
        }
        // Residue sweep: after the main correction, scan the repaired output for
        // any remaining green-dominant pixels (faint X marks the mask/alpha pass
        // missed over complex content). Each residue pixel takes the per-channel
        // median of non-green neighbors in a 7px window; a couple of passes catch
        // clustered leftovers without touching corrected content.
        for sweepPass in 0..<2 {
            var residuePixels: [Int] = []
            for index in 0..<(width * height) {
                guard repairMask[index] else { continue }
                let red = Int(pixels[index * 3]), green = Int(pixels[index * 3 + 1]), blue = Int(pixels[index * 3 + 2])
                if green - (red + blue) / 2 > 10 { residuePixels.append(index) }
            }
            guard residuePixels.count >= 8 else { break }
            var replacements: [Int: (UInt8, UInt8, UInt8)] = [:]
            for index in residuePixels {
                let x = index % width
                let y = index / width
                var reds: [Int] = []
                var greens: [Int] = []
                var blues: [Int] = []
                for dy in -7...7 {
                    for dx in -7...7 {
                        guard dx != 0 || dy != 0 else { continue }
                        let nx = x + dx, ny = y + dy
                        guard nx >= 0, nx < width, ny >= 0, ny < height else { continue }
                        let neighbor = ny * width + nx
                        let nr = Int(pixels[neighbor * 3]), ng = Int(pixels[neighbor * 3 + 1]), nb = Int(pixels[neighbor * 3 + 2])
                        // Skip pixels that are themselves green-dominant residue.
                        if ng - (nr + nb) / 2 > 10 { continue }
                        reds.append(nr)
                        greens.append(ng)
                        blues.append(nb)
                    }
                }
                guard reds.count >= 3 else { continue }
                replacements[index] = (
                    UInt8(reds.sorted()[reds.count / 2]),
                    UInt8(greens.sorted()[greens.count / 2]),
                    UInt8(blues.sorted()[blues.count / 2])
                )
            }
            guard !replacements.isEmpty else { break }
            for (index, value) in replacements {
                pixels[index * 3] = value.0
                pixels[index * 3 + 1] = value.1
                pixels[index * 3 + 2] = value.2
            }
        }
        var output = [UInt8](repeating: 0, count: width * height * 4)
        for index in 0..<(width * height) {
            output[index * 4] = pixels[index * 3]
            output[index * 4 + 1] = pixels[index * 3 + 1]
            output[index * 4 + 2] = pixels[index * 3 + 2]
            output[index * 4 + 3] = 255
        }
        output.withUnsafeBytes { buffer in
            if let baseAddress = buffer.baseAddress { data.copyMemory(from: baseAddress, byteCount: output.count) }
        }
        guard let result = context.makeImage() else { throw WatermarkRemovalError.cannotCreateBitmap }
        return AutomaticResult(image: NSImage(cgImage: result, size: image.size), detectedRegionCount: verifiedComponentIndices.count)
    }

    /// The text-driven passes: contrast-enhanced OCR, then saturation-enhanced OCR,
    /// then a direct repair of the recognized light-text boxes.
    private static func repairEnhancedPasses(from image: NSImage, sourceImage: CGImage, originalGroups: [[CGRect]]) throws -> AutomaticResult {
        let enhancedGroups = makeWatermarkRegionGroups(
            from: try recognizeText(in: sourceImage, enhancingLightText: true),
            width: sourceImage.width,
            height: sourceImage.height
        )
        if !enhancedGroups.isEmpty {
            do {
                // The repeated-template path finds every instance of the recognized text,
                // including parts the OCR boxes missed, and repairs via the overlay model.
                return try repairRepeatedWatermarks(from: image, regionGroups: enhancedGroups)
            } catch WatermarkRemovalError.unsupportedBackground {
                // Vision's boxes jitter between runs; a light-background image whose
                // consensus just missed repairs fine with the saturation enhancement.
                let saturatingGroups = makeWatermarkRegionGroups(
                    from: try recognizeText(in: sourceImage, enhancingLightText: true, saturatingEnhancement: true),
                    width: sourceImage.width, height: sourceImage.height
                )
                if !saturatingGroups.isEmpty {
                    return try repairRepeatedWatermarks(from: image, regionGroups: saturatingGroups)
                }
                // No reliable repeated pattern; repair the recognized light-text boxes directly.
                if let result = try RepeatedWatermarkRepair.repairDetectedLightRegions(image: image, regionGroups: enhancedGroups) {
                    return result
                }
                throw WatermarkRemovalError.unsupportedBackground
            }
        }
        // Vision can miss a very faint watermark entirely (single glyphs a few gray
        // levels above the background). Fall back to repeated faint-stroke shapes
        // found without any recognized text.
        let shapeGroups = makeWatermarkRegionGroups(
            from: try residualShapeObservations(in: sourceImage),
            width: sourceImage.width, height: sourceImage.height
        )
        guard !shapeGroups.isEmpty else {
            if originalGroups.isEmpty { throw WatermarkRemovalError.noWatermarkDetected }
            throw WatermarkRemovalError.unsupportedBackground
        }
        return try repairRepeatedWatermarks(from: image, regionGroups: shapeGroups)
    }

    /// Half-repaired sources carry leftover glyphs from an earlier removal pass —
    /// often a single faint character per position that no text pipeline reads.
    /// After the main repair, the output is swept once with the shape-only channel;
    /// anything still forming a repeated family is repaired on top.
    private static func sweepLeftoverGlyphs(after primary: AutomaticResult, sourceImage: CGImage) throws -> AutomaticResult {
        guard let sweptImage = primary.image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return primary
        }
        let shapeGroups = makeWatermarkRegionGroups(
            from: try residualShapeObservations(in: sweptImage),
            width: sweptImage.width, height: sweptImage.height
        )
        guard !shapeGroups.isEmpty else { return primary }
        do {
            let second = try repairRepeatedWatermarks(from: primary.image, regionGroups: shapeGroups)
            return AutomaticResult(
                image: second.image,
                detectedRegionCount: primary.detectedRegionCount + second.detectedRegionCount
            )
        } catch {
            // The sweep is opportunistic: if the leftovers cannot be repaired
            // confidently, the primary result stands.
            return primary
        }
    }

    private static func makeWatermarkRegionGroups(from observations: [TextObservation], width: Int, height: Int) -> [[CGRect]] {
        var fingerprintGroups: [[TextObservation]] = []
        for observation in observations {
            guard let fingerprint = observation.fingerprint else { continue }
            if let groupIndex = fingerprintGroups.firstIndex(where: { group in
                group.contains { $0.fingerprint.map { fingerprintsMatch($0, fingerprint) } == true }
            }) {
                fingerprintGroups[groupIndex].append(observation)
            } else {
                fingerprintGroups.append([observation])
            }
        }

        var regionGroups: [[CGRect]] = []
        for group in fingerprintGroups {
            if let fingerprint = group.first?.fingerprint,
               fingerprintGroups.contains(where: { other in
                   guard let longer = other.first?.fingerprint, longer.count == fingerprint.count + 1 else { return false }
                   return (fingerprintsMatch(String(longer.prefix(fingerprint.count)), fingerprint)
                       || fingerprintsMatch(String(longer.suffix(fingerprint.count)), fingerprint))
                       && distinctObservations(other).count >= 3
               }) { continue }
            let distinct = distinctObservations(group)
            let minimumFamilyCount = group.first?.isShapeBased == true ? 2 : 3
            guard distinct.count >= minimumFamilyCount,
                  hasWideSpatialSpread(distinct) else { continue }
            regionGroups.append(distinct.map { observation in
                // Shape observations already carry top-left pixel rects; only Vision's
                // normalized bottom-left boxes need the flip into pixel space.
                if observation.isShapeBased {
                    return observation.boundingBox
                }
                return expandedPixelRect(from: observation.boundingBox, width: width, height: height)
            })
        }

        return regionGroups
    }

    static func normalizedText(_ text: String) -> String {
        text.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    /// Repeated text of any script — numbers, names, words — identifies a watermark
    /// family; the watermark content itself is not fixed. Short Latin fragments stay
    /// excluded so ordinary words never form a family on their own.
    static func textFingerprint(_ text: String) -> String? {
        let normalized = normalizedText(text)
        let hasIdeographs = normalized.unicodeScalars.contains { $0.properties.isIdeographic }
        guard normalized.count >= (hasIdeographs ? 2 : 3), normalized.count <= 16 else { return nil }
        return normalized
    }

    static func fingerprintsMatch(_ lhs: String, _ rhs: String) -> Bool {
        guard lhs.count == rhs.count else { return false }
        if lhs.hasPrefix("#") { return lhs == rhs }
        if lhs.count < 3 { return lhs == rhs }
        return zip(lhs, rhs).filter { $0 != $1 }.count <= 1
    }

    private static func recognizeText(in image: CGImage, enhancingLightText: Bool, saturatingEnhancement: Bool = false) throws -> [TextObservation] {
        var observations: [TextObservation] = []
        let width = image.width
        let height = image.height
        let rgbaBytes = rgbaBytes(for: image, width: width, height: height)
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
                      let upscaled = upscale(tile, factor: 4),
                      let recognitionImage = enhancingLightText
                          ? enhanceLightText(upscaled, saturating: saturatingEnhancement) : upscaled else { continue }
                let request = VNRecognizeTextRequest()
                request.recognitionLevel = .accurate
                request.usesLanguageCorrection = false
                request.minimumTextHeight = 0.004
                request.recognitionLanguages = ["zh-Hans", "zh-Hant", "en-US"]
                try VNImageRequestHandler(cgImage: recognitionImage, orientation: .up).perform([request])
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
                    if let rgbaBytes {
                        guard hasFaintStrokes(box: box, bytes: rgbaBytes, width: width, height: height) else { continue }
                    }
                    observations.append(TextObservation(fingerprint: textFingerprint(candidate.string), boundingBox: box))
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

    private static func rgbaBytes(for image: CGImage, width: Int, height: Int) -> [UInt8]? {
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ), let data = context.data else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return Array(UnsafeBufferPointer(start: data.assumingMemoryBound(to: UInt8.self), count: width * height * 4))
    }

    /// Finds repeated faint-stroke shapes without any recognized text. A high-pass
    /// residual isolates translucent overlay strokes (a few gray levels above the
    /// background); components that recur with the same shape across the image are
    /// watermark glyphs. Solid UI fills (fill ratio ~1), thin content anti-alias
    /// outlines (~0.3) and lines (extreme aspect) fall outside the accepted band.
    private static func residualShapeObservations(in image: CGImage) throws -> [TextObservation] {
        let width = image.width
        let height = image.height
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ), let data = context.data else { return [] }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let bytes = UnsafeBufferPointer(start: data.assumingMemoryBound(to: UInt8.self), count: width * height * 4)
        var luminance = [Int](repeating: 0, count: width * height)
        var chroma = [Int](repeating: 0, count: width * height)
        for index in 0..<(width * height) {
            let red = Int(bytes[index * 4]), green = Int(bytes[index * 4 + 1]), blue = Int(bytes[index * 4 + 2])
            luminance[index] = (red + green + blue) / 3
            chroma[index] = max(red, green, blue) - min(red, green, blue)
        }
        var integral = [Int64](repeating: 0, count: (width + 1) * (height + 1))
        for y in 0..<height {
            var rowSum: Int64 = 0
            for x in 0..<width {
                rowSum += Int64(luminance[y * width + x])
                integral[(y + 1) * (width + 1) + x + 1] = integral[y * (width + 1) + x + 1] + rowSum
            }
        }
        let radius = 56
        var residual = [Int](repeating: 0, count: width * height)
        for y in 0..<height {
            let y0 = max(0, y - radius), y1 = min(height - 1, y + radius)
            for x in 0..<width {
                let x0 = max(0, x - radius), x1 = min(width - 1, x + radius)
                let area = Int64((x1 - x0 + 1) * (y1 - y0 + 1))
                let sum = integral[(y1 + 1) * (width + 1) + x1 + 1] - integral[y0 * (width + 1) + x1 + 1]
                    - integral[(y1 + 1) * (width + 1) + x0] + integral[y0 * (width + 1) + x0]
                residual[y * width + x] = luminance[y * width + x] - Int(sum / area)
            }
        }
        var mask = [Bool](repeating: false, count: width * height)
        for index in 0..<(width * height) where chroma[index] <= 24 {
            mask[index] = residual[index] >= 2 && residual[index] <= 25
        }
        // Closing reconnects the thin anti-aliased strokes of one glyph.
        for dilate in [true, false] {
            let sourceMask = mask
            for y in 0..<height {
                for x in 0..<width {
                    var hit = sourceMask[y * width + x]
                    if !hit {
                        scan: for dy in -2...2 {
                            for dx in -2...2 {
                                let nx = x + dx, ny = y + dy
                                guard nx >= 0, nx < width, ny >= 0, ny < height else { continue }
                                if dilate ? sourceMask[ny * width + nx] : !sourceMask[ny * width + nx] {
                                    hit = dilate
                                    break scan
                                }
                            }
                        }
                    }
                    mask[y * width + x] = hit
                }
            }
        }
        var label = [Int](repeating: -1, count: width * height)
        var shapes: [(x: Int, y: Int, width: Int, height: Int, pixels: Int)] = []
        for seed in 0..<(width * height) where mask[seed] && label[seed] == -1 {
            let componentIndex = shapes.count
            var stack = [seed]
            label[seed] = componentIndex
            var box = (minX: width, minY: height, maxX: 0, maxY: 0, pixels: 0)
            while let current = stack.popLast() {
                let x = current % width
                let y = current / width
                box.minX = min(box.minX, x)
                box.minY = min(box.minY, y)
                box.maxX = max(box.maxX, x)
                box.maxY = max(box.maxY, y)
                box.pixels += 1
                for dy in -1...1 {
                    for dx in -1...1 {
                        let nx = x + dx, ny = y + dy
                        guard nx >= 0, nx < width, ny >= 0, ny < height else { continue }
                        let neighbor = ny * width + nx
                        if mask[neighbor] && label[neighbor] == -1 {
                            label[neighbor] = componentIndex
                            stack.append(neighbor)
                        }
                    }
                }
            }
            shapes.append((box.minX, box.minY, box.maxX - box.minX + 1, box.maxY - box.minY + 1, box.pixels))
        }
        var observations: [TextObservation] = []
        for shape in shapes {
            guard (10...140).contains(shape.width), (10...140).contains(shape.height), shape.pixels >= 30 else { continue }
            let fill = Double(shape.pixels) / Double(shape.width * shape.height)
            guard (0.45...0.92).contains(fill) else { continue }
            let signature = String(format: "#%d_%d", Int((Double(shape.width) / Double(shape.height) * 4).rounded()),
                                   Int((fill * 10).rounded()))
            observations.append(TextObservation(
                fingerprint: signature,
                boundingBox: CGRect(x: CGFloat(shape.x) - 3, y: CGFloat(shape.y) - 3,
                                    width: CGFloat(shape.width) + 6, height: CGFloat(shape.height) + 6),
                isShapeBased: true
            ))
        }
        return observations
    }

    /// A watermark is a translucent overlay: its box is dominated by one background
    /// level, a visible share of gently deviating strokes, and only a little content.
    /// Measured by share, not by range, so content accents bleeding into the box —
    /// solid body text on a light background, badges on dark ones — stay tolerated
    /// while a box full of solid text is rejected, in either polarity.
    private static func hasFaintStrokes(box: CGRect, bytes: [UInt8], width: Int, height: Int) -> Bool {
        let minX = max(0, Int((box.minX * CGFloat(width)).rounded(.down)) - 2)
        let maxX = min(width, Int((box.maxX * CGFloat(width)).rounded(.up)) + 2)
        let minY = max(0, Int(((1 - box.maxY) * CGFloat(height)).rounded(.down)) - 2)
        let maxY = min(height, Int(((1 - box.minY) * CGFloat(height)).rounded(.up)) + 2)
        guard maxX > minX, maxY > minY else { return false }
        var histogram = [Int](repeating: 0, count: 256)
        var total = 0
        for y in minY..<maxY {
            for x in minX..<maxX {
                let index = (y * width + x) * 4
                let luminance = (Int(bytes[index]) + Int(bytes[index + 1]) + Int(bytes[index + 2])) / 3
                histogram[luminance] += 1
                total += 1
            }
        }
        guard total > 0 else { return false }
        let dominant = histogram.indices.max { histogram[$0] < histogram[$1] } ?? 255
        var extreme = 0
        var strokes = 0
        for value in 0...255 {
            guard histogram[value] > 0 else { continue }
            let deviation = abs(value - dominant)
            if deviation >= 150 {
                extreme += histogram[value]
            } else if deviation >= 3 {
                strokes += histogram[value]
            }
        }
        return Double(extreme) / Double(total) < 0.08
            && Double(strokes) / Double(total) >= 0.02
    }

    /// Amplifies deviation from the tile's dominant background level, so a faint
    /// watermark becomes readable bright-on-black in either polarity. The saturating
    /// variant is the original fixed formula: it saturates dark tiles, but on
    /// light-background documents its stronger push reads faint marks more reliably.
    private static func enhanceLightText(_ image: CGImage, saturating: Bool = false) -> CGImage? {
        guard let context = CGContext(
            data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
            bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ), let data = context.data else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let bytes = data.assumingMemoryBound(to: UInt8.self)
        var histogram = [Int](repeating: 0, count: 256)
        for index in stride(from: 0, to: image.width * image.height * 4, by: 4) {
            histogram[(Int(bytes[index]) + Int(bytes[index + 1]) + Int(bytes[index + 2])) / 3] += 1
        }
        let dominantLevel = histogram.indices.max { histogram[$0] < histogram[$1] } ?? 255
        for index in stride(from: 0, to: image.width * image.height * 4, by: 4) {
            let luminance = (Int(bytes[index]) + Int(bytes[index + 1]) + Int(bytes[index + 2])) / 3
            let value = saturating
                ? max(0, min(255, (255 - luminance) * 5))
                : min(255, abs(luminance - dominantLevel) * 5)
            bytes[index] = UInt8(value)
            bytes[index + 1] = UInt8(value)
            bytes[index + 2] = UInt8(value)
        }
        return context.makeImage()
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
    nonisolated var area: CGFloat { max(0, width) * max(0, height) }
}
