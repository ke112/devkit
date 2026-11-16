import Foundation

struct LotterySelection: Equatable {
    let redNumbers: [Int]
    let blueNumber: Int

    private init(redNumbers: [Int], blueNumber: Int) {
        self.redNumbers = redNumbers
        self.blueNumber = blueNumber
    }

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
