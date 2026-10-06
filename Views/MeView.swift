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
                    VStack(spacing: 14) {
                        TotalCard(summary: summary)
                        // 本月没听也没听完就不摆空卡，年度报告的入口跟着本月卡走
                        if summary.hasMonthActivity {
                            MonthCard(summary: summary)
                        }
                    }
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

/// 设置卡片：语言与播放两行，样式与累计时长卡片一致
private struct SettingsCard: View {
    @ObservedObject private var settings = PlaybackSettings.shared

    var body: some View {
        VStack(spacing: 0) {
            NavigationLink {
                LanguageView()
            } label: {
                settingsRow(id: "me-language-row",
                            title: L("Language"),
                            value: AppLanguageSetting.followsSystem
                                 ? L("System Default")
                                 : AppLanguageSetting.all.first { $0.code == AppLanguageSetting.effectiveCode }?.nativeName ?? AppLanguageSetting.effectiveCode)
            }
            hairline

            NavigationLink {
                PlaybackSettingsView()
            } label: {
                // 尾巴上只报跳过静音的档位：它是会挪播放位置的那一项，最值得先看一眼
                settingsRow(id: "me-playback-row",
                            title: L("Playback"),
                            value: L(settings.silenceMode.labelKey))
            }
        }
        // 两行都别长成系统蓝链接：卡片里的导航沿用整卡点击的原样式
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color(.secondarySystemGroupedBackground)))
    }

    private func settingsRow(id: String, title: String, value: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        // 先声明「这一行是一个整体」再挂标识：不然 SwiftUI 会把整卡两行并成一个元素，
        // 标识只剩最外层那个，自动化点不到具体一行
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(id)
    }

    /// 行间细线：卡片里两行之间要有归属关系，但分隔线不该顶到卡片边
    private var hairline: some View {
        Rectangle()
            .fill(Color(.separator))
            .frame(height: 0.5)
            .padding(.leading, 16)
            .padding(.vertical, 2)
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

                ListeningBarChart(values: summary.recentDays.map(\.seconds),
                                  peakFloor: Self.dailyGoalSeconds,
                                  highlightIndex: summary.recentDays.count - 1)
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
}

/// 本月卡：本月的收听时长与听完的本数，点进去是今年的收听报告
/// 样式跟累计卡一致（小标题 + 分栏指标），只占两栏
private struct MonthCard: View {
    let summary: LibraryService.ListeningSummary

    var body: some View {
        NavigationLink {
            ListeningReportView()
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                Text(L("This Month"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                HStack(spacing: 0) {
                    StatItem(title: L("Listening Time"), value: TimeFormat.duration(summary.monthSeconds))
                    StatItem(title: L("Books Finished"), value: LF("%d Books", summary.monthFinished))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(RoundedRectangle(cornerRadius: 14).fill(Color(.secondarySystemGroupedBackground)))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("me-month-card")
    }
}

/// 一个指标：上值下标题，几列平分卡片宽度（累计卡三列、本月卡两列都用它）
struct StatItem: View {
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

/// 柱状图：一格一根浅底柱，实心部分才是那格的量（近 7 天与逐月都用它）
struct ListeningBarChart: View {
    /// 每格一根柱子的秒数，从旧到新
    let values: [Double]
    /// 标尺下限：近 7 天拿每日目标当下限，柱子才跟目标可比；年度报告传 0，按最高那格算
    let peakFloor: Double
    /// 实心那一格的下标（今天 / 本月），其余半透明
    let highlightIndex: Int?

    var body: some View {
        GeometryReader { proxy in
            HStack(spacing: 0) {
                ForEach(values.indices, id: \.self) { index in
                    ZStack(alignment: .bottom) {
                        // 浅底柱表示这一格的满值，实心部分才是当天时长
                        Capsule()
                            .fill(Color.indigo.opacity(0.1))
                            .frame(width: 12)

                        Capsule()
                            .fill(index == highlightIndex ? Color.indigo : Color.indigo.opacity(0.4))
                            .frame(width: 12, height: barHeight(values[index], in: proxy.size.height))
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        }
    }

    /// 没听的那格为 0，秒数直接按比例化成柱高
    private var peak: Double {
        max(values.max() ?? 0, peakFloor, 1)
    }

    /// 柱高按标尺等比缩放；只要那格听过就至少留 4pt，别让几分钟的收听在图上看不见
    private func barHeight(_ seconds: Double, in height: CGFloat) -> CGFloat {
        guard seconds > 0 else { return 0 }
        return max(height * CGFloat(min(seconds / peak, 1)), min(4, height))
    }
}
