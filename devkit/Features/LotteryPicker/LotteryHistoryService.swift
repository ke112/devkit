import Foundation
import Observation

struct LotteryDraw: Equatable, Identifiable {
    let issue: String
    let date: String
    let redNumbers: [Int]
    let blueNumber: Int

    var id: String { issue }
}

enum LotteryHistoryError: LocalizedError {
    case invalidResponse
    case invalidDraw(String)
    case incompleteHistory

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            "未能读取上海福彩开奖数据，网站可能暂时不可用或已调整格式。"
        case .invalidDraw(let issue):
            "第 \(issue) 期数据不完整或号码无效，未载入本次结果。"
        case .incompleteHistory:
            "返回的开奖历史存在缺期或重复，未载入不完整结果，请稍后重试。"
        }
    }
}

enum LotteryHistoryService {
    static let startIssue = 2025001
    static let endIssue = 2026032
    static let sourceURL = URL(string: "https://www.swlc.net.cn/lottery/ssq.html?view=previous&limit=100&weekday=&start_issue=2025001&end_issue=2026032")!

    static func fetch(
        loadPage: (URL) async throws -> String = loadHTML
    ) async throws -> [LotteryDraw] {
        var upperIssue = endIssue
        var draws: [String: LotteryDraw] = [:]

        // 网站最多返回 100 期；按本页最早期号向前查询，不能把一期号差当作期数。
        while upperIssue >= startIssue {
            try Task.checkCancellation()
            var components = URLComponents(url: sourceURL, resolvingAgainstBaseURL: false)!
            components.queryItems = [
                URLQueryItem(name: "view", value: "previous"),
                URLQueryItem(name: "limit", value: "100"),
                URLQueryItem(name: "weekday", value: ""),
                URLQueryItem(name: "start_issue", value: String(startIssue)),
                URLQueryItem(name: "end_issue", value: String(upperIssue)),
            ]
            guard let url = components.url else { throw LotteryHistoryError.invalidResponse }
            let page = try parse(try await loadPage(url))
            try Task.checkCancellation()
            guard !page.isEmpty else { throw LotteryHistoryError.incompleteHistory }

            for draw in page {
                guard let issue = Int(draw.issue), (startIssue...upperIssue).contains(issue),
                      draws.updateValue(draw, forKey: draw.issue) == nil else {
                    throw LotteryHistoryError.incompleteHistory
                }
            }
            guard let earliest = page.compactMap({ Int($0.issue) }).min() else {
                throw LotteryHistoryError.invalidResponse
            }
            upperIssue = earliest - 1
        }

        let ordered = draws.values.sorted { $0.issue < $1.issue }
        guard ordered.first?.issue == String(startIssue), ordered.last?.issue == String(endIssue) else {
            throw LotteryHistoryError.incompleteHistory
        }
        for year in (startIssue / 1000)...(endIssue / 1000) {
            let issues = ordered.compactMap { Int($0.issue) }.filter { $0 / 1000 == year }
            guard let last = issues.last,
                  issues == Array((year * 1000 + 1)...last) else {
                throw LotteryHistoryError.incompleteHistory
            }
        }
        return ordered
    }

    static func parse(_ html: String) throws -> [LotteryDraw] {
        let dateFormatter = DateFormatter()
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        dateFormatter.timeZone = TimeZone(secondsFromGMT: 0)
        dateFormatter.dateFormat = "yyyy-MM-dd"
        dateFormatter.isLenient = false

        let rows = try captures(#"<tr\b[^>]*>([\s\S]*?)</tr>"#, in: html)
        var draws: [LotteryDraw] = []
        for row in rows {
            let cells = try captures(#"<td\b[^>]*>([\s\S]*?)</td>"#, in: row)
            guard let first = cells.first else { continue }
            let issue = first.trimmingCharacters(in: .whitespacesAndNewlines)
            guard issue.range(of: #"^\d{7}$"#, options: .regularExpression) != nil else { continue }
            guard cells.count >= 4 else { throw LotteryHistoryError.invalidDraw(issue) }
            let date = String(cells[1].trimmingCharacters(in: .whitespacesAndNewlines).prefix(10))
            let reds = try numbers(in: cells[2], ballClass: "red")
            let blues = try numbers(in: cells[3], ballClass: "blue")
            guard let parsedDate = dateFormatter.date(from: date),
                  dateFormatter.string(from: parsedDate) == date,
                  date.prefix(4) == issue.prefix(4),
                  reds.count == 6, Set(reds).count == 6,
                  reds.allSatisfy({ (1...33).contains($0) }),
                  blues.count == 1, let blue = blues.first, (1...16).contains(blue) else {
                throw LotteryHistoryError.invalidDraw(issue)
            }
            draws.append(LotteryDraw(issue: issue, date: date, redNumbers: reds.sorted(), blueNumber: blue))
        }
        guard !draws.isEmpty else { throw LotteryHistoryError.invalidResponse }
        return draws
    }

    private static func numbers(in cell: String, ballClass: String) throws -> [Int] {
        let pattern = #"<span\b[^>]*class\s*=\s*["'][^"']*\blottery-history-balls--"#
            + ballClass + #"\b[^"']*["'][^>]*>([\s\S]*?)</span>"#
        guard let span = try captures(pattern, in: cell).first else { return [] }
        let values = try captures(#"<i\b[^>]*>\s*(\d+)\s*</i>"#, in: span)
        return values.compactMap(Int.init)
    }

    private static func captures(_ pattern: String, in string: String) throws -> [String] {
        let regex = try NSRegularExpression(pattern: pattern, options: .caseInsensitive)
        return regex.matches(in: string, range: NSRange(string.startIndex..., in: string)).compactMap {
            guard let range = Range($0.range(at: 1), in: string) else { return nil }
            return String(string[range])
        }
    }

    private static func loadHTML(_ url: URL) async throws -> String {
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse, response.statusCode == 200,
              let html = String(data: data, encoding: .utf8) else {
            throw LotteryHistoryError.invalidResponse
        }
        return html
    }
}

@MainActor
@Observable
final class LotteryHistoryModel {
    private(set) var draws: [LotteryDraw] = []
    private(set) var isLoading = false
    private(set) var errorMessage: String?

    func load(fetch: () async throws -> [LotteryDraw] = { try await LotteryHistoryService.fetch() }) async {
        guard !isLoading else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let result = try await fetch()
            try Task.checkCancellation()
            draws = result
        } catch {
            guard !Task.isCancelled else { return }
            errorMessage = error.localizedDescription
        }
    }
}
