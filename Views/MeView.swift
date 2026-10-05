import SwiftUI

/// 「我」页：收听的累计时长统计（微信读书式的简洁卡片）
/// 数据来自播放器每秒上报的真实收听秒数，随播放进度一起落盘
struct MeView: View {
    @EnvironmentObject private var library: LibraryService

    var body: some View {
        let summary = library.listeningSummary()
        VStack(spacing: 14) {
            // 设置卡片放最上方，空态时也能进语言设置
            SettingsCard()
            if summary.isEmpty {
                ContentUnavailableWrapper(
                    title: L("No Listening Records Yet"),
                    systemImage: "person"
                ) { EmptyView() }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    TotalCard(summary: summary)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // 底色铺进状态栏与导航栏，与书库、历史页一致
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
        .toolbarBackground(.hidden, for: .navigationBar)
        .navigationTitle(L("Me"))
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("me-page")
    }
}

/// 设置卡片：目前只有语言一项，样式与累计时长卡片一致
private struct SettingsCard: View {
    var body: some View {
        NavigationLink {
            LanguageView()
        } label: {
            HStack {
                Text(L("Language"))
                Spacer()
                Text(AppLanguageSetting.followsSystem
                     ? L("System Default")
                     : AppLanguageSetting.all.first { $0.code == AppLanguageSetting.effectiveCode }?.nativeName ?? AppLanguageSetting.effectiveCode)
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.vertical, 4)
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color(.secondarySystemGroupedBackground)))
        .accessibilityIdentifier("me-language-row")
    }
}

/// 累计时长卡片：大数字 + 今日目标环与近 7 天柱状图 + 今天 / 近 7 天 / 连续天数三个小指标
/// 目标环和柱状图都只有图形、不放文字，数值由下方三个指标承载
private struct TotalCard: View {
    let summary: LibraryService.ListeningSummary

    /// 每日收听目标：半小时（目标环按今天的收听时长占它的比例填充）
    private static let dailyGoalSeconds: TimeInterval = 30 * 60

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L("Total Listening"))
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Text(TimeFormat.duration(summary.totalSeconds))
                .font(.system(size: 30, weight: .bold, design: .rounded))
                .foregroundStyle(Color.indigo)
                .accessibilityIdentifier("me-total")

            HStack(spacing: 16) {
                GoalRing(progress: summary.todaySeconds / Self.dailyGoalSeconds)
                    .frame(width: 64, height: 64)
                    .accessibilityLabel(L("Today"))
                    .accessibilityValue(TimeFormat.duration(summary.todaySeconds))
                    .accessibilityIdentifier("me-goal-ring")

                WeekBarChart(days: summary.recentDays, goalSeconds: Self.dailyGoalSeconds)
                    .frame(maxWidth: .infinity)
                    .frame(height: 64)
                    .accessibilityLabel(L("Last 7 Days"))
                    .accessibilityValue(TimeFormat.duration(summary.last7Seconds))
                    .accessibilityIdentifier("me-week-bars")
            }

            HStack(spacing: 0) {
                StatItem(title: L("Today"), value: TimeFormat.duration(summary.todaySeconds))
                StatItem(title: L("Last 7 Days"), value: TimeFormat.duration(summary.last7Seconds))
                StatItem(title: L("Listening Streak"), value: LF("%d days", summary.streakDays))
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

/// 今日目标环：浅紫底圈是整天的目标，深紫弧线是今天已经完成的进度（从 12 点起顺时针）
private struct GoalRing: View {
    /// 完成度 0...1，超过目标按满环算
    let progress: Double

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.indigo.opacity(0.12), lineWidth: 8)

            if fraction >= 1 {
                // 满环不裁切，免得首尾相接处留下一道接缝
                Circle()
                    .stroke(Color.indigo, lineWidth: 8)
            } else {
                Circle()
                    .trim(from: 0, to: fraction)
                    .stroke(
                        AngularGradient(
                            colors: [Color.indigo.opacity(0.4), Color.indigo],
                            center: .center,
                            startAngle: .degrees(0),
                            endAngle: .degrees(360)
                        ),
                        style: StrokeStyle(lineWidth: 8, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
            }
        }
    }

    /// 夹到 0...1，脏数据（NaN、负数）当没听处理
    private var fraction: Double {
        let raw = progress
        guard raw.isFinite else { return 0 }
        return min(max(raw, 0), 1)
    }
}

/// 近 7 天柱状图：从旧到新排列，今天那根实心，其余半透明；标尺取「本周最高的一天」与「每日目标」的较大者
private struct WeekBarChart: View {
    let days: [ListeningDay]
    let goalSeconds: TimeInterval

    var body: some View {
        GeometryReader { proxy in
            HStack(spacing: 0) {
                ForEach(Array(days.enumerated()), id: \.element.id) { index, day in
                    ZStack(alignment: .bottom) {
                        // 浅底柱表示这一格的满值，实心部分才是当天时长
                        Capsule()
                            .fill(Color.indigo.opacity(0.1))
                            .frame(width: 12)

                        Capsule()
                            .fill(index == days.count - 1 ? Color.indigo : Color.indigo.opacity(0.4))
                            .frame(width: 12, height: barHeight(day.seconds, in: proxy.size.height))
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        }
    }

    /// 没听的那天为 0，秒数直接按比例化成柱高
    private var peak: TimeInterval {
        max(days.map(\.seconds).max() ?? 0, goalSeconds, 1)
    }

    /// 柱高按标尺等比缩放；只要那天听过就至少留 4pt，别让几分钟的收听在图上看不见
    private func barHeight(_ seconds: TimeInterval, in height: CGFloat) -> CGFloat {
        guard seconds > 0 else { return 0 }
        return max(height * CGFloat(min(seconds / peak, 1)), min(4, height))
    }
}
