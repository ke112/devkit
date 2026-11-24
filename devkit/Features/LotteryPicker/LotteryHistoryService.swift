import Foundation
import Observation

nonisolated struct LotteryDraw: Codable, Equatable, Identifiable, Sendable {
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
    static let startIssue = 2020001
    fileprivate static let legacyStartIssue = 2025001
    static let sourceURL = URL(string: "https://www.swlc.net.cn/lottery/ssq.html")!
    private static let loader = LotteryHistoryLoader(cache: LotteryHistoryCache(), loadPage: loadHTML)

    static func fetchLatest() async throws -> LotteryHistoryResult {
        let archive = try LotteryDrawArchive.bundled.get()
        let live = try await loader.fetch()
        return LotteryHistoryResult(draws: archive.joining(live.draws), refreshError: live.refreshError)
    }

    static func cachedHistory() throws -> [LotteryDraw] {
        try LotteryDrawArchive.bundled.get().joining(loader.cachedHistory())
    }

    static func refresh(
        cache: LotteryHistoryCache,
        loadPage: (URL) async throws -> String
    ) async throws -> LotteryHistoryResult {
        var state = cache.readState()
        var cached = state.draws
        let fallback: [LotteryDraw] = cached.last.flatMap { Int($0.issue) }.flatMap { end -> [LotteryDraw]? in
            let first = cached.first.flatMap { Int($0.issue) }
            guard first == startIssue || first == legacyStartIssue, let first else { return nil }
            return (try? validate(cached, start: first, end: end)) == nil ? nil : cached
        } ?? []
        do {
            if let first = cached.first.flatMap({ Int($0.issue) }), first > startIssue {
                var prefix = state.prefix ?? LotteryHistoryCache.Pending(
                    lower: startIssue,
                    upper: first - 1,
                    draws: []
                )
                while let upper = prefix.upper, upper >= prefix.lower {
                    let page = try parsePage(
                        try await loadPage(pageURL(start: prefix.lower, end: upper)),
                        allowEmpty: true
                    )
                    guard !page.isEmpty,
                          Set(page.map(\.issue)).count == page.count,
                          Set(page.map(\.issue)).isDisjoint(with: Set(prefix.draws.map(\.issue))),
                          page.allSatisfy({ Int($0.issue).map { (prefix.lower...upper).contains($0) } == true }),
                          let earliest = page.compactMap({ Int($0.issue) }).min() else {
                        throw LotteryHistoryError.incompleteHistory
                    }
                    prefix.draws.append(contentsOf: page)
                    let previous = earliest - 1
                    prefix.upper = previous % 1000 == 0 ? previous - 1 : previous
                    state.prefix = prefix
                    try cache.save(state)
                    try Task.checkCancellation()
                }
                cached.append(contentsOf: prefix.draws)
                cached.sort { $0.issue < $1.issue }
                state.draws = cached
                state.prefix = nil
                try cache.save(state)
            }
            if state.pending == nil, let last = cached.last.flatMap({ Int($0.issue) }) {
                for (lower, upper) in missingRanges(cached, last: last) {
                    let page = try await fetchMissing(lower: lower, upper: upper, loadPage: loadPage)
                    cached.append(contentsOf: page)
                    state.draws = cached.sorted { $0.issue < $1.issue }
                    try cache.save(state)
                }
                cached.sort { $0.issue < $1.issue }
            }
            let resuming = state.pending != nil
            var pending = state.pending ?? LotteryHistoryCache.Pending(
                lower: cached.last.flatMap { Int($0.issue) }.map { $0 + 1 } ?? startIssue,
                upper: nil,
                draws: []
            )
            while pending.upper.map({ $0 >= pending.lower }) ?? true {
                let page = try parsePage(
                    try await loadPage(pageURL(start: pending.lower, end: pending.upper)),
                    allowEmpty: true
                )
                if page.isEmpty {
                    pending.upper = pending.lower - 1
                    if !pending.draws.isEmpty {
                        state.pending = pending
                        try cache.save(state)
                    }
                    break
                }
                let known = Set(pending.draws.map(\.issue)).union(cached.map(\.issue))
                for draw in page {
                    guard let issue = Int(draw.issue), issue >= pending.lower,
                          pending.upper.map({ issue <= $0 }) ?? true,
                          !known.contains(draw.issue) else {
                        throw LotteryHistoryError.incompleteHistory
                    }
                }
                guard Set(page.map(\.issue)).count == page.count,
                      let earliest = page.compactMap({ Int($0.issue) }).min() else {
                    throw LotteryHistoryError.incompleteHistory
                }
                pending.draws.append(contentsOf: page)
                let previous = earliest - 1
                pending.upper = previous % 1000 == 0 ? previous - 1 : previous
                state.pending = pending
                try cache.save(state)
                try Task.checkCancellation()
            }
            let available = cached + pending.draws
            if let last = available.compactMap({ Int($0.issue) }).max() {
                for (lower, upper) in missingRanges(available, last: last) {
                    let page = try await fetchMissing(lower: lower, upper: upper, loadPage: loadPage)
                    pending.draws.append(contentsOf: page)
                    state.pending = pending
                    try cache.save(state)
                }
            }
            let ordered = (cached + pending.draws).sorted { $0.issue < $1.issue }
            try validate(ordered, start: startIssue, end: Int(ordered.last?.issue ?? "") ?? 0)
            state.draws = ordered
            state.pending = nil
            try cache.save(state)
            if resuming {
                return try await refresh(cache: cache, loadPage: loadPage)
            }
            return LotteryHistoryResult(draws: ordered, refreshError: nil)
        } catch {
            if Task.isCancelled || error is CancellationError { throw error }
            guard !fallback.isEmpty else { throw error }
            return LotteryHistoryResult(draws: fallback, refreshError: error.localizedDescription)
        }
    }

    private static func missingRanges(_ draws: [LotteryDraw], last: Int) -> [(Int, Int)] {
        let known = Set(draws.compactMap { Int($0.issue) })
        var ranges: [(Int, Int)] = []
        for year in (startIssue / 1000)...(last / 1000) {
            let first = max(startIssue, year * 1000 + 1)
            let lastInYear = known.filter { $0 / 1000 == year }.max() ?? (year * 1000 + 999)
            guard first <= lastInYear else { continue }
            for issue in first...lastInYear where !known.contains(issue) {
                if let previous = ranges.last, previous.1 + 1 == issue, issue - previous.0 < 100 {
                    ranges[ranges.count - 1].1 = issue
                } else {
                    ranges.append((issue, issue))
                }
            }
        }
        return ranges
    }

    private static func fetchMissing(
        lower: Int,
        upper: Int,
        loadPage: (URL) async throws -> String
    ) async throws -> [LotteryDraw] {
        let page = try parsePage(try await loadPage(pageURL(start: lower, end: upper)), allowEmpty: true)
        guard Set(page.map(\.issue)).count == page.count,
              page.allSatisfy({ Int($0.issue).map { (lower...upper).contains($0) } == true }),
              Set(page.compactMap { Int($0.issue) }) == Set(lower...upper) else {
            throw LotteryHistoryError.incompleteHistory
        }
        return page
    }

    private static func pageURL(start: Int, end: Int?) throws -> URL {
        var components = URLComponents(url: sourceURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "view", value: "previous"),
            URLQueryItem(name: "limit", value: "100"),
            URLQueryItem(name: "weekday", value: ""),
            URLQueryItem(name: "start_issue", value: String(start)),
        ]
        if let end {
            components.queryItems?.append(URLQueryItem(name: "end_issue", value: String(end)))
        }
        guard let url = components.url else { throw LotteryHistoryError.invalidResponse }
        return url
    }

    nonisolated static func validate(_ ordered: [LotteryDraw], start: Int, end: Int) throws {
        guard start <= end, ordered.first?.issue == String(start), ordered.last?.issue == String(end) else {
            throw LotteryHistoryError.incompleteHistory
        }
        for year in (start / 1000)...(end / 1000) {
            let issues = ordered.compactMap { Int($0.issue) }.filter { $0 / 1000 == year }
            guard let last = issues.last,
                  last >= max(start, year * 1000 + 1),
                  issues == Array(max(start, year * 1000 + 1)...last) else {
                throw LotteryHistoryError.incompleteHistory
            }
        }
        guard validDraws(ordered) else { throw LotteryHistoryError.incompleteHistory }
    }

    nonisolated fileprivate static func validDraws(_ draws: [LotteryDraw]) -> Bool {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        return draws.allSatisfy { draw in
            draw.issue.range(of: #"^\d{7}$"#, options: .regularExpression) != nil
                && draw.date.prefix(4) == draw.issue.prefix(4)
                && formatter.date(from: draw.date).map { formatter.string(from: $0) == draw.date } == true
                && draw.redNumbers.count == 6 && Set(draw.redNumbers).count == 6
                && draw.redNumbers.allSatisfy { (1...33).contains($0) }
                && (1...16).contains(draw.blueNumber)
        }
    }

    static func parse(_ html: String) throws -> [LotteryDraw] {
        try parsePage(html, allowEmpty: false)
    }

    private static func parsePage(_ html: String, allowEmpty: Bool) throws -> [LotteryDraw] {
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
        if draws.isEmpty {
            let emptyTable = #"<table\b[^>]*class\s*=\s*["'][^"']*\blottery-history-table--ssq\b[^"']*["'][^>]*>[\s\S]*?<tbody[^>]*>\s*</tbody>\s*</table>"#
            guard allowEmpty, html.range(of: emptyTable, options: [.regularExpression, .caseInsensitive]) != nil else {
                throw LotteryHistoryError.invalidResponse
            }
        }
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

struct LotteryHistoryResult {
    let draws: [LotteryDraw]
    let refreshError: String?
}

final class LotteryHistoryLoader {
    private let cache: LotteryHistoryCache
    private let loadPage: (URL) async throws -> String
    private var task: (id: UUID, value: Task<LotteryHistoryResult, Error>)?

    init(cache: LotteryHistoryCache, loadPage: @escaping (URL) async throws -> String) {
        self.cache = cache
        self.loadPage = loadPage
    }

    func cachedHistory() -> [LotteryDraw] {
        let draws = cache.read()
        guard let first = draws.first.flatMap({ Int($0.issue) }),
              first == LotteryHistoryService.startIssue || first == LotteryHistoryService.legacyStartIssue,
              let last = draws.last.flatMap({ Int($0.issue) }),
              (try? LotteryHistoryService.validate(draws, start: first, end: last)) != nil else {
            return []
        }
        return draws
    }

    func fetch() async throws -> LotteryHistoryResult {
        let current: (id: UUID, value: Task<LotteryHistoryResult, Error>)
        if let task {
            current = task
        } else {
            let newTask = Task { try await LotteryHistoryService.refresh(cache: cache, loadPage: loadPage) }
            current = (UUID(), newTask)
            task = current
        }
        defer {
            if task?.id == current.id { task = nil }
        }
        let result = try await current.value.value
        try Task.checkCancellation()
        return result
    }
}

final class LotteryHistoryCache {
    struct Pending: Codable {
        let lower: Int
        var upper: Int?
        var draws: [LotteryDraw]
    }

    struct Contents: Codable {
        var lottery: String = "ssq"
        var draws: [LotteryDraw]
        var pending: Pending? = nil
        var prefix: Pending? = nil
    }

    private let url: URL

    init(url: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("DevKit/lottery-history-ssq.json")) {
        self.url = url
    }

    func read() -> [LotteryDraw] {
        readState().draws
    }

    func readState() -> Contents {
        guard let data = try? Data(contentsOf: url),
              let contents = try? JSONDecoder().decode(Contents.self, from: data),
              contents.lottery == "ssq",
              Set(contents.draws.map(\.issue)).count == contents.draws.count,
              contents.draws.allSatisfy({ (Int($0.issue) ?? 0) >= LotteryHistoryService.startIssue }),
              LotteryHistoryService.validDraws(contents.draws) else {
            return Contents(draws: [])
        }
        var state = contents
        state.draws.sort { $0.issue < $1.issue }
        if state.draws.isEmpty, let pending = state.pending,
           pending.lower == LotteryHistoryService.legacyStartIssue {
            state.pending = Pending(
                lower: LotteryHistoryService.startIssue,
                upper: pending.upper,
                draws: pending.draws
            )
        }
        if let prefix = state.prefix {
            let ids = prefix.draws.map(\.issue)
            let first = state.draws.first.flatMap { Int($0.issue) }
            if prefix.lower != LotteryHistoryService.startIssue
                || first == nil
                || prefix.draws.isEmpty
                || Set(ids).count != ids.count
                || !LotteryHistoryService.validDraws(prefix.draws)
                || !prefix.draws.allSatisfy({ draw in
                    guard let issue = Int(draw.issue), let first, let upper = prefix.upper else { return false }
                    return issue >= prefix.lower && issue < first && issue > upper
                }) {
                state.prefix = nil
            }
        }
        if let pending = state.pending {
            let ids = pending.draws.map(\.issue)
            let cached = Set(state.draws.map(\.issue))
            guard pending.lower >= LotteryHistoryService.startIssue,
                  pending.lower == (state.draws.last.flatMap({ Int($0.issue) }).map { $0 + 1 } ?? LotteryHistoryService.startIssue),
                  !pending.draws.isEmpty,
                  Set(ids).count == ids.count,
                  Set(ids).isDisjoint(with: cached),
                  LotteryHistoryService.validDraws(pending.draws),
                  pending.draws.allSatisfy({ draw in
                      guard let issue = Int(draw.issue), issue >= pending.lower else { return false }
                      return pending.upper.map { issue > $0 } ?? false
                  }) else {
                state.pending = nil
                return state
            }
        }
        return state
    }

    func write(_ draws: [LotteryDraw]) {
        do {
            try save(Contents(draws: draws))
        } catch {
            NSLog("开奖历史缓存写入失败：%@", error.localizedDescription)
        }
    }

    func save(_ contents: Contents) throws {
        let data = try JSONEncoder().encode(contents)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }
}

@MainActor
@Observable
final class LotteryHistoryModel {
    private(set) var draws: [LotteryDraw] = []
    private(set) var isLoading = false
    private(set) var errorMessage: String?

    func load(fetch: (() async throws -> [LotteryDraw])? = nil) async {
        guard !isLoading else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let result: LotteryHistoryResult
            if let fetch {
                result = LotteryHistoryResult(draws: try await fetch(), refreshError: nil)
            } else {
                let cached = try LotteryHistoryService.cachedHistory()
                if !cached.isEmpty { draws = cached }
                result = try await LotteryHistoryService.fetchLatest()
            }
            try Task.checkCancellation()
            draws = result.draws
            errorMessage = result.refreshError
        } catch {
            guard !Task.isCancelled else { return }
            errorMessage = error.localizedDescription
        }
    }
}
