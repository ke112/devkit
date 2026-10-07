import AppKit

nonisolated enum RepeatedWatermarkRepair {
    private struct Template {
        let width: Int
        let height: Int
        let opacity: [Double]
        let features: [(x: Int, y: Int, contrast: Int)]
        let peak: Double
        let background: Int
    }

    private struct Match {
        let x: Int
        let y: Int
        let score: Double
    }

    /// Stroke alpha of one OCR box measured against the box's own background.
    /// Values include the anti-alias edges (difference >= 1); votes and features use
    /// the `strokeThreshold` floor so JPEG noise never counts as a stroke.
    private struct InstanceMap {
        let x: Int
        let y: Int
        let width: Int
        let height: Int
        let background: Int
        let alpha: [Double]

        var strokeThreshold: Double { 3.0 / Double(background) }
    }

    static func repairDetectedLightRegions(image: NSImage, regionGroups: [[CGRect]]) throws -> WatermarkRemovalProcessor.AutomaticResult? {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw WatermarkRemovalError.invalidImage
        }
        let width = cgImage.width
        let height = cgImage.height
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ), let data = context.data else { throw WatermarkRemovalError.cannotCreateBitmap }
        context.draw(cgImage, in: bounds)
        let source = Array(UnsafeBufferPointer(start: data.assumingMemoryBound(to: UInt8.self), count: width * height * 4))
        var mask = [Bool](repeating: false, count: width * height)
        for group in regionGroups {
            for region in group {
                let rect = region.insetBy(dx: -2, dy: -2).integral.intersection(bounds)
                let pixelCount = max(1, Int(rect.width * rect.height))
                let darkCount = (Int(rect.minY)..<Int(rect.maxY)).reduce(0) { count, y in
                    count + (Int(rect.minX)..<Int(rect.maxX)).reduce(0) { subtotal, x in
                        let index = (y * width + x) * 4
                        let luminance = (Int(source[index]) + Int(source[index + 1]) + Int(source[index + 2])) / 3
                        return subtotal + (luminance < 150 ? 1 : 0)
                    }
                }
                guard Double(darkCount) / Double(pixelCount) < 0.01 else { continue }
                for y in Int(rect.minY)..<Int(rect.maxY) {
                    for x in Int(rect.minX)..<Int(rect.maxX) {
                        let index = (y * width + x) * 4
                        let channels = (0..<3).map { Int(source[index + $0]) }
                        let luminance = channels.reduce(0, +) / 3
                        if luminance >= 180 && luminance < 252 && channels.max()! - channels.min()! <= 8 {
                            mask[y * width + x] = true
                        }
                    }
                }
            }
        }
        guard mask.contains(true) else { return nil }
        var output = source
        var changed = 0
        for index in mask.indices where mask[index] {
            let x = index % width
            let y = index / width
            var neighbors: [[UInt8]] = []
            for radius in 1...4 {
                for (nx, ny) in [(x - radius, y), (x + radius, y), (x, y - radius), (x, y + radius)]
                where nx >= 0 && nx < width && ny >= 0 && ny < height && !mask[ny * width + nx] {
                    let neighbor = (ny * width + nx) * 4
                    neighbors.append(Array(source[neighbor..<neighbor + 3]))
                }
            }
            guard neighbors.count >= 2 else { continue }
            for channel in 0..<3 {
                output[index * 4 + channel] = neighbors.map { $0[channel] }.sorted()[neighbors.count / 2]
            }
            changed += 1
        }
        guard changed > 0 else { return nil }
        output.withUnsafeBytes { bytes in
            if let baseAddress = bytes.baseAddress { data.copyMemory(from: baseAddress, byteCount: output.count) }
        }
        guard let result = context.makeImage() else { throw WatermarkRemovalError.cannotCreateBitmap }
        return .init(image: NSImage(cgImage: result, size: image.size), detectedRegionCount: regionGroups.reduce(0) { $0 + $1.count })
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
        var output = source
        var repairedRegions: [CGRect] = []
        // Complementing RGB maps a white translucent overlay to the same black-overlay
        // model. OCR still uses the original image; alpha and unmasked pixels stay intact.
        for inverted in [false, true] {
            try Task.checkCancellation()
            let workingSource = inverted ? source.enumerated().map { index, value in
                index % 4 == 3 ? value : 255 - value
            } : source
            var luminance = [Int](repeating: 0, count: width * height)
            for index in luminance.indices {
                luminance[index] = (Int(workingSource[index * 4]) + Int(workingSource[index * 4 + 1]) + Int(workingSource[index * 4 + 2])) / 3
            }
            let contrast = try localContrast(luminance, width: width, height: height)
            var workingOutput = workingSource
            // Two boxes already cross-validate each other inside consensusTemplate;
            // smaller groups fail there instead of here.
            for regionGroup in regionGroups where regionGroup.count >= 2 {
                try Task.checkCancellation()
                // A different fingerprint can name the same watermark (its digits and
                // its name); boxes inside already-repaired regions carry no new work.
                let group = regionGroup.filter { box in
                    !repairedRegions.contains { $0.intersects(box) }
                }
                guard group.count >= 3 else { continue }
                guard let bootstrap = consensusTemplate(
                    boxes: group, source: workingSource, luminance: luminance, width: width, height: height
                ) else { continue }
                let initialMatches = try findMatches(
                    template: bootstrap, source: workingSource, contrast: contrast, width: width, height: height
                )
                guard initialMatches.count >= 3 else { continue }
                // A watermark tiles an image dozens of times at most. A template that
                // "matches" hundreds of positions is generic noise (a rule line, a
                // loose fragment), not a watermark — reject the whole family.
                let maximumMatches = max(48, width * height / max(1, bootstrap.width * bootstrap.height * 12))
                guard initialMatches.count <= maximumMatches else { continue }
                var template = bootstrap
                var matches = initialMatches
                // Neighboring watermark parts the OCR boxes miss (e.g. the name beside a
                // repeated number) join the template when their strokes repeat at every
                // matched position and stay connected to the bootstrap strokes.
                if let grown = try grownTemplate(
                    from: bootstrap, matches: initialMatches, source: workingSource,
                    luminance: luminance, contrast: contrast, width: width, height: height
                ) {
                    template = grown
                    matches = try findMatches(
                        template: template, source: workingSource, contrast: contrast, width: width, height: height
                    )
                    guard matches.count >= 3 else { continue }
                }
                for match in matches {
                    try Task.checkCancellation()
                    apply(template: template, match: match, source: workingSource, output: &workingOutput, width: width, height: height)
                    var region = CGRect(x: match.x, y: match.y, width: template.width, height: template.height).intersection(bounds)
                    // Different OCR numeric fragments can identify the same watermark.
                    for index in repairedRegions.indices.reversed() where repairedRegions[index].intersects(region) {
                        region = region.union(repairedRegions.remove(at: index))
                    }
                    repairedRegions.append(region)
                }
            }
            for index in output.indices where workingOutput[index] != workingSource[index] {
                output[index] = inverted ? 255 - workingOutput[index] : workingOutput[index]
            }
        }
        guard !repairedRegions.isEmpty else { throw WatermarkRemovalError.unsupportedBackground }
        try Task.checkCancellation()
        output.withUnsafeBytes { bytes in
            if let baseAddress = bytes.baseAddress { data.copyMemory(from: baseAddress, byteCount: output.count) }
        }
        guard let result = context.makeImage() else { throw WatermarkRemovalError.cannotCreateBitmap }
        return .init(image: NSImage(cgImage: result, size: image.size), detectedRegionCount: repairedRegions.count)
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

    /// Builds one template from every OCR box in a group. Boxes are aligned on their
    /// dominant stroke mass and only strokes repeated in (nearly) every box survive, so
    /// content bleeding into one box can never define the repair pattern.
    private static func consensusTemplate(boxes: [CGRect], source: [UInt8], luminance: [Int], width: Int, height: Int) -> Template? {
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        let maps = boxes.compactMap { box -> InstanceMap? in
            instanceMap(for: box.integral.intersection(bounds), source: source, luminance: luminance, width: width, height: height)
        }
        // One content-covered box must not void the family; two aligned boxes still
        // cross-validate each other. A single box has no cross-check and stays rejected.
        guard maps.count >= 2 else { return nil }
        let strokedIndices = maps.indices.filter { maps[$0].alpha.contains { $0 > 0 } }
        guard let referenceIndex = strokedIndices.max(by: {
            let lhs = maps[$0], rhs = maps[$1]
            let lhsArea = lhs.width * lhs.height, rhsArea = rhs.width * rhs.height
            if lhsArea != rhsArea { return lhsArea < rhsArea }
            return (lhs.alpha.max() ?? 0) > (rhs.alpha.max() ?? 0)
        }) else { return nil }
        let reference = maps[referenceIndex]
        let canvasWidth = reference.width
        let canvasHeight = reference.height
        // Boxes live at different image positions; alignment works in box-local
        // coordinates, where the same text occupies roughly the same offset.
        var aligned: [(map: InstanceMap, dx: Int, dy: Int, overlap: Int, strokeCount: Int)] = []
        for (index, map) in maps.enumerated() where index != referenceIndex {
            var best = (dx: 0, dy: 0, overlap: 0)
            // Vision boxes for the same faint text vary in size and padding, so the
            // glyph offset inside the box can drift by roughly half a glyph height.
            for dy in -10...10 {
                for dx in -10...10 {
                    var overlap = 0
                    for y in 0..<map.height {
                        for x in 0..<map.width
                        where map.alpha[y * map.width + x] >= map.strokeThreshold {
                            let canvasX = x + dx
                            let canvasY = y + dy
                            if canvasX >= 0, canvasX < canvasWidth, canvasY >= 0, canvasY < canvasHeight,
                               reference.alpha[canvasY * canvasWidth + canvasX] >= reference.strokeThreshold {
                                overlap += 1
                            }
                        }
                    }
                    if overlap > best.overlap { best = (dx, dy, overlap) }
                }
            }
            let strokeCount = map.alpha.filter { $0 >= map.strokeThreshold }.count
            aligned.append((map, best.dx, best.dy, best.overlap, strokeCount))
        }
        // Poorly aligned boxes describe different content; voting with them would
        // hollow out the template, so only well-aligned boxes get a vote.
        // The alpha-agreement check below is what keeps polluted boxes out of the
        // consensus; the alignment gate only needs to drop boxes whose strokes land
        // somewhere else entirely.
        let voting = [(reference, 0, 0)] + aligned.filter { Double($0.overlap) >= 0.5 * Double(max(1, $0.strokeCount)) }
            .map { ($0.map, $0.dx, $0.dy) }
        guard voting.count >= 2 else { return nil }
        let required = max(2, Int((0.55 * Double(voting.count)).rounded(.up)))
        var consensus = [Double](repeating: 0, count: canvasWidth * canvasHeight)
        for canvasY in 0..<canvasHeight {
            for canvasX in 0..<canvasWidth {
                var strong: [Double] = []
                var samples: [Double] = []
                for (map, dx, dy) in voting {
                    let localX = canvasX - dx
                    let localY = canvasY - dy
                    guard localX >= 0, localX < map.width, localY >= 0, localY < map.height else { continue }
                    let alpha = map.alpha[localY * map.width + localX]
                    if alpha >= map.strokeThreshold {
                        strong.append(alpha)
                        samples.append(alpha)
                    } else if alpha > 0, !strong.isEmpty {
                        samples.append(alpha)
                    }
                }
                guard strong.count >= required else { continue }
                let alpha = median(samples)
                guard strong.max()! - strong.min()! <= max(2.0 / 255, alpha * 0.6) else { continue }
                consensus[canvasY * canvasWidth + canvasX] = alpha
            }
        }
        // A one-pixel anti-alias ring around the agreed strokes keeps faint edges in
        // the template so `apply` can restore them instead of leaving a soft halo.
        // The adjacency snapshot keeps the ring from chaining through noise.
        let strokeSet = consensus.map { $0 > 0 }
        for canvasY in 0..<canvasHeight {
            for canvasX in 0..<canvasWidth {
                let index = canvasY * canvasWidth + canvasX
                guard consensus[index] == 0 else { continue }
                let touchesStroke = (max(0, canvasX - 1)...min(canvasWidth - 1, canvasX + 1)).contains { nx in
                    (max(0, canvasY - 1)...min(canvasHeight - 1, canvasY + 1)).contains { ny in
                        strokeSet[ny * canvasWidth + nx]
                    }
                }
                guard touchesStroke else { continue }
                var present: [Double] = []
                for (map, dx, dy) in voting {
                    let localX = canvasX - dx
                    let localY = canvasY - dy
                    guard localX >= 0, localX < map.width, localY >= 0, localY < map.height else { continue }
                    let alpha = map.alpha[localY * map.width + localX]
                    if alpha > 0 { present.append(alpha) }
                }
                guard present.count >= required else { continue }
                consensus[index] = median(present)
            }
        }
        dropIsolatedPixels(&consensus, width: canvasWidth, height: canvasHeight)
        return assembleTemplate(fromOpacity: consensus, width: canvasWidth, height: canvasHeight, background: reference.background)
    }

    /// Extracts the translucent-stroke alpha of one OCR box. The dark-text and background
    /// checks apply to the recognized text only; the padded surroundings just contribute
    /// the background estimate.
    private static func instanceMap(for core: CGRect, source: [UInt8], luminance: [Int], width: Int, height: Int) -> InstanceMap? {
        guard !core.isNull, core.width >= 1, core.height >= 1 else { return nil }
        let rect = core.insetBy(dx: -12, dy: -8).integral.intersection(CGRect(x: 0, y: 0, width: width, height: height))
        guard rect.width >= 1, rect.height >= 1 else { return nil }
        let rectWidth = Int(rect.width)
        let rectHeight = Int(rect.height)
        var histogram = [Int](repeating: 0, count: 256)
        var darkPixels = 0
        for y in Int(rect.minY)..<Int(rect.maxY) {
            for x in Int(rect.minX)..<Int(rect.maxX) {
                let index = y * width + x
                let channels = (0..<3).map { Int(source[index * 4 + $0]) }
                guard channels.max()! - channels.min()! <= 8, source[index * 4 + 3] == 255 else { continue }
                histogram[luminance[index]] += 1
                if luminance[index] < 150,
                   CGFloat(x) >= core.minX, CGFloat(x) < core.maxX,
                   CGFloat(y) >= core.minY, CGFloat(y) < core.maxY {
                    darkPixels += 1
                }
            }
        }
        guard let background = (180...255).filter({ histogram[$0] > 0 }).max(by: {
                  histogram[$0] + histogram[$0 - 1] < histogram[$1] + histogram[$1 - 1]
              }),
              Double(histogram[background] + histogram[background - 1]) / Double(rectWidth * rectHeight) >= 0.65,
              Double(darkPixels) / Double(max(1, Int(core.width) * Int(core.height))) < 0.01 else { return nil }
        let strokeArea = core.insetBy(dx: -4, dy: -4).intersection(rect)
        var alpha = [Double](repeating: 0, count: rectWidth * rectHeight)
        for y in max(Int(rect.minY), Int(strokeArea.minY))..<min(Int(rect.maxY), Int(strokeArea.maxY)) {
            for x in max(Int(rect.minX), Int(strokeArea.minX))..<min(Int(rect.maxX), Int(strokeArea.maxX)) {
                let index = y * width + x
                let channels = (0..<3).map { Int(source[index * 4 + $0]) }
                let difference = background - luminance[index]
                guard channels.max()! - channels.min()! <= 8,
                      difference > 0, difference <= 96, source[index * 4 + 3] == 255 else { continue }
                alpha[(y - Int(rect.minY)) * rectWidth + (x - Int(rect.minX))] = Double(difference) / Double(background)
            }
        }
        return InstanceMap(x: Int(rect.minX), y: Int(rect.minY), width: rectWidth, height: rectHeight,
                           background: background, alpha: alpha)
    }

    /// Extends the template with strokes that repeat at the same offset at every matched
    /// position and stay connected to the bootstrap strokes. Growth stops by itself at
    /// empty gaps, which keeps adjacent watermark repeats out of the template.
    private static func grownTemplate(from template: Template, matches: [Match], source: [UInt8], luminance: [Int], contrast: [Int], width: Int, height: Int) throws -> Template? {
        let margin = 64
        let jump = 12
        let votingMatches = Array(matches.prefix(60))
        let totalWidth = template.width + margin * 2
        let totalHeight = template.height + margin * 2
        guard votingMatches.count >= 3, totalWidth > 0, totalHeight > 0 else { return nil }
        // Many matched positions sit over content that hides parts of the glyph;
        // demanding a majority of all matches would drop exactly those strokes.
        // The alpha band below is what keeps content out.
        let required = max(3, Int((0.35 * Double(votingMatches.count)).rounded(.up)))
        // One overlay has one strength; strokes far stronger at every position are
        // content (table lines, glyph fragments), not the watermark.
        let bandLow = template.peak * 0.25
        let bandHigh = template.peak * 2.5
        var opacity = [Double](repeating: 0, count: totalWidth * totalHeight)
        var accepted = [Bool](repeating: false, count: totalWidth * totalHeight)
        var queue: [Int] = []
        for y in 0..<template.height {
            for x in 0..<template.width {
                let alpha = template.opacity[y * template.width + x]
                guard alpha > 0 else { continue }
                let index = (y + margin) * totalWidth + x + margin
                opacity[index] = alpha
                accepted[index] = true
                queue.append(index)
            }
        }
        let seedCount = queue.count
        var candidates = [Double?](repeating: nil, count: totalWidth * totalHeight)
        for y in 0..<totalHeight {
            try Task.checkCancellation()
            for x in 0..<totalWidth {
                let index = y * totalWidth + x
                guard !accepted[index] else { continue }
                var present: [Double] = []
                for match in votingMatches {
                    let pixelX = match.x + x - margin
                    let pixelY = match.y + y - margin
                    guard pixelX >= 0, pixelX < width, pixelY >= 0, pixelY < height else { continue }
                    let pixel = (pixelY * width + pixelX) * 4
                    guard source[pixel + 3] == 255 else { continue }
                    let channels = (0..<3).map { Int(source[pixel + $0]) }
                    guard channels.max()! - channels.min()! <= 10 else { continue }
                    let luminanceIndex = pixelY * width + pixelX
                    let localBackground = luminance[luminanceIndex] + contrast[luminanceIndex]
                    guard localBackground >= 120 else { continue }
                    let difference = contrast[luminanceIndex]
                    if difference >= 3, difference <= 96 {
                        present.append(Double(difference) / Double(localBackground))
                    }
                }
                guard present.count >= required else { continue }
                let alpha = median(present)
                guard alpha >= bandLow, alpha <= bandHigh else { continue }
                candidates[index] = alpha
            }
        }
        while let seed = queue.popLast() {
            let seedX = seed % totalWidth
            let seedY = seed / totalWidth
            for dy in max(0, seedY - jump)...min(totalHeight - 1, seedY + jump) {
                for dx in max(0, seedX - jump)...min(totalWidth - 1, seedX + jump) {
                    let index = dy * totalWidth + dx
                    guard !accepted[index], let alpha = candidates[index] else { continue }
                    opacity[index] = alpha
                    accepted[index] = true
                    queue.append(index)
                }
            }
        }
        // One-pixel anti-alias ring around the grown strokes, mirroring the bootstrap
        // ring so faint glyph edges are repaired instead of left as halos. The
        // adjacency snapshot keeps the ring from chaining through noise.
        let grownSet = accepted
        for y in 0..<totalHeight {
            for x in 0..<totalWidth {
                let index = y * totalWidth + x
                guard !accepted[index] else { continue }
                let touchesAccepted = (max(0, x - 1)...min(totalWidth - 1, x + 1)).contains { nx in
                    (max(0, y - 1)...min(totalHeight - 1, y + 1)).contains { ny in
                        grownSet[ny * totalWidth + nx]
                    }
                }
                guard touchesAccepted else { continue }
                var present: [Double] = []
                for match in votingMatches {
                    let pixelX = match.x + x - margin
                    let pixelY = match.y + y - margin
                    guard pixelX >= 0, pixelX < width, pixelY >= 0, pixelY < height else { continue }
                    let pixel = (pixelY * width + pixelX) * 4
                    guard source[pixel + 3] == 255 else { continue }
                    let channels = (0..<3).map { Int(source[pixel + $0]) }
                    guard channels.max()! - channels.min()! <= 10 else { continue }
                    let luminanceIndex = pixelY * width + pixelX
                    let localBackground = luminance[luminanceIndex] + contrast[luminanceIndex]
                    let difference = contrast[luminanceIndex]
                    if difference > 0, difference <= 96, localBackground >= 120 {
                        present.append(Double(difference) / Double(localBackground))
                    }
                }
                guard present.count >= required else { continue }
                let alpha = median(present)
                guard alpha <= bandHigh else { continue }
                opacity[index] = alpha
                accepted[index] = true
            }
        }
        let grownCount = accepted.indices.filter { accepted[$0] }.count
        guard grownCount > seedCount else { return nil }
        return assembleTemplate(fromOpacity: opacity, width: totalWidth, height: totalHeight, background: template.background)
    }

    private static func assembleTemplate(fromOpacity opacity: [Double], width: Int, height: Int, background: Int) -> Template? {
        let strokes = opacity.enumerated().filter { $0.element > 0 }
        guard strokes.count >= 8 else { return nil }
        let alphas = strokes.map(\.element).sorted()
        let robustPeak = alphas[min(alphas.count - 1, Int(Double(alphas.count) * 0.9))]
        // Strokes far stronger than the repeated overlay behave like content, not watermark.
        let pruned = strokes.filter { $0.element <= robustPeak * 2.5 }
        guard !pruned.isEmpty else { return nil }
        var minX = width
        var minY = height
        var maxX = -1
        var maxY = -1
        for (index, _) in pruned {
            let x = index % width
            let y = index / width
            minX = min(minX, x); maxX = max(maxX, x)
            minY = min(minY, y); maxY = max(maxY, y)
        }
        let templateWidth = maxX - minX + 1
        let templateHeight = maxY - minY + 1
        var cropped = [Double](repeating: 0, count: templateWidth * templateHeight)
        var features: [(x: Int, y: Int, contrast: Int)] = []
        let peak = pruned.map(\.element).max() ?? 0
        for (index, alpha) in pruned {
            let x = index % width - minX
            let y = index / width - minY
            cropped[y * templateWidth + x] = alpha
            if alpha >= max(peak * 0.4, 3.0 / 255) {
                features.append((x, y, max(2, Int((alpha * Double(background)).rounded()))))
            }
        }
        guard features.count >= 8 else { return nil }
        // A real glyph spreads its strokes over most of its height. A template built
        // from misaligned boxes can collapse onto a horizontal structure (a rule
        // line, a band edge) that would then match every text row in the image.
        let rowsWithStrokes = (0..<templateHeight).filter { row in
            (0..<templateWidth).contains { column in cropped[row * templateWidth + column] > 0 }
        }.count
        guard Double(rowsWithStrokes) >= 0.5 * Double(templateHeight) else { return nil }
        let sampled = stride(from: 0, to: features.count, by: max(1, features.count / 64)).map { features[$0] }
        return Template(width: templateWidth, height: templateHeight, opacity: cropped,
                        features: sampled, peak: peak, background: background)
    }

    private static func dropIsolatedPixels(_ opacity: inout [Double], width: Int, height: Int) {
        var kept = [Bool](repeating: false, count: opacity.count)
        for index in opacity.indices where opacity[index] > 0 {
            let x = index % width
            let y = index / width
            let hasNeighbor = (max(0, x - 1)...min(width - 1, x + 1)).contains { nx in
                (max(0, y - 1)...min(height - 1, y + 1)).contains { ny in
                    (nx != x || ny != y) && opacity[ny * width + nx] > 0
                }
            }
            kept[index] = hasNeighbor
        }
        for index in opacity.indices where !kept[index] {
            opacity[index] = 0
        }
    }

    private static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        return sorted[sorted.count / 2]
    }

    private static func findMatches(template: Template, source: [UInt8], contrast: [Int], width: Int, height: Int) throws -> [Match] {
        guard template.width <= width, template.height <= height else { return [] }
        func score(x: Int, y: Int, minimumMatchRatio: Double = 0.65, occlusionTolerant: Bool = false) -> Double {
            var matched = 0
            var visible = 0
            var difference = 0.0
            for feature in template.features {
                guard x + feature.x >= 0, x + feature.x < width,
                      y + feature.y >= 0, y + feature.y < height else { continue }
                let index = (y + feature.y) * width + x + feature.x
                let value = contrast[index]
                let pixel = index * 4
                let low = min(source[pixel], source[pixel + 1], source[pixel + 2])
                let high = max(source[pixel], source[pixel + 1], source[pixel + 2])
                if low < 60 || high - low >= 60 {
                    // Saturated or very dark content (photos, avatars) covers the
                    // watermark. At lattice-predicted positions it occludes strokes
                    // rather than disproving them, so it abstains from the ratio;
                    // plain background keeps failing the match as before.
                    guard occlusionTolerant else {
                        visible += 1
                        difference += 1
                        continue
                    }
                    continue
                }
                visible += 1
                if low >= 120, high - low < 30,
                   value >= max(1, feature.contrast / 3), value <= feature.contrast * 2 + 3 {
                    matched += 1
                    difference += min(1, Double(abs(value - feature.contrast)) / Double(max(3, feature.contrast)))
                } else {
                    difference += 1
                }
                if visible == 16, matched < 5 { return 0 }
            }
            guard visible >= 8,
                  Double(matched) / Double(visible) >= minimumMatchRatio else { return 0 }
            return 1 - difference / Double(visible)
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
        // Confirmed edge matches provide the second neighbor needed by clipped corners.
        // Both passes use offsets learned exclusively from the original full matches.
        for _ in 0..<2 {
            var predictions: [(x: Int, y: Int, neighbors: Set<Int>)] = []
            for (index, match) in matches.enumerated() {
                for offset in repeatedOffsets {
                    for sign in [-1.0, 1.0] {
                        let x = match.x + Int((offset.x * sign).rounded())
                        let y = match.y + Int((offset.y * sign).rounded())
                        guard x + template.width > 0, x < width, y + template.height > 0, y < height,
                              !matches.contains(where: { abs($0.x - x) < template.width / 2 + 1 && abs($0.y - y) < template.height / 2 + 1 }) else { continue }
                        if let prediction = predictions.firstIndex(where: { abs($0.x - x) <= 4 && abs($0.y - y) <= 4 }) {
                            predictions[prediction].neighbors.insert(index)
                        } else {
                            predictions.append((x, y, [index]))
                        }
                    }
                }
            }
            let previousCount = matches.count
            for prediction in predictions where prediction.neighbors.count >= 2 {
                try Task.checkCancellation()
                var best = Match(x: prediction.x, y: prediction.y, score: 0)
                let clipped = prediction.x < 0 || prediction.y < 0
                    || prediction.x + template.width > width || prediction.y + template.height > height
                for y in max(1 - template.height, prediction.y - 3)...min(height - 1, prediction.y + 3) {
                    for x in max(1 - template.width, prediction.x - 3)...min(width - 1, prediction.x + 3) {
                        // Predicted positions are lattice-confirmed; content covering
                        // them occludes strokes instead of disproving the match.
                        let value = score(x: x, y: y, minimumMatchRatio: clipped ? 0.65 : 0.4, occlusionTolerant: true)
                        if value > best.score { best = Match(x: x, y: y, score: value) }
                    }
                }
                if best.score >= (clipped ? 0.5 : 0.3),
                   !matches.contains(where: { abs($0.x - best.x) < template.width / 2 + 1 && abs($0.y - best.y) < template.height / 2 + 1 }) {
                    matches.append(best)
                }
            }
            if matches.count == previousCount { break }
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
                guard pixelX >= 0, pixelX < width, pixelY >= 0, pixelY < height else { continue }
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
                    // A pair from across a content edge (blue bar against white paper)
                    // reports a background this pixel never sat on; its red channel
                    // would demand a shift larger than any overlay can produce.
                    let plausible = changes.max()! <= template.peak * 255 + 3 && changes.min()! >= -(template.peak * 255 + 6)
                    // Three signatures accept an interpolation: an even gray shift in
                    // either direction — darker (the stroke over a light background) or
                    // brighter (the leftover of a light overlay whose consensus alpha
                    // missed this edge pixel) — or a per-channel proportional shift
                    // changes = source * alpha/(1-alpha) over uniform color.
                    let evenly = plausible && changes.max()! - changes.min()! <= 8
                    var proportionally = false
                    if plausible, alpha > 0, changes.min()! >= 0 {
                        let factor = alpha / (1 - alpha)
                        proportionally = (0..<3).allSatisfy { channel in
                            let expected = Double(source[index + channel]) * factor
                            return abs(changes[channel] - expected) <= 2.5
                        }
                    }
                    if evenly || proportionally {
                        for channel in 0..<3 { output[index + channel] = UInt8(min(255, background[channel].rounded())) }
                        continue
                    }
                    // Measure this pixel's own overlay per channel. Over colored
                    // content the three channels agree only pairwise with their own
                    // background level, so a single gray alpha cannot express them.
                    if plausible, changes.min()! >= 0 {
                        let measuredRatios = (0..<3).compactMap { channel -> Double? in
                            let denominator = background[channel]
                            guard denominator >= 30 else { return nil }
                            let change = background[channel] - Double(source[index + channel])
                            guard change > 0 else { return nil }
                            return change / denominator
                        }
                        if measuredRatios.count >= 2,
                           measuredRatios.max()! - measuredRatios.min()! <= 0.04,
                           let measured = measuredRatios.sorted()[measuredRatios.count / 2] as Double?,
                           measured > 0, measured <= template.peak * 2 + 0.02 {
                            for channel in 0..<3 {
                                output[index + channel] = UInt8(min(255, (Double(source[index + channel]) / (1 - measured)).rounded()))
                            }
                            continue
                        }
                        if measuredRatios.count >= 2, measuredRatios.min()! >= 0 {
                            // Per-channel restore: channels where the overlay saturates the
                            // source (ratio near one) fall back to the background itself.
                            for channel in 0..<3 {
                                let denominator = background[channel]
                                let ratio = denominator >= 1 ? (denominator - Double(source[index + channel])) / denominator : 0
                                if ratio >= 0.99 {
                                    output[index + channel] = UInt8(min(255, background[channel].rounded()))
                                } else if ratio > 0 {
                                    output[index + channel] = UInt8(min(255, (Double(source[index + channel]) / (1 - ratio)).rounded()))
                                } else {
                                    output[index + channel] = UInt8(min(255, background[channel].rounded()))
                                }
                            }
                            continue
                        }
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
