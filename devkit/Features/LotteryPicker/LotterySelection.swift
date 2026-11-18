import Foundation

struct LotterySelection: Equatable {
    let redNumbers: [Int]
    let blueNumber: Int

    static func random() -> Self {
        var generator = SystemRandomNumberGenerator()
        return random(using: &generator)
    }

    static func random(using generator: inout some RandomNumberGenerator) -> Self {
        // 从完整号码池无放回抽取，排序只用于展示，不改变组合概率。
        let reds = (1...33).shuffled(using: &generator).prefix(6).sorted()
        return Self(redNumbers: reds, blueNumber: Int.random(in: 1...16, using: &generator))
    }

    var formattedNumbers: String {
        redNumbers.map(Self.formatted).joined(separator: " ")
            + " + " + Self.formatted(blueNumber)
    }

    static func formatted(_ number: Int) -> String {
        String(format: "%02d", number)
    }
}

struct LotteryForecast {
    private static let redBaseline = (0...6).map { overlap in
        Double(combinations(6, choosing: overlap) * combinations(27, choosing: 6 - overlap))
            / Double(combinations(33, choosing: 6))
    }
    private static let blueBaseline = Array(repeating: 1.0 / 16, count: 16)
    private static let warmup = 30
    private static let maximumLag = 3

    private static func combinations(_ pool: Int, choosing count: Int) -> Int {
        (0..<count).reduce(1) { result, index in result * (pool - index) / (index + 1) }
    }

    private struct Pattern {
        let baseline: [Double]
        var counts: [Double]
        var total = 32.0
        var logEvidence = 0.0

        init(baseline: [Double]) {
            self.baseline = baseline
            counts = baseline.map { $0 * 32 }
        }

        func ratio(for outcome: Int) -> Double {
            counts[outcome] / (total * baseline[outcome])
        }

        mutating func observe(_ outcome: Int, score: Bool) {
            if score { logEvidence += log(ratio(for: outcome)) }
            counts[outcome] += 1
            total += 1
        }
    }

    private var reds = Array(repeating: Pattern(baseline: redBaseline), count: maximumLag)
    private var blues = Array(repeating: Pattern(baseline: blueBaseline), count: maximumLag)
    private var recent: [LotteryDraw] = []
    private(set) var evaluated = 0
    private(set) var logGain = 0.0

    private static func active(_ patterns: [Pattern]) -> Int? {
        guard let best = patterns.indices.max(by: { patterns[$0].logEvidence < patterns[$1].logEvidence }),
              patterns[best].logEvidence >= log(30.0) else { return nil }
        return best
    }

    init(draws: [LotteryDraw]) {
        for (index, draw) in draws.sorted(by: { $0.issue < $1.issue }).enumerated() {
            let redModel = Self.active(reds)
            let blueModel = Self.active(blues)
            let scoring = index >= Self.warmup
            for offset in recent.indices {
                let previous = recent[offset]
                let overlap = draw.redNumbers.filter(previous.redNumbers.contains).count
                let shift = (draw.blueNumber - previous.blueNumber + 16) % 16
                if scoring {
                    if offset == redModel { logGain += log(reds[offset].ratio(for: overlap)) }
                    if offset == blueModel { logGain += log(blues[offset].ratio(for: shift)) }
                }
                reds[offset].observe(overlap, score: scoring)
                blues[offset].observe(shift, score: scoring)
            }
            if scoring { evaluated += 1 }
            recent.insert(draw, at: 0)
            if recent.count > Self.maximumLag { recent.removeLast() }
        }
    }

    var summary: String {
        let red = Self.active(reds).map { "红球参考前 \($0 + 1) 期的重号个数" }
        let blue = Self.active(blues).map { "蓝球参考前 \($0 + 1) 期的循环位移" }
        guard evaluated > 0 else { return "正在积累验证样本，当前按均匀概率生成。" }
        return [red ?? "红球未检出稳定重号规律", blue ?? "蓝球未检出稳定位移规律"].joined(separator: "，") + "。"
    }

    func next() -> LotterySelection {
        var generator = SystemRandomNumberGenerator()
        return next(using: &generator)
    }

    func next(using generator: inout some RandomNumberGenerator) -> LotterySelection {
        let numbers: [Int]
        if let offset = Self.active(reds) {
            let previous = recent[offset].redNumbers
            let others = (1...33).filter { !previous.contains($0) }
            let overlap = sample(reds[offset], using: &generator)
            numbers = Array(previous.shuffled(using: &generator).prefix(overlap))
                + others.shuffled(using: &generator).prefix(6 - overlap)
        } else {
            numbers = Array((1...33).shuffled(using: &generator).prefix(6))
        }
        let blue: Int
        if let offset = Self.active(blues) {
            let shift = sample(blues[offset], using: &generator)
            blue = (recent[offset].blueNumber - 1 + shift) % 16 + 1
        } else {
            blue = Int.random(in: 1...16, using: &generator)
        }
        return LotterySelection(redNumbers: numbers.sorted(), blueNumber: blue)
    }

    private func sample(_ pattern: Pattern, using generator: inout some RandomNumberGenerator) -> Int {
        var offset = Double.random(in: 0..<pattern.total, using: &generator)
        for (index, weight) in pattern.counts.enumerated() {
            if offset < weight { return index }
            offset -= weight
        }
        return pattern.counts.count - 1
    }
}
