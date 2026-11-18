import Foundation
import Testing
@testable import devkit

struct LotteryRedPoolTests {
    @Test func conditionalBaselineCountsOnlyEligibleTickets() {
        let expected = (0...2).map { choose(6, $0) * choose(27, 6 - $0) }
        #expect(LotteryRedPool.overlapCounts(referenceSize: 6, sharedWithLatest: 6) == expected + [0, 0, 0, 0])
        let total = expected.reduce(0, +)
        for size in [6, 17] {
            for shared in 0...6 {
                #expect(LotteryRedPool.overlapCounts(referenceSize: size, sharedWithLatest: shared).reduce(0, +) == total)
            }
        }
    }
    @Test func samplesValidCombinationsForDifferentReferences() {
        let latest = Array(1...6)
        for reference in [latest, Array(4...9), Array(7...12)] {
            let pool = LotteryRedPool(latest: latest, reference: reference, scores: [1, 2, 3, 4, 5, 6, 7])
            var generator = RedPoolGenerator()
            for _ in 0..<500 {
                for highest in [false, true] {
                    let result = pool.pick(highestScore: highest, using: &generator)
                    #expect(result.count == 6)
                    #expect(result == Set(result).sorted())
                    #expect(result.allSatisfy { (1...33).contains($0) })
                    #expect(Set(result).intersection(latest).count <= 2)
                    if highest {
                        let maximumOverlap = reference == latest ? 2 : (reference == Array(4...9) ? 5 : 6)
                        #expect(Set(result).intersection(reference).count == maximumOverlap)
                    }
                }
            }
        }
    }

    @Test func uniformWeightsSampleCombinationsRatherThanAllocations() {
        let latest = Array(1...6)
        let reference = Array(7...12)
        let pool = LotteryRedPool(latest: latest, reference: reference, scores: Array(repeating: 1, count: 7))
        var generator = RedPoolGenerator()
        var counts = Array(repeating: 0, count: 7)
        let samples = 20_000
        for _ in 0..<samples {
            let result = pool.pick(highestScore: false, using: &generator)
            counts[Set(result).intersection(reference).count] += 1
        }
        let expected = (0...6).map { overlap in
            (0...2).reduce(0) { total, latestCount in
                let otherCount = 6 - overlap - latestCount
                guard (0...21).contains(otherCount) else { return total }
                return total + choose(6, overlap) * choose(6, latestCount) * choose(21, otherCount)
            }
        }
        let total = Double(expected.reduce(0, +))
        for overlap in 0...6 {
            let probability = Double(expected[overlap]) / total
            let observed = Double(counts[overlap]) / Double(samples)
            #expect(abs(observed - probability) < 0.015)
        }
    }

    @Test func highestScoreAllowsRepeatedUniqueCombination() {
        let reference = Array(7...12)
        let pool = LotteryRedPool(latest: Array(1...6), reference: reference, scores: [1, 1, 1, 1, 1, 1, 10])
        var generator = RedPoolGenerator()
        for _ in 0..<20 {
            #expect(pool.pick(highestScore: true, using: &generator) == reference)
        }
    }

    @Test func supportsOddNumberReference() {
        let latest = Array(1...6)
        let odds = Array(stride(from: 1, through: 33, by: 2))
        let pool = LotteryRedPool(latest: latest, reference: odds, scores: [1, 1, 1, 1, 1, 1, 10])
        var generator = RedPoolGenerator()
        for _ in 0..<500 {
            let result = pool.pick(highestScore: false, using: &generator)
            #expect(result.count == 6)
            #expect(Set(result).intersection(latest).count <= 2)
            let best = pool.pick(highestScore: true, using: &generator)
            #expect(best.allSatisfy { $0 % 2 == 1 })
            #expect(Set(best).intersection(latest).count <= 2)
        }
    }

    private func choose(_ pool: Int, _ count: Int) -> Int {
        guard count <= pool else { return 0 }
        return (0..<count).reduce(1) { $0 * (pool - $1) / ($1 + 1) }
    }
}

private struct RedPoolGenerator: RandomNumberGenerator {
    private var state: UInt64 = 42

    mutating func next() -> UInt64 {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return state
    }
}
