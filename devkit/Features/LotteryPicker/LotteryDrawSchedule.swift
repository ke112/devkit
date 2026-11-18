import Foundation

struct LotteryDrawSchedule: Equatable {
    let date: Date
    let nextRefreshDate: Date

    var displayText: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = LotteryDrawScheduleService.beijingTimeZone
        formatter.dateFormat = "yyyy年M月d日 EEEE HH:mm"
        return "预计 \(formatter.string(from: date))（北京时间，休市安排以福彩公告为准）"
    }
}

enum LotteryDrawScheduleError: LocalizedError {
    case invalidResponse

    var errorDescription: String? {
        "暂时无法获取最新开奖信息，请稍后重试。"
    }
}

enum LotteryDrawScheduleService {
    static let beijingTimeZone = TimeZone(identifier: "Asia/Shanghai")!
    static func fetch(now: Date = Date()) async throws -> LotteryDrawSchedule {
        try await fetch(now: now) { url in
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else {
                throw LotteryDrawScheduleError.invalidResponse
            }
            return data
        }
    }

    static func fetch(
        now: Date,
        load: (URL) async throws -> Data
    ) async throws -> LotteryDrawSchedule {
        let data = try await load(LotteryHistoryService.sourceURL)
        guard let html = String(data: data, encoding: .utf8),
              let intro = match(#"<span\b[^>]*class\s*=\s*["'][^"']*\blottery-service-intro\b[^"']*["'][^>]*>(.*?)</span\s*>"#, in: html, group: 1),
              let rule = match(
                #"每周\s*([一二三四五六日天、，,\s]+?)\s*(\d{1,2})[:：](\d{2})\s*开奖"#,
                in: intro.replacingOccurrences(of: "<[^>]*>", with: " ", options: .regularExpression)
                    .replacingOccurrences(of: "&nbsp;", with: " ")
              ) else {
            throw LotteryDrawScheduleError.invalidResponse
        }
        let parts = rule.components(separatedBy: "\u{0}")
        guard parts.count == 3, let hour = Int(parts[1]), (0...23).contains(hour),
              let minute = Int(parts[2]), (0...59).contains(minute) else {
            throw LotteryDrawScheduleError.invalidResponse
        }
        let weekdayValues: [Character: Int] = ["日": 1, "天": 1, "一": 2, "二": 3, "三": 4, "四": 5, "五": 6, "六": 7]
        let weekdays = Set(parts[0].compactMap { weekdayValues[$0] })
        guard !weekdays.isEmpty else { throw LotteryDrawScheduleError.invalidResponse }
        let today = calendar.startOfDay(for: now)
        for offset in 0...7 {
            guard let day = calendar.date(byAdding: .day, value: offset, to: today),
                  weekdays.contains(calendar.component(.weekday, from: day)),
                  let candidate = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day),
                  candidate > now else { continue }
            return LotteryDrawSchedule(date: candidate, nextRefreshDate: candidate)
        }
        throw LotteryDrawScheduleError.invalidResponse
    }

    private static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = beijingTimeZone
        return calendar
    }

    private static func match(_ pattern: String, in text: String, group: Int? = nil) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators, .caseInsensitive]),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        let groups = group.map { [$0] } ?? Array(1..<match.numberOfRanges)
        let values = groups.compactMap { index in
            Range(match.range(at: index), in: text).map { String(text[$0]) }
        }
        guard values.count == groups.count else { return nil }
        return values.joined(separator: "\u{0}")
    }
}
