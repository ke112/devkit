import Foundation

nonisolated enum LotteryPrize: String, CaseIterable, Sendable {
    case first = "一等奖"
    case second = "二等奖"
    case third = "三等奖"
    case fourth = "四等奖"
    case fifth = "五等奖"
    case sixth = "六等奖"
    case goodFortune = "福运奖"

    var isFourthOrBetter: Bool {
        switch self {
        case .first, .second, .third, .fourth: true
        case .fifth, .sixth, .goodFortune: false
        }
    }

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

    init(selection: LotterySelection, draw: LotteryDraw, announcement: LotteryPrizeAnnouncement?, ticketStake: Int) {
        redHits = Set(selection.redNumbers).intersection(draw.redNumbers).count
        blueHit = selection.blueNumber == draw.blueNumber
        prize = LotteryPrize.matching(red: redHits, blue: blueHit, goodFortune: announcement?.includesGoodFortune == true)
        amount = prize.flatMap { announcement?.amounts[$0] ?? $0.fixedAmount }
        promotion = ticketStake >= 20 ? prize.flatMap { announcement?.promotions[$0] } : nil
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
    nonisolated static let firstFortuneIssue = "2026014"

    let amounts: [LotteryPrize: Decimal]
    let includesGoodFortune: Bool
    let promotions: [LotteryPrize: Decimal]
    let hasOtherPromotions: Bool
    private(set) var fromArchive = false

    static func sourceURL(for issue: String) -> URL {
        URL(string: "https://www.gxcaipiao.com.cn/notice/detail/ssq/\(issue).html")!
    }

    static func fetch(for draw: LotteryDraw) async throws -> Self {
        do {
            let regional = try await fetchOfficial(for: draw)
            guard draw.issue >= firstFortuneIssue, !regional.includesGoodFortune else { return regional }
            let data = try await nationalData(from: draw.issue, through: draw.issue, limit: 1)
            return try regional.checkingGoodFortune(data, for: draw)
        } catch let error as URLError where error.code != .cannotParseResponse {
            try Task.checkCancellation()
            if let number = Int(draw.issue), number <= LotteryDrawArchive.lastIssue,
               let fallback = try LotteryDrawArchive.bundled.get().regularPrizes(for: draw) { return fallback }
            throw error
        }
    }

    @concurrent
    static func fortuneStatuses(for draws: [LotteryDraw]) async throws -> [String: Bool] {
        try await fortuneStatuses(for: draws) { first, last, limit in
            try await nationalData(from: first, through: last, limit: limit)
        }
    }

    @concurrent
    static func fortuneStatuses(for draws: [LotteryDraw],
                                load: @Sendable (String, String, Int) async throws -> Data) async throws -> [String: Bool] {
        try Task.checkCancellation()
        let requested = Dictionary(grouping: draws, by: \.issue).compactMapValues { copies in
            copies.allSatisfy { $0 == copies.first } ? copies.first : nil
        }
        var statuses = requested.filter { $0.key < firstFortuneIssue }.mapValues { _ in false }
        let eligible = requested.keys.filter { $0 >= firstFortuneIssue }.compactMap(Int.init).sorted()
        let limit = 100
        var remaining = eligible[...]
        while let first = remaining.first {
            try Task.checkCancellation()
            let batch = remaining.prefix { $0 - first < limit }
            guard let last = batch.last else { break }
            remaining = remaining.dropFirst(batch.count)
            do {
                let data = try await load(String(first), String(last), limit)
                let notice = try NationalNotice(data: data)
                var seen = Set<String>()
                for entry in notice.result {
                    guard let issue = entry.code, let number = Int(issue), (first...last).contains(number),
                          let draw = requested[issue] else { continue }
                    statuses[issue] = seen.insert(issue).inserted ? entry.fortuneStatus(for: draw) : nil
                }
            } catch {
                if error is CancellationError || (error as? URLError)?.code == .cancelled { throw error }
            }
        }
        try Task.checkCancellation()
        return statuses
    }

    private nonisolated static func nationalData(from first: String, through last: String, limit: Int) async throws -> Data {
        var components = URLComponents(string: "https://www.cwl.gov.cn/cwl_admin/front/cwlkj/search/kjxx/findDrawNotice")!
        components.queryItems = ["name": "ssq", "issueStart": first, "issueEnd": last,
                                 "pageNo": "1", "pageSize": String(limit), "systemType": "PC"].sorted { $0.key < $1.key }
            .map { URLQueryItem(name: $0.key, value: $0.value) }
        guard let url = components.url else { throw URLError(.badURL) }
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue("https://www.cwl.gov.cn/ygkj/wqkjgg/ssq/", forHTTPHeaderField: "Referer")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        return data
    }

    private nonisolated struct NationalNotice: Decodable {
        nonisolated struct Entry: Decodable {
            let code, date, red, blue, fyjMoney, fyjCount: String?

            private enum Keys: String, CodingKey { case code, date, red, blue, fyjMoney, fyjCount }

            init(from decoder: Decoder) throws {
                let fields = try? decoder.container(keyedBy: Keys.self)
                func text(_ key: Keys) -> String? {
                    if let value = try? fields?.decode(String.self, forKey: key) { return value }
                    return (try? fields?.decode(Int.self, forKey: key)).map(String.init)
                }
                code = text(.code)
                date = text(.date)
                red = text(.red)
                blue = text(.blue)
                fyjMoney = text(.fyjMoney)
                fyjCount = text(.fyjCount)
            }

            func fortuneStatus(for draw: LotteryDraw) -> Bool? {
                guard code == draw.issue, let date, date.prefix(10) == draw.date,
                      let red, red.components(separatedBy: ",").map({ Int($0) }) == draw.redNumbers.map(Optional.some),
                      let blue, Int(blue) == draw.blueNumber, let fyjMoney, let fyjCount else { return nil }
                if fyjMoney.isEmpty && fyjCount.isEmpty { return false }
                guard let count = Int(fyjCount), count >= 0, let amount = Int(fyjMoney),
                      amount == 5 || (amount == 0 && count == 0) else { return nil }
                return amount == 5
            }
        }

        let state: Int
        let result: [Entry]

        init(data: Data) throws {
            self = try JSONDecoder().decode(Self.self, from: data)
            guard state == 0 else { throw URLError(.cannotParseResponse) }
        }
    }

    func checkingGoodFortune(_ data: Data, for draw: LotteryDraw) throws -> Self {
        let notice = try NationalNotice(data: data)
        guard notice.result.count == 1, let status = notice.result.first?.fortuneStatus(for: draw) else {
            throw URLError(.cannotParseResponse)
        }
        guard status else { return self }
        var confirmed = amounts
        confirmed[.goodFortune] = LotteryPrize.goodFortune.fixedAmount
        return Self(amounts: confirmed, includesGoodFortune: true, promotions: promotions,
                    hasOtherPromotions: hasOtherPromotions, fromArchive: fromArchive)
    }

    private static func fetchOfficial(for draw: LotteryDraw) async throws -> Self {
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
