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
    enum SelectionMode {
        case highestScore
        case sample
    }

    private static func overlapBaseline(poolSize: Int) -> [Double] {
        (0...6).map { overlap in
            Double(combinations(poolSize, choosing: overlap) * combinations(33 - poolSize, choosing: 6 - overlap))
                / Double(combinations(33, choosing: 6))
        }
    }
    private static let oddNumbers = Array(stride(from: 1, through: 33, by: 2))
    private static let blueBaseline = Array(repeating: 1.0 / 16, count: 16)
    private static let warmup = 30
    private static let maximumLag = 3
    private static let repeatBaselines = eligibleBaselines(referenceSize: 6)
    private static let oddBaselines = eligibleBaselines(referenceSize: oddNumbers.count)

    private static func eligibleBaselines(referenceSize: Int) -> [[Double]] {
        (0...6).map { shared in
            let counts = LotteryRedPool.overlapCounts(referenceSize: referenceSize, sharedWithLatest: shared)
            let total = Double(counts.reduce(0, +))
            return counts.map { Double($0) / total }
        }
    }

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

        @discardableResult
        mutating func observe(_ outcome: Int, score: Bool, eligibleBaseline: [Double]? = nil) -> Double {
            var gain = 0.0
            if score {
                let normalization = eligibleBaseline.map { distribution in
                    distribution.indices.reduce(0.0) { $0 + distribution[$1] * ratio(for: $1) }
                } ?? 1
                gain = log(ratio(for: outcome) / normalization)
                logEvidence += gain
            }
            counts[outcome] += 1
            total += 1
            return gain
        }
    }

    private var reds = Array(repeating: Pattern(baseline: overlapBaseline(poolSize: 6)), count: maximumLag)
        + [Pattern(baseline: overlapBaseline(poolSize: oddNumbers.count))]
    private var blues = Array(repeating: Pattern(baseline: blueBaseline), count: maximumLag)
        + [Pattern(baseline: [0.5, 0.5])]
    private var recent: [LotteryDraw] = []
    private var redPool: LotteryRedPool?
    private(set) var evaluated = 0
    private(set) var covered = 0
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
            let latest = recent.first
            let eligible = scoring && latest.map { draw.redNumbers.filter($0.redNumbers.contains).count <= 2 } == true
            if eligible { covered += 1 }
            for offset in recent.indices {
                let previous = recent[offset]
                let overlap = draw.redNumbers.filter(previous.redNumbers.contains).count
                let shift = (draw.blueNumber - previous.blueNumber + 16) % 16
                let shared = recent[0].redNumbers.filter(previous.redNumbers.contains).count
                let redGain = reds[offset].observe(overlap, score: eligible, eligibleBaseline: Self.repeatBaselines[shared])
                let blueGain = blues[offset].observe(shift, score: scoring)
                if offset == redModel { logGain += redGain }
                if eligible && offset == blueModel { logGain += blueGain }
            }
            let oddCount = draw.redNumbers.filter { !$0.isMultiple(of: 2) }.count
            let previousOddCount = latest?.redNumbers.filter { !$0.isMultiple(of: 2) }.count ?? 0
            let oddGain = reds[Self.maximumLag].observe(oddCount, score: eligible, eligibleBaseline: Self.oddBaselines[previousOddCount])
            if redModel == Self.maximumLag { logGain += oddGain }
            if let latest {
                let changedHalf = (draw.blueNumber > 8) != (latest.blueNumber > 8) ? 1 : 0
                let halfGain = blues[Self.maximumLag].observe(changedHalf, score: scoring)
                if eligible && blueModel == Self.maximumLag { logGain += halfGain }
            }
            if scoring { evaluated += 1 }
            recent.insert(draw, at: 0)
            if recent.count > Self.maximumLag { recent.removeLast() }
        }
        if let latest = recent.first {
            let active = Self.active(reds)
            let reference = active.map { $0 == Self.maximumLag ? Self.oddNumbers : recent[$0].redNumbers }
            let scores = (0...6).map { outcome in active.map { reds[$0].ratio(for: outcome) } ?? 1 }
            redPool = LotteryRedPool(latest: latest.redNumbers, reference: reference ?? latest.redNumbers, scores: scores)
        }
    }

    var summary: String {
        let red = Self.active(reds).map { $0 == Self.maximumLag ? "红球参考奇偶个数" : "红球参考前 \($0 + 1) 期的重号个数" }
        let blue = Self.active(blues).map { $0 == Self.maximumLag ? "蓝球参考与上期的大小区切换" : "蓝球参考前 \($0 + 1) 期的循环位移" }
        guard evaluated > 0 else { return "正在积累回测样本，按选号规则均匀生成。" }
        guard red != nil || blue != nil else {
            return "红球重号、奇偶个数及蓝球位移、大小区切换均未达启用门槛，按选号规则均匀生成。"
        }
        return [red ?? "红球均匀抽取", blue ?? "蓝球均匀抽取"].joined(separator: "，")
            + "。首注选模型评分最高的组合，并列时随机选取；追加注按模型概率抽取。"
    }

    func next(mode: SelectionMode = .sample) -> LotterySelection {
        var generator = SystemRandomNumberGenerator()
        return next(mode: mode, using: &generator)
    }

    func next(mode: SelectionMode = .sample, using generator: inout some RandomNumberGenerator) -> LotterySelection {
        guard let redPool else { return LotterySelection.random(using: &generator) }
        let numbers = redPool.pick(highestScore: mode == .highestScore, using: &generator)
        let blue: Int
        if let offset = Self.active(blues) {
            let value = outcome(for: blues[offset], mode: mode, using: &generator)
            if offset == Self.maximumLag {
                let high = (recent[0].blueNumber > 8) != (value == 1)
                blue = Int.random(in: high ? 9...16 : 1...8, using: &generator)
            } else {
                blue = (recent[offset].blueNumber - 1 + value) % 16 + 1
            }
        } else {
            blue = Int.random(in: 1...16, using: &generator)
        }
        return LotterySelection(redNumbers: numbers.sorted(), blueNumber: blue)
    }

    private func outcome(for pattern: Pattern, mode: SelectionMode, using generator: inout some RandomNumberGenerator) -> Int {
        if mode == .highestScore {
            let scores = pattern.counts.indices.map { pattern.ratio(for: $0) }
            let best = scores.max()!
            let tied = scores.indices.filter { scores[$0] == best }
            var offset = Double.random(in: 0..<tied.reduce(0) { $0 + pattern.baseline[$1] }, using: &generator)
            for index in tied {
                if offset < pattern.baseline[index] { return index }
                offset -= pattern.baseline[index]
            }
            return tied[tied.count - 1]
        }
        var offset = Double.random(in: 0..<pattern.total, using: &generator)
        for (index, weight) in pattern.counts.enumerated() {
            if offset < weight { return index }
            offset -= weight
        }
        return pattern.counts.count - 1
    }
}
