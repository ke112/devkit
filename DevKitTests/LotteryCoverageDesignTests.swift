import Testing
@testable import devkit

struct LotteryCoverageDesignTests {
    @Test func tenLinesCoverAllLabelsInFrequencyOrder() {
        let lines = LotteryCoverageDesign.redLines
        #expect(lines.count == 10)
        let frequencies = Dictionary(grouping: lines.flatMap { $0 }, by: { $0 }).mapValues(\.count)
        #expect(Set(frequencies.keys) == Set(0..<33))
        #expect((0..<27).allSatisfy { frequencies[$0] == 2 })
        #expect((27..<33).allSatisfy { frequencies[$0] == 1 })

        for (index, line) in lines.enumerated() {
            let labels = Set(line)
            #expect(line.count == 6)
            #expect(labels.count == 6)
            for other in lines.dropFirst(index + 1) {
                #expect(labels.intersection(other).count <= 1)
            }
        }
    }

    @Test func threeOrMoreRedHitsCover566491Draws() {
        let lines = LotteryCoverageDesign.redLines.map { Set($0) }
        var sharedPairs = 0
        var triangles = 0
        var fourCliques = 0
        for first in lines.indices {
            for second in lines.indices where second > first && !lines[first].isDisjoint(with: lines[second]) {
                sharedPairs += 1
                let common = lines.indices.filter {
                    $0 > second && !lines[first].isDisjoint(with: lines[$0]) && !lines[second].isDisjoint(with: lines[$0])
                }
                triangles += common.count
                for (index, third) in common.enumerated() {
                    fourCliques += common.dropFirst(index + 1).filter { !lines[third].isDisjoint(with: lines[$0]) }.count
                }
            }
        }

        let pairs = lines.count * (lines.count - 1) / 2
        let singleCoverage = lines.count * 63_928
        let pairOverlap = sharedPairs * 2_500 + (pairs - sharedPairs) * 400
        let covered = singleCoverage - pairOverlap + triangles * 64 - fourCliques
        #expect(covered == LotteryCoverageDesign.redOutcomesWithThreeOrMoreHits)
    }
}
