import SwiftUI

/// 「我」页：收听的累计时长统计（微信读书式的简洁卡片）
/// 数据来自播放器每秒上报的真实收听秒数，随播放进度一起落盘
struct MeView: View {
    @EnvironmentObject private var library: LibraryService

    var body: some View {
        let summary = library.listeningSummary()
        VStack(spacing: 0) {
            if summary.isEmpty {
                ContentUnavailableWrapper(
                    title: L("No Listening Records Yet"),
                    systemImage: "person"
                ) { EmptyView() }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    TotalCard(summary: summary)
                        .padding(14)
                }
            }
            // 设置卡片常驻底部，空态时也能进语言设置
            SettingsCard()
                .padding(.horizontal, 14)
                .padding(.bottom, 14)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemGroupedBackground))
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
        .padding(.vertical, 4)
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color(.secondarySystemGroupedBackground)))
        .accessibilityIdentifier("me-language-row")
    }
}

/// 累计时长卡片：大数字加今天 / 近 7 天 / 连续天数三个小指标
private struct TotalCard: View {
    let summary: LibraryService.ListeningSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L("Total Listening"))
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Text(TimeFormat.duration(summary.totalSeconds))
                .font(.system(size: 30, weight: .bold, design: .rounded))
                .foregroundStyle(Color.indigo)
                .accessibilityIdentifier("me-total")

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
