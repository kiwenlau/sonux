import SwiftUI

/// 收听报告页：把今年的收听汇总成一张卡片，年底回看用
/// 数字随进度落盘一起更新，所以在页面上继续听，数值会跟着长
struct ListeningReportView: View {
    @EnvironmentObject private var library: LibraryService

    var body: some View {
        let report = library.listeningReport()
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text(TimeFormat.duration(report.totalSeconds))
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.indigo)
                    .accessibilityIdentifier("report-total")

                // 逐月分布照旧只给图形，一个字都不加；实心那根是本月
                ListeningBarChart(values: report.monthly,
                                  peakFloor: 0,
                                  highlightIndex: report.currentMonth)
                    .frame(maxWidth: .infinity)
                    .frame(height: 64)
                    .accessibilityLabel(LF("%d Listening Report", report.year))
                    .accessibilityValue(TimeFormat.duration(report.totalSeconds))
                    .accessibilityIdentifier("report-month-bars")

                HStack(spacing: 0) {
                    StatItem(title: L("Days Listened"), value: LF("%d days", report.daysListened))
                    StatItem(title: L("Books Finished"), value: LF("%d Books", report.booksFinished))
                }
                .padding(.top, 4)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(RoundedRectangle(cornerRadius: 14).fill(Color(.secondarySystemGroupedBackground)))
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // 底色铺进状态栏与导航栏，与「我」页一致
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
        .toolbarBackground(.hidden, for: .navigationBar)
        .navigationTitle(LF("%d Listening Report", report.year))
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("listening-report")
    }
}
