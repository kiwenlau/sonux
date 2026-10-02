import SwiftUI

/// 「我」页：收听的累计时长统计（微信读书式的简洁卡片）
/// 数据来自播放器每秒上报的真实收听秒数，随播放进度一起落盘
struct MeView: View {
    @EnvironmentObject private var library: LibraryService
    /// 从收听排行跳详情页：压进「我」这个 tab 自己的导航栈
    let onOpenBook: (String) -> Void

    var body: some View {
        let summary = library.listeningSummary()
        Group {
            if summary.isEmpty {
                ContentUnavailableWrapper(
                    title: "还没有收听记录",
                    message: "去书库或历史页挑一本书开始收听，这里会累计你的收听时长",
                    systemImage: "person"
                ) { EmptyView() }
            } else {
                ScrollView {
                    VStack(spacing: 14) {
                        TotalCard(summary: summary)
                        WeekChartCard(days: summary.recentDays)
                        DetailCard(summary: summary)
                        if !summary.topBooks.isEmpty {
                            TopBooksCard(items: summary.topBooks, onOpenBook: onOpenBook)
                        }
                    }
                    .padding(14)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemGroupedBackground))
        .navigationTitle("我的收听")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("me-page")
    }
}

/// 累计时长卡片：大数字加今天 / 近 7 天 / 连续天数三个小指标
private struct TotalCard: View {
    let summary: LibraryService.ListeningSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("累计收听")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Text(TimeFormat.duration(summary.totalSeconds))
                .font(.system(size: 30, weight: .bold, design: .rounded))
                .foregroundStyle(Color.indigo)
                .accessibilityIdentifier("me-total")

            HStack(spacing: 0) {
                StatItem(title: "今天", value: TimeFormat.duration(summary.todaySeconds))
                StatItem(title: "近 7 天", value: TimeFormat.duration(summary.last7Seconds))
                StatItem(title: "连续收听", value: "\(summary.streakDays) 天")
            }
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color(.secondarySystemGroupedBackground)))
    }

    /// 一个指标：上值下标题，三列平分卡片宽度
    private struct StatItem: View {
        let title: String
        let value: String

        var body: some View {
            VStack(alignment: .leading, spacing: 4) {
                Text(value)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// 近 7 天柱状图：每天一根柱子，今天用实心主题色
private struct WeekChartCard: View {
    let days: [ListeningDay]

    /// 柱子区域高度，最长的一天铺满
    private static let chartHeight: CGFloat = 72

    var body: some View {
        Card(title: "近 7 天") {
            let peak = max(days.map(\.seconds).max() ?? 0, 1)
            HStack(alignment: .bottom, spacing: 8) {
                ForEach(days) { day in
                    DayBar(day: day, peak: peak, isToday: Calendar.current.isDateInToday(day.date))
                }
            }
            .frame(height: Self.chartHeight + 34)
        }
    }
}

/// 一根柱子：顶部秒数、中间柱体按峰值等比、底部星期
private struct DayBar: View {
    let day: ListeningDay
    /// 这周最长那天的秒数，用来算柱高
    let peak: TimeInterval
    let isToday: Bool

    private static let chartHeight: CGFloat = 72

    var body: some View {
        VStack(spacing: 6) {
            Text(day.seconds >= 60 ? TimeFormat.compact(day.seconds) : " ")
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.6)

            Spacer(minLength: 0)

            RoundedRectangle(cornerRadius: 3)
                .fill(isToday ? Color.indigo : Color.indigo.opacity(0.25))
                .frame(height: barHeight)

            Text(day.date.formatted(.dateTime.weekday(.narrow)))
                .font(.system(size: 10))
                .foregroundStyle(isToday ? Color.indigo : Color.secondary)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(day.date.formatted(date: .abbreviated, time: .omitted)) 收听 \(TimeFormat.duration(day.seconds))")
    }

    /// 柱高按当天与峰值的比例，有收听就留 4pt 以上，别看不见
    private var barHeight: CGFloat {
        guard day.seconds > 0 else { return 2 }
        return max(4, DayBar.chartHeight * CGFloat(day.seconds / max(peak, 1)))
    }
}

/// 收听明细：收听天数、听过的书、平均每天
private struct DetailCard: View {
    let summary: LibraryService.ListeningSummary

    var body: some View {
        Card(title: "收听明细") {
            VStack(spacing: 0) {
                DetailRow(title: "收听天数", value: "\(summary.listenedDays) 天")
                DetailRow(title: "听过的书", value: "\(summary.listenedBookCount) 本")
                DetailRow(title: "平均每天", value: TimeFormat.duration(summary.averagePerDay), isLast: true)
            }
        }
    }
}

private struct DetailRow: View {
    let title: String
    let value: String
    var isLast = false

    var body: some View {
        HStack {
            Text(title)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.subheadline)
        }
        .padding(.vertical, 9)
        .overlay(alignment: .bottom) {
            if !isLast {
                Rectangle().fill(Color(.separator)).frame(height: 0.5)
            }
        }
    }
}

/// 收听最多的书：点书名进详情页
private struct TopBooksCard: View {
    let items: [ListenedBook]
    let onOpenBook: (String) -> Void

    var body: some View {
        Card(title: "收听最多") {
            VStack(spacing: 10) {
                ForEach(items) { item in
                    Button {
                        NSLog("[sonux] ui: 我页点收听排行《%@》", item.book.title)
                        onOpenBook(item.book.id)
                    } label: {
                        HStack(spacing: 10) {
                            BookCoverView(book: item.book)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(item.book.title)
                                    .font(.subheadline)
                                    .foregroundStyle(Color.primary)
                                    .lineLimit(2)
                                    .multilineTextAlignment(.leading)
                                Text("收听 \(TimeFormat.duration(item.seconds))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("me-book-\(item.book.id)")
                }
            }
        }
    }
}

/// 通用白底圆角卡片：一个标题加任意内容
private struct Card<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color(.secondarySystemGroupedBackground)))
    }
}
