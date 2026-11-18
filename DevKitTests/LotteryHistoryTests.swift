import Foundation
import Testing
@testable import devkit

struct LotteryHistoryTests {
    @Test func parsesOfficialTableWithOtherColumnsAndSortedRedNumbers() throws {
        let html = """
        <table><thead><tr><th>期号</th></tr></thead><tbody>
        <tr><td>2026032</td><td>2026-03-24(二)</td>
        <td><span class="lottery-history-balls lottery-history-balls--red"><i>01</i><i>03</i><i>11</i><i>18</i><i>31</i><i>33</i></span></td>
        <td><span class="lottery-history-balls lottery-history-balls--blue"><i>02</i></span></td>
        <td>392,702,390.00</td><td>6</td><td>7,330,318.00</td></tr>
        </tbody></table>
        """
        #expect(try LotteryHistoryService.parse(html) == [
            LotteryDraw(issue: "2026032", date: "2026-03-24", redNumbers: [1, 3, 11, 18, 31, 33], blueNumber: 2)
        ])
    }

    @Test(arguments: [
        ([1, 1, 3, 4, 5, 6], 1, "2025-01-01"),
        ([0, 2, 3, 4, 5, 6], 1, "2025-01-01"),
        ([1, 2, 3, 4, 5, 34], 1, "2025-01-01"),
        ([1, 2, 3, 4, 5], 1, "2025-01-01"),
        ([1, 2, 3, 4, 5, 6], 17, "2025-01-01"),
        ([1, 2, 3, 4, 5, 6], 0, "2025-01-01"),
        ([1, 2, 3, 4, 5, 6], 1, "2025-02-30"),
        ([1, 2, 3, 4, 5, 6], 1, "2026-01-01"),
    ])
    func rejectsInvalidNumbersAndDates(reds: [Int], blue: Int, date: String) {
        let draw = LotteryDraw(issue: "2025001", date: date, redNumbers: reds, blueNumber: blue)
        #expect(throws: LotteryHistoryError.self) {
            try LotteryHistoryService.parse(Self.html([draw]))
        }
    }

    @Test func rejectsChangedOrEmptyWebsiteResponse() {
        #expect(throws: LotteryHistoryError.self) { try LotteryHistoryService.parse("<html>系统维护中</html>") }
        #expect(throws: LotteryHistoryError.self) {
            try LotteryHistoryService.parse("<tr><td>2025001</td><td>2025-01-01</td></tr>")
        }
    }

    @Test func fetchesPastTheHundredRowLimitAcrossTheYearBoundary() async throws {
        let cacheURL = Self.cacheURL()
        defer { try? FileManager.default.removeItem(at: cacheURL.deletingLastPathComponent()) }
        let expected = Self.fullHistory
        var requestedUpperIssues: [Int?] = []
        let actual = try await LotteryHistoryService.refresh(cache: LotteryHistoryCache(url: cacheURL)) { url in
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            #expect(items.first(where: { $0.name == "start_issue" })?.value == "2020001")
            #expect(items.first(where: { $0.name == "limit" })?.value == "100")
            let upper = items.first(where: { $0.name == "end_issue" })?.value.flatMap(Int.init)
            requestedUpperIssues.append(upper)
            return Self.html(Array(expected.filter { Int($0.issue)! <= (upper ?? Int.max) }.suffix(100).reversed()))
        }
        #expect(actual.draws == expected)
        #expect(actual.draws.count == 188)
        #expect(requestedUpperIssues == [nil, 2025083])
    }

    @Test func rejectsMissingOrDuplicateIssuesInsteadOfPublishingPartialHistory() async {
        let cacheURL = Self.cacheURL()
        defer { try? FileManager.default.removeItem(at: cacheURL.deletingLastPathComponent()) }
        let missing = Self.fullHistory.filter { $0.issue != "2025050" }
        await #expect(throws: LotteryHistoryError.self) {
            try await LotteryHistoryService.refresh(cache: LotteryHistoryCache(url: cacheURL)) { url in
                let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
                let upper = items.first(where: { $0.name == "end_issue" })?.value.flatMap(Int.init) ?? Int.max
                return Self.html(Array(missing.filter { Int($0.issue)! <= upper }.suffix(100)))
            }
        }
        let duplicateURL = Self.cacheURL()
        defer { try? FileManager.default.removeItem(at: duplicateURL.deletingLastPathComponent()) }
        await #expect(throws: LotteryHistoryError.self) {
            try await LotteryHistoryService.refresh(cache: LotteryHistoryCache(url: duplicateURL)) { _ in
                Self.html([Self.fullHistory[0], Self.fullHistory[0]])
            }
        }
    }

    @Test func refreshFailureKeepsTheLastCompleteResult() async {
        let model = LotteryHistoryModel()
        await model.load { Self.fullHistory }
        await model.load { throw URLError(.notConnectedToInternet) }
        #expect(model.draws == Self.fullHistory)
        #expect(model.errorMessage != nil)
        #expect(!model.isLoading)
    }

    @Test func persistsAndFetchesOnlyNewIssues() async throws {
        let url = Self.cacheURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        LotteryHistoryCache(url: url).write(Self.fullHistory)
        let additions = (33...35).map { Self.draw(year: 2026, index: $0) }
        let cache = LotteryHistoryCache(url: url)
        let result = try await LotteryHistoryService.refresh(cache: cache) { url in
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            #expect(items.first(where: { $0.name == "start_issue" })?.value == "2026033")
            #expect(items.first(where: { $0.name == "end_issue" }) == nil)
            return Self.html(additions.reversed().map { $0 })
        }
        #expect(result.draws == Self.fullHistory + additions)
        #expect(result.refreshError == nil)
        #expect(LotteryHistoryCache(url: url).read() == result.draws)
    }

    @Test func emptyOfficialTableAndOfflineFailureAreDistinct() async throws {
        let url = Self.cacheURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        LotteryHistoryCache(url: url).write(Self.fullHistory)
        let cache = LotteryHistoryCache(url: url)
        let unchanged = try await LotteryHistoryService.refresh(cache: cache) { _ in Self.emptyTable }
        #expect(unchanged.draws == Self.fullHistory)
        #expect(unchanged.refreshError == nil)
        let offline = try await LotteryHistoryService.refresh(cache: LotteryHistoryCache(url: url)) { _ in
            throw URLError(.notConnectedToInternet)
        }
        #expect(offline.draws == Self.fullHistory)
        #expect(offline.refreshError != nil)
        let invalid = try await LotteryHistoryService.refresh(cache: cache) { _ in "<html>系统维护中</html>" }
        #expect(invalid.draws == Self.fullHistory)
        #expect(invalid.refreshError != nil)
    }

    @Test func fillsCachedGapWithoutRequestingKnownIssues() async throws {
        let url = Self.cacheURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let cache = LotteryHistoryCache(url: url)
        cache.write(Self.fullHistory.filter { $0.issue != "2025050" })
        var ranges: [(String?, String?)] = []
        let result = try await LotteryHistoryService.refresh(cache: cache) { url in
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            let start = items.first(where: { $0.name == "start_issue" })?.value
            let end = items.first(where: { $0.name == "end_issue" })?.value
            ranges.append((start, end))
            return end == nil ? Self.emptyTable : Self.html([Self.draw(year: 2025, index: 50)])
        }
        #expect(result.draws == Self.fullHistory)
        #expect(ranges.count == 2)
        #expect(ranges[0].0 == "2025050" && ranges[0].1 == "2025050")
        #expect(ranges[1].0 == "2026033" && ranges[1].1 == nil)
    }

    @Test func initialLoadPaginatesFromTheLatestIssue() async throws {
        let url = Self.cacheURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        var requests = 0
        let result = try await LotteryHistoryService.refresh(cache: LotteryHistoryCache(url: url)) { url in
            requests += 1
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            let upper = items.first(where: { $0.name == "end_issue" })?.value.flatMap(Int.init) ?? Int.max
            return Self.html(Array(Self.fullHistory.filter { Int($0.issue)! <= upper }.suffix(100).reversed()))
        }
        #expect(result.draws == Self.fullHistory)
        #expect(requests == 2)
    }

    @Test func offlineWithoutCompleteCacheDoesNotPublishPartialResults() async {
        let url = Self.cacheURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let cache = LotteryHistoryCache(url: url)
        cache.write(Self.fullHistory.filter { $0.issue != "2025050" })
        await #expect(throws: URLError.self) {
            try await LotteryHistoryService.refresh(cache: cache) { _ in
                throw URLError(.notConnectedToInternet)
            }
        }
    }

    @Test func resumesPersistedPagesAcrossYearBoundaryAfterRepeatedFailures() async throws {
        let url = Self.cacheURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let history = (2020...2024).map { Self.draw(year: $0, index: 1) }
            + (1...151).map { Self.draw(year: 2025, index: $0) }
            + (1...100).map { Self.draw(year: 2026, index: $0) }
        var firstRequests: [Int?] = []
        await #expect(throws: URLError.self) {
            try await LotteryHistoryService.refresh(cache: LotteryHistoryCache(url: url)) { request in
                let items = URLComponents(url: request, resolvingAgainstBaseURL: false)?.queryItems ?? []
                let upper = items.first(where: { $0.name == "end_issue" })?.value.flatMap(Int.init)
                firstRequests.append(upper)
                if upper != nil { throw URLError(.notConnectedToInternet) }
                return Self.html(Array(history.suffix(100).reversed()))
            }
        }
        #expect(firstRequests == [nil, 2025999])

        var secondRequests: [Int?] = []
        await #expect(throws: URLError.self) {
            try await LotteryHistoryService.refresh(cache: LotteryHistoryCache(url: url)) { request in
                let items = URLComponents(url: request, resolvingAgainstBaseURL: false)?.queryItems ?? []
                let upper = items.first(where: { $0.name == "end_issue" })?.value.flatMap(Int.init)
                secondRequests.append(upper)
                if upper != 2025999 { throw URLError(.notConnectedToInternet) }
                return Self.html(Array(history.filter { Int($0.issue)! <= 2025999 }.suffix(100).reversed()))
            }
        }
        #expect(secondRequests == [2025999, 2025051])

        var finalRequests: [Int?] = []
        let result = try await LotteryHistoryService.refresh(cache: LotteryHistoryCache(url: url)) { request in
            let items = URLComponents(url: request, resolvingAgainstBaseURL: false)?.queryItems ?? []
            let upper = items.first(where: { $0.name == "end_issue" })?.value.flatMap(Int.init)
            finalRequests.append(upper)
            guard let upper else { return Self.emptyTable }
            return Self.html(Array(history.filter { Int($0.issue)! <= upper }.suffix(100).reversed()))
        }
        #expect(finalRequests == [2025051, nil])
        #expect(result.draws == history)
        #expect(LotteryHistoryCache(url: url).read() == history)
    }

    @Test func resumesIncrementalRefreshWhileKeepingCompleteOfflineFallback() async throws {
        let url = Self.cacheURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        LotteryHistoryCache(url: url).write(Self.fullHistory)
        let additions = (33...150).map { Self.draw(year: 2026, index: $0) }
        let failed = try await LotteryHistoryService.refresh(cache: LotteryHistoryCache(url: url)) { request in
            let items = URLComponents(url: request, resolvingAgainstBaseURL: false)?.queryItems ?? []
            if items.contains(where: { $0.name == "end_issue" }) { throw URLError(.notConnectedToInternet) }
            return Self.html(Array(additions.suffix(100).reversed()))
        }
        #expect(failed.draws == Self.fullHistory)
        #expect(failed.refreshError != nil)

        var requests: [Int?] = []
        let resumed = try await LotteryHistoryService.refresh(cache: LotteryHistoryCache(url: url)) { request in
            let items = URLComponents(url: request, resolvingAgainstBaseURL: false)?.queryItems ?? []
            let upper = items.first(where: { $0.name == "end_issue" })?.value.flatMap(Int.init)
            requests.append(upper)
            guard let upper else { return Self.emptyTable }
            return Self.html(additions.filter { Int($0.issue)! <= upper })
        }
        #expect(requests == [2026050, nil])
        #expect(resumed.draws == Self.fullHistory + additions)
        #expect(resumed.refreshError == nil)
    }

    @Test func backfillsLegacyCacheAndResumesBothKindsOfPendingPages() async throws {
        let url = Self.cacheURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let cache = LotteryHistoryCache(url: url)
        let legacy = Self.fullHistory.filter { Int($0.issue)! >= 2025001 }
        let older = (2020...2024).flatMap { year in
            (1...120).map { Self.draw(year: year, index: $0) }
        }
        let additions = (33...150).map { Self.draw(year: 2026, index: $0) }
        try cache.save(.init(
            draws: legacy,
            pending: .init(lower: 2026033, upper: 2026050, draws: Array(additions.suffix(100)))
        ))
        let loader = LotteryHistoryLoader(cache: cache) { _ in throw URLError(.notConnectedToInternet) }
        #expect(loader.cachedHistory() == legacy)
        var firstRequests = 0
        let failed = try await LotteryHistoryService.refresh(cache: cache) { request in
            firstRequests += 1
            if firstRequests > 1 { throw URLError(.notConnectedToInternet) }
            let upper = URLComponents(url: request, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "end_issue" })?.value.flatMap(Int.init) ?? 0
            return Self.html(Array(older.filter { Int($0.issue)! <= upper }.suffix(100).reversed()))
        }
        #expect(failed.draws == legacy)
        #expect(failed.refreshError != nil)
        #expect(cache.readState().prefix?.draws.count == 100)
        #expect(cache.readState().pending?.draws.count == 100)
        #expect(loader.cachedHistory() == legacy)

        var requested: [(Int, Int?)] = []
        let resumed = try await LotteryHistoryService.refresh(cache: LotteryHistoryCache(url: url)) { request in
            let items = URLComponents(url: request, resolvingAgainstBaseURL: false)?.queryItems ?? []
            let lower = Int(items.first(where: { $0.name == "start_issue" })?.value ?? "")!
            let upper = items.first(where: { $0.name == "end_issue" })?.value.flatMap(Int.init)
            requested.append((lower, upper))
            let matching = (older + legacy + additions).filter {
                let issue = Int($0.issue)!
                return issue >= lower && issue <= (upper ?? Int.max)
            }
            return matching.isEmpty ? Self.emptyTable : Self.html(Array(matching.suffix(100).reversed()))
        }
        #expect(requested.first?.1 == 2024020)
        #expect(requested.allSatisfy { lower, upper in
            lower != 2020001 || (upper ?? Int.max) < 2025001
        })
        #expect(resumed.draws == older + legacy + additions)
        #expect(resumed.refreshError == nil)
        #expect(cache.readState().prefix == nil)
        #expect(cache.readState().pending == nil)
    }

    @Test func resumesLegacyInitialDownloadWithoutDiscardingItsPages() async throws {
        let url = Self.cacheURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let cache = LotteryHistoryCache(url: url)
        try cache.save(.init(
            draws: [],
            pending: .init(lower: 2025001, upper: 2025083, draws: Array(Self.fullHistory.suffix(100)))
        ))
        var requests: [(Int, Int?)] = []
        let result = try await LotteryHistoryService.refresh(cache: cache) { request in
            let items = URLComponents(url: request, resolvingAgainstBaseURL: false)?.queryItems ?? []
            let lower = Int(items.first(where: { $0.name == "start_issue" })?.value ?? "")!
            let upper = items.first(where: { $0.name == "end_issue" })?.value.flatMap(Int.init)
            requests.append((lower, upper))
            let matches = Self.fullHistory.filter {
                let issue = Int($0.issue)!
                return issue >= lower && issue <= (upper ?? Int.max)
            }
            return matches.isEmpty ? Self.emptyTable : Self.html(Array(matches.suffix(100).reversed()))
        }
        #expect(requests.first?.0 == 2020001)
        #expect(requests.first?.1 == 2025083)
        #expect(result.draws == Self.fullHistory)
    }

    @Test func concurrentRefreshesShareOneRequest() async throws {
        let url = Self.cacheURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let cache = LotteryHistoryCache(url: url)
        cache.write(Self.fullHistory)
        var requests = 0
        var entered = 0
        var release: CheckedContinuation<Void, Never>?
        let loader = LotteryHistoryLoader(cache: cache) { _ in
            requests += 1
            await withCheckedContinuation { release = $0 }
            return Self.emptyTable
        }
        let first = Task {
            entered += 1
            return try await loader.fetch()
        }
        let second = Task {
            entered += 1
            return try await loader.fetch()
        }
        while entered < 2 || release == nil { await Task.yield() }
        release?.resume()
        let results = try await [first.value, second.value]
        #expect(results.allSatisfy { $0.draws == Self.fullHistory })
        #expect(requests == 1)
    }

    private static var emptyTable: String {
        "<table class='lottery-history-table lottery-history-table--ssq'><thead></thead><tbody></tbody></table>"
    }

    private static func cacheURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("LotteryHistoryTests-\(UUID().uuidString)")
            .appendingPathComponent("cache.json")
    }

    private static var fullHistory: [LotteryDraw] {
        (2020...2024).map { draw(year: $0, index: 1) }
            + (1...151).map { draw(year: 2025, index: $0) }
            + (1...32).map { draw(year: 2026, index: $0) }
    }

    private static func draw(year: Int, index: Int) -> LotteryDraw {
        LotteryDraw(issue: String(year * 1000 + index), date: "\(year)-01-01", redNumbers: [1, 3, 11, 18, 31, 33], blueNumber: 2)
    }

    private static func html(_ draws: [LotteryDraw]) -> String {
        "<table><tbody>" + draws.map { draw in
            """
            <tr><td>\(draw.issue)</td><td>\(draw.date)(二)</td>
            <td><span class='lottery-history-balls--red lottery-history-balls'>\(draw.redNumbers.map { "<i>\($0)</i>" }.joined())</span></td>
            <td><span class='lottery-history-balls--blue'><i>\(draw.blueNumber)</i></span></td></tr>
            """
        }.joined() + "</tbody></table>"
    }
}
