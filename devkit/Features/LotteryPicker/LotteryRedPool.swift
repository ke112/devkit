import Foundation

struct LotteryRedPool {
    private struct Allocation {
        let counts: [Int]
        let combinations: Int
        let overlap: Int
    }

    private let groups: [[Int]]
    private let scores: [Double]
    private let allocations: [Allocation]

    init(latest: [Int], reference: [Int], scores: [Double]) {
        precondition(latest.count == 6 && Set(latest).count == 6 && latest.allSatisfy { (1...33).contains($0) })
        precondition(Set(reference).count == reference.count && reference.allSatisfy { (1...33).contains($0) })
        precondition(scores.count == 7 && scores.allSatisfy { $0.isFinite && $0 > 0 })

        let latestSet = Set(latest)
        let referenceSet = Set(reference)
        let numbers = Array(1...33)
        let groups = [
            numbers.filter { latestSet.contains($0) && referenceSet.contains($0) },
            numbers.filter { latestSet.contains($0) && !referenceSet.contains($0) },
            numbers.filter { !latestSet.contains($0) && referenceSet.contains($0) },
            numbers.filter { !latestSet.contains($0) && !referenceSet.contains($0) }
        ]
        self.groups = groups
        self.scores = scores

        var allocations: [Allocation] = []
        for both in 0...min(2, groups[0].count) {
            for latestOnly in 0...min(2 - both, groups[1].count) {
                for referenceOnly in 0...min(6 - both - latestOnly, groups[2].count) {
                    let neither = 6 - both - latestOnly - referenceOnly
                    guard neither <= groups[3].count else { continue }
                    let counts = [both, latestOnly, referenceOnly, neither]
                    let combinations = zip(groups, counts).reduce(1) {
                        $0 * Self.choose($1.0.count, $1.1)
                    }
                    allocations.append(Allocation(counts: counts, combinations: combinations, overlap: both + referenceOnly))
                }
            }
        }
        self.allocations = allocations
    }

    func pick(highestScore: Bool, using generator: inout some RandomNumberGenerator) -> [Int] {
        let maximum = allocations.map { scores[$0.overlap] }.max()!
        let weights = allocations.map { allocation in
            let score = scores[allocation.overlap]
            if highestScore {
                return score == maximum ? Double(allocation.combinations) : 0
            }
            return Double(allocation.combinations) * (score / maximum)
        }
        var threshold = Double.random(in: 0..<weights.reduce(0, +), using: &generator)
        var selected = allocations[weights.lastIndex(where: { $0 > 0 })!]
        for (allocation, weight) in zip(allocations, weights) {
            if threshold < weight {
                selected = allocation
                break
            }
            threshold -= weight
        }
        return zip(groups, selected.counts).flatMap { group, count in
            group.shuffled(using: &generator).prefix(count)
        }.sorted()
    }

    private static func choose(_ pool: Int, _ count: Int) -> Int {
        (0..<count).reduce(1) { result, index in
            result * (pool - index) / (index + 1)
        }
    }
}
