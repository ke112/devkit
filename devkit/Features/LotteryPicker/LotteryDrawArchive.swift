import Foundation

struct LotteryDrawArchive {
    static let firstIssue = 2003001
    static let lastIssue = 2019151
    static let sourceURL = URL(string: "https://datachart.500.com/ssq/history/newinc/history.php?start=03001&end=19151")!
    static let bundled = Result {
        guard let url = Bundle.main.url(forResource: "ssq-2003-2019", withExtension: "csv") else {
            throw LotteryHistoryError.incompleteHistory
        }
        return try Self(contents: String(contentsOf: url, encoding: .utf8))
    }

    let draws: [LotteryDraw]
    private let prizes: [String: [LotteryPrize: Decimal]]

    private init(contents: String) throws {
        var draws: [LotteryDraw] = []
        var prizes: [String: [LotteryPrize: Decimal]] = [:]
        for line in contents.split(whereSeparator: \.isNewline) {
            let fields = line.split(separator: ",", omittingEmptySubsequences: false)
            guard fields.count == 11, let blue = Int(fields[8]),
                  let first = Int(fields[9]), first >= 0, let second = Int(fields[10]), second >= 0 else {
                throw LotteryHistoryError.incompleteHistory
            }
            let issue = String(fields[0])
            draws.append(LotteryDraw(issue: issue, date: String(fields[1]),
                                     redNumbers: fields[2...7].compactMap { Int($0) }, blueNumber: blue))
            var amounts: [LotteryPrize: Decimal] = [:]
            if first > 0 { amounts[.first] = Decimal(first) }
            if second > 0 { amounts[.second] = Decimal(second) }
            prizes[issue] = amounts
        }
        guard draws.count == 2510, prizes.count == draws.count else { throw LotteryHistoryError.incompleteHistory }
        try LotteryHistoryService.validate(draws, start: Self.firstIssue, end: Self.lastIssue)
        self.draws = draws
        self.prizes = prizes
    }

    func joining(_ live: [LotteryDraw]) -> [LotteryDraw] {
        draws + live
    }

    func regularPrizes(for draw: LotteryDraw) -> LotteryPrizeAnnouncement? {
        guard let amounts = prizes[draw.issue], draws.first(where: { $0.issue == draw.issue }) == draw else { return nil }
        return LotteryPrizeAnnouncement(amounts: amounts, includesGoodFortune: false, promotions: [:],
                                        hasOtherPromotions: true, fromArchive: true)
    }
}
