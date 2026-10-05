import Foundation

/// 收听时长统计：把播放器每秒上报的真实收听秒数按「本地日期」和「书」两个维度累计
/// 只记收听了多少秒，不记听了什么内容，所以删书时连带清掉那本书的秒数即可
struct ListeningStats: Codable, Equatable {
    /// key: yyyy-MM-dd（本地日历），value: 当天累计收听秒数
    var daily: [String: Double] = [:]
    /// key: bookId，value: 该书累计收听秒数
    var byBook: [String: Double] = [:]
    /// key: bookId，value: 第一次整本听完那天的 yyyy-MM-dd
    /// 有了完成日期才能按月/按年数「听完几本」；重听不会把日期挪走，一本书只算听完一次
    var finished: [String: String] = [:]

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

    /// 某个时间桶内的累计秒数：桶键用日分桶键的前缀，月是「2026-10」、年是「2026」
    func seconds(in bucket: String) -> TimeInterval {
        var total: TimeInterval = 0
        for (day, value) in daily where day.hasPrefix(bucket) { total += value }
        return total
    }

    /// 某个时间桶内听过音的天数（只有一秒也算，但不收脏数据里的 0）
    func daysListened(in bucket: String) -> Int {
        var count = 0
        for (day, value) in daily where day.hasPrefix(bucket) && value >= 1 { count += 1 }
        return count
    }

    /// 某个时间桶内听完的书数：按完成日期归月、归年
    func booksFinished(in bucket: String) -> Int {
        finished.values.filter { $0.hasPrefix(bucket) }.count
    }

    /// 某年的逐月收听秒数，下标 0 是 1 月，没听的那个月为 0
    func monthlySeconds(inYear year: Int) -> [TimeInterval] {
        var buckets = [TimeInterval](repeating: 0, count: 12)
        let prefix = String(format: "%04d-", year)
        for (day, value) in daily where day.hasPrefix(prefix) {
            // 日分桶键是零补齐的 yyyy-MM-dd，第 6 位起两位就是月份
            if let month = Int(day.dropFirst(5).prefix(2)), (1...12).contains(month) {
                buckets[month - 1] += value
            }
        }
        return buckets
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

    /// 记一次「整本听完」：只落第一次完成的日期，之后重听不改，免得一本书被算进别的月份
    mutating func markFinished(bookId: String, at date: Date = Date(), calendar: Calendar = .current) {
        guard finished[bookId] == nil else { return }
        finished[bookId] = Self.dayKey(date, calendar: calendar)
    }

    /// 书被删除时清掉它的收听秒数与听完记录（按天的统计保留，历史时长不动）
    mutating func removeBook(_ bookId: String) {
        byBook[bookId] = nil
        finished[bookId] = nil
    }

    /// 日期分桶的键：用公历分量手工拼，避免 DateFormatter 这种非 Sendable 的全局量
    static func dayKey(_ date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    /// 月份分桶的键（yyyy-MM），拿去问 seconds(in:) 就是本月的量
    static func monthKey(_ date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month], from: date)
        return String(format: "%04d-%02d", parts.year ?? 0, parts.month ?? 0)
    }

    /// 年份分桶的键（yyyy）；日分桶键是定宽四位年开头，所以这个前缀只会命中这一年
    static func yearKey(_ date: Date, calendar: Calendar = .current) -> String {
        String(format: "%04d", calendar.component(.year, from: date))
    }

    private enum CodingKeys: String, CodingKey {
        case daily, byBook, finished
    }

    init() {}

    /// 逐键缺省解：老文件里没 finished（甚至没某一块），缺哪个就按空处理。
    /// 合成解码会要求每个键都在，一旦缺键整份 progress.json 都解不出来，
    /// 而解不出来时书库会拿默认值继续落盘，等于把用户的进度与统计全清空
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        daily = try values.decodeIfPresent([String: Double].self, forKey: .daily) ?? [:]
        byBook = try values.decodeIfPresent([String: Double].self, forKey: .byBook) ?? [:]
        finished = try values.decodeIfPresent([String: String].self, forKey: .finished) ?? [:]
    }
}

/// 某一天的收听时长，供「我」页的时长统计使用
struct ListeningDay: Identifiable, Equatable {
    let date: Date
    let seconds: TimeInterval

    var id: Date { date }
}
