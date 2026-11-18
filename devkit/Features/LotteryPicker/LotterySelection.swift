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
    private let redWeights: [Int]
    private let blueWeights: [Int]

    init(draws: [LotteryDraw]) {
        var reds = Array(repeating: 1, count: 33)
        var blues = Array(repeating: 1, count: 16)
        for draw in draws {
            for number in draw.redNumbers {
                reds[number - 1] += 1
            }
            blues[draw.blueNumber - 1] += 1
        }
        redWeights = reds
        blueWeights = blues
    }

    func next() -> LotterySelection {
        var generator = SystemRandomNumberGenerator()
        return next(using: &generator)
    }

    func next(using generator: inout some RandomNumberGenerator) -> LotterySelection {
        var available = redWeights
        var reds: [Int] = []
        for _ in 0..<6 {
            let index = weightedIndex(available, using: &generator)
            reds.append(index + 1)
            available[index] = 0
        }
        let blue = weightedIndex(blueWeights, using: &generator) + 1
        return LotterySelection(redNumbers: reds.sorted(), blueNumber: blue)
    }

    private func weightedIndex(_ weights: [Int], using generator: inout some RandomNumberGenerator) -> Int {
        var offset = Int.random(in: 0..<weights.reduce(0, +), using: &generator)
        for (index, weight) in weights.enumerated() {
            if offset < weight { return index }
            offset -= weight
        }
        preconditionFailure("号码池必须包含正权重")
    }
}
