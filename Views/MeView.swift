import SwiftUI

/// 「我」页：收听的累计时长统计（微信读书式的简洁卡片）
/// 数据来自播放器每秒上报的真实收听秒数，随播放进度一起落盘
struct MeView: View {
    @EnvironmentObject private var library: LibraryService

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
                    TotalCard(summary: summary)
                        .padding(14)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemGroupedBackground))
        .navigationTitle("我的")
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
