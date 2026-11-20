import Foundation

enum LotteryPrize: String, CaseIterable {
    case first = "一等奖"
    case second = "二等奖"
    case third = "三等奖"
    case fourth = "四等奖"
    case fifth = "五等奖"
    case sixth = "六等奖"
    case goodFortune = "福运奖"

    var fixedAmount: Decimal? {
        switch self {
        case .first, .second: nil
        case .third: 3_000
        case .fourth: 200
        case .fifth: 10
        case .sixth, .goodFortune: 5
        }
    }

    static func matching(red: Int, blue: Bool, goodFortune: Bool) -> Self? {
        switch (red, blue) {
        case (6, true): .first
        case (6, false): .second
        case (5, true): .third
        case (5, false), (4, true): .fourth
        case (4, false), (3, true): .fifth
        case (0...2, true): .sixth
        case (3, false) where goodFortune: .goodFortune
        default: nil
        }
    }
}

struct LotteryTicketResult {
    let redHits: Int
    let blueHit: Bool
    let prize: LotteryPrize?
    let amount: Decimal?
    let promotion: Decimal?

    init(selection: LotterySelection, draw: LotteryDraw, announcement: LotteryPrizeAnnouncement?) {
        redHits = Set(selection.redNumbers).intersection(draw.redNumbers).count
        blueHit = selection.blueNumber == draw.blueNumber
        prize = LotteryPrize.matching(red: redHits, blue: blueHit, goodFortune: announcement?.includesGoodFortune == true)
        amount = prize.flatMap { announcement?.amounts[$0] ?? $0.fixedAmount }
        promotion = prize.flatMap { announcement?.promotions[$0] }
    }
}

struct LotteryPrizeSummary {
    let winnerCount: Int
    let promotions: Decimal
    let total: Decimal
    let hasPendingAmount: Bool

    init(results: [LotteryTicketResult]) {
        let winners = results.filter { $0.prize != nil }
        winnerCount = winners.count
        promotions = winners.compactMap(\.promotion).reduce(0, +)
        total = winners.compactMap(\.amount).reduce(0, +) + promotions
        hasPendingAmount = winners.contains { $0.amount == nil }
    }
}

struct LotteryPrizeAnnouncement {
    let amounts: [LotteryPrize: Decimal]
    let includesGoodFortune: Bool
    let promotions: [LotteryPrize: Decimal]
    let hasOtherPromotions: Bool

    static func sourceURL(for issue: String) -> URL {
        URL(string: "https://www.gxcaipiao.com.cn/notice/detail/ssq/\(issue).html")!
    }

    static func fetch(for draw: LotteryDraw) async throws -> Self {
        var request = URLRequest(url: sourceURL(for: draw.issue))
        request.timeoutInterval = 20
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let html = String(data: data, encoding: .utf8) else { throw URLError(.badServerResponse) }
        return try parse(html, for: draw)
    }

    static func parse(_ html: String, for draw: LotteryDraw) throws -> Self {
        guard let issue = html.firstMatch(of: #/<h1>[^<]*第\s*([0-9]{7})\s*期开奖公告/#)?.1,
              issue == draw.issue,
              html.contains("datetime=\"\(draw.date)\""),
              let balls = html.firstMatch(of: #/<div class="balls balls-ssq"[^>]*>([\s\S]*?)</div>/#)?.1,
              balls.matches(of: #/<span class="ball red">([0-9]{1,2})</span>/#).compactMap({ Int($0.1) }).sorted() == draw.redNumbers,
              balls.matches(of: #/<span class="ball blue">([0-9]{1,2})</span>/#).compactMap({ Int($0.1) }) == [draw.blueNumber],
              let table = html.firstMatch(of: #/<table class="lottery-table"[^>]*>([\s\S]*?)</table>/#)?.1 else {
            throw URLError(.cannotParseResponse)
        }

        var amounts: [LotteryPrize: Decimal] = [:]
        var seen = Set<LotteryPrize>()
        var promotions: [LotteryPrize: Decimal] = [:]
        var hasOtherPromotions = false
        for row in table.matches(of: #/<tr\b[^>]*>([\s\S]*?)</tr>/#) {
            let cells = row.1.matches(of: #/<td\b[^>]*>([\s\S]*?)</td>/#)
                .map { $0.1.trimmingCharacters(in: .whitespacesAndNewlines) }
            guard cells.count >= 3 else { continue }
            let title = cells[0]
            let money = cells[2].replacingOccurrences(of: ",", with: "")
            let amount = money.wholeMatch(of: #/[0-9]+(?:\.[0-9]{1,2})?/#) == nil
                ? nil : Decimal(string: money, locale: Locale(identifier: "en_US_POSIX"))
            if let prize = LotteryPrize(rawValue: title) {
                guard seen.insert(prize).inserted else { throw URLError(.cannotParseResponse) }
                if let amount, amount > 0 { amounts[prize] = amount }
            } else if draw.issue.hasPrefix("2026"), draw.issue >= "2026128", let amount, amount > 0 {
                switch title {
                case "二等奖特别奖": promotions[.second] = amount
                case "六等奖翻番奖": promotions[.sixth] = amount
                default: hasOtherPromotions = true
                }
            } else {
                hasOtherPromotions = true
            }
        }
        guard LotteryPrize.allCases.dropLast().allSatisfy(seen.contains) else {
            throw URLError(.cannotParseResponse)
        }
        return Self(amounts: amounts, includesGoodFortune: seen.contains(.goodFortune),
                    promotions: promotions, hasOtherPromotions: hasOtherPromotions)
    }
}
