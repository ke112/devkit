import Foundation
import Testing
@testable import devkit

struct LotterySelectionTests {
    @Test func generatedSelectionsRespectNumberPoolsAndReachTheirBoundaries() {
        var generator = SeededGenerator()
        var seenReds = Set<Int>()
        var seenBlues = Set<Int>()

        for _ in 0..<1_000 {
            let selection = LotterySelection.random(using: &generator)
            #expect(selection.redNumbers.count == 6)
            #expect(Set(selection.redNumbers).count == 6)
            #expect(selection.redNumbers.allSatisfy { (1...33).contains($0) })
            #expect((1...16).contains(selection.blueNumber))
            #expect(selection.redNumbers == selection.redNumbers.sorted())
            seenReds.formUnion(selection.redNumbers)
            seenBlues.insert(selection.blueNumber)
        }

        #expect(seenReds == Set(1...33))
        #expect(seenBlues == Set(1...16))
    }

    @Test func copiedNumbersKeepLeadingZerosAndSeparateTheBlueBall() {
        var generator = SeededGenerator()
        let selection = LotterySelection.random(using: &generator)
        let groups = selection.formattedNumbers.components(separatedBy: " + ")
        #expect(groups.count == 2)
        #expect(groups[0].split(separator: " ").map { Int($0) } == selection.redNumbers.map(Optional.some))
        #expect(Int(groups[1]) == selection.blueNumber)
        #expect(LotterySelection.formatted(1) == "01")
        #expect(LotterySelection.formatted(9) == "09")
        #expect(LotterySelection.formatted(33) == "33")
    }
}

private struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64 = 42

    mutating func next() -> UInt64 {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return state
    }
}
