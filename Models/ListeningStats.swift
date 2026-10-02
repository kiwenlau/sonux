import Foundation

/// 收听时长统计：把播放器每秒上报的真实收听秒数按「本地日期」和「书」两个维度累计
/// 只记收听了多少秒，不记听了什么内容，所以删书时连带清掉那本书的秒数即可
struct ListeningStats: Codable, Equatable {
    /// key: yyyy-MM-dd（本地日历），value: 当天累计收听秒数
    var daily: [String: Double] = [:]
    /// key: bookId，value: 该书累计收听秒数
    var byBook: [String: Double] = [:]

    /// 累计收听总秒数
    var totalSeconds: TimeInterval { daily.values.reduce(0, +) }

    /// 一天的累计秒数
    func seconds(on date: Date, calendar: Calendar = .current) -> TimeInterval {
        daily[Self.dayKey(date, calendar: calendar)] ?? 0
    }

    /// 最近 count 天（含今天）的累计秒数
    func seconds(in count: Int, endingOn now: Date = Date(), calendar: Calendar = .current) -> TimeInterval {
        recentDays(count, endingOn: now, calendar: calendar).reduce(0) { $0 + $1.seconds }
    }

    /// 连续收听天数：从今天往前数连续有记录的天数；今天还没听就从昨天起算
    func streakDays(endingOn now: Date = Date(), calendar: Calendar = .current) -> Int {
        var day = calendar.startOfDay(for: now)
        if seconds(on: day, calendar: calendar) <= 0 {
            guard let yesterday = calendar.date(byAdding: .day, value: -1, to: day) else { return 0 }
            day = yesterday
            if seconds(on: day, calendar: calendar) <= 0 { return 0 }
        }
        var streak = 0
        while seconds(on: day, calendar: calendar) > 0 {
            streak += 1
            guard let previous = calendar.date(byAdding: .day, value: -1, to: day) else { break }
            day = previous
        }
        return streak
    }

    /// 最近 count 天的逐日收听情况，按日期从旧到新排列（没听的那天为 0）
    func recentDays(_ count: Int, endingOn now: Date = Date(), calendar: Calendar = .current) -> [ListeningDay] {
        guard count > 0, let today = calendar.date(byAdding: .day, value: -(count - 1), to: calendar.startOfDay(for: now)) else { return [] }
        return (0..<count).compactMap { offset in
            guard let date = calendar.date(byAdding: .day, value: offset, to: today) else { return nil }
            return ListeningDay(date: date, seconds: seconds(on: date, calendar: calendar))
        }
    }

    /// 记一段收听时长
    mutating func add(seconds: TimeInterval, bookId: String, at date: Date = Date(), calendar: Calendar = .current) {
        guard seconds > 0, seconds.isFinite else { return }
        let key = Self.dayKey(date, calendar: calendar)
        daily[key, default: 0] += seconds
        byBook[bookId, default: 0] += seconds
    }

    /// 书被删除时清掉它的收听秒数（按天的统计保留，历史时长不动）
    mutating func removeBook(_ bookId: String) {
        byBook[bookId] = nil
    }

    /// 日期分桶的键：用公历分量手工拼，避免 DateFormatter 这种非 Sendable 的全局量
    static func dayKey(_ date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
}

/// 某一天的收听时长，供「我」页的时长统计使用
struct ListeningDay: Identifiable, Equatable {
    let date: Date
    let seconds: TimeInterval

    var id: Date { date }
}
