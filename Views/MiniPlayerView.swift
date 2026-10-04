import SwiftUI

/// 「正在播放」音柱标记：播放时四根柱子跳动，暂停时静止成固定高度
/// 供播放器收起条、书库列表行、书库卡片共用，保证三处视觉一致
struct NowPlayingBars: View {
    var height: CGFloat = 14
    let isPlaying: Bool

    /// 暂停时四根柱子的静态高度比例，避免全部一样高看着像进度条
    private static let restingPattern: [CGFloat] = [0.45, 0.9, 0.6, 1]

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 20.0, paused: !isPlaying)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(alignment: .center, spacing: max(1.5, height * 0.14)) {
                ForEach(0..<Self.restingPattern.count, id: \.self) { i in
                    Capsule()
                        .fill(Color.indigo)
                        .frame(width: max(2, height * 0.18), height: height * barScale(t: t, index: i))
                }
            }
            .frame(height: height, alignment: .center)
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }

    private func barScale(t: TimeInterval, index: Int) -> CGFloat {
        guard isPlaying else { return Self.restingPattern[index] }
        // 每根柱子不同相位 + 不同速度，跳起来更像真实电平表
        let wave = sin(t * 5.4 + Double(index) * 0.9) + 0.35 * sin(t * 9.1 + Double(index) * 1.7)
        let normalized = min(max(0.5 + 0.5 * wave, 0), 1)
        return 0.35 + 0.65 * CGFloat(normalized)
    }
}

/// 底部「继续收听」条：参考微信读书——小封面 + 两行标题、右侧一个带进度环的播放按钮。
/// 切章在播放页里做，这里不放按钮。
/// 左边（封面+标题）与播放按钮是两个平级的独立按钮：包成一整个按钮会把播放按钮
/// 在无障碍树里合并掉，只剩「打开播放页」一个操作
struct MiniPlayerView: View {
    @EnvironmentObject private var player: PlayerService
    let onTap: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Button(action: onTap) {
                HStack(spacing: 10) {
                    // 左侧书籍封面：不铺底色，封面之外直接露出条的背景
                    if let book = player.currentBook {
                        BookCoverView(book: book, size: 40, background: nil)
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        Text(player.currentBook?.title ?? "")
                            .font(.footnote.weight(.semibold))
                            .lineLimit(1)
                        Text(player.currentChapter?.title ?? "")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    Spacer(minLength: 8)
                }
                .contentShape(Rectangle())
            }
            .accessibilityIdentifier("mini-open-player")

            MiniPlayButton(
                progress: player.duration > 0 ? player.currentTime / player.duration : 0,
                isPlaying: player.isPlaying
            ) {
                player.togglePlayPause()
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 52)
        .background(.bar)
    }
}

/// 播放/暂停按钮：外圈一整条浅色轨道 + 一条随进度增长的实心弧，中间是播放符号
struct MiniPlayButton: View {
    /// 本章已播进度 0...1
    let progress: Double
    let isPlaying: Bool
    let action: () -> Void

    private static let side: CGFloat = 34
    private static let lineWidth: CGFloat = 2.5

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .stroke(Color.secondary.opacity(0.25), lineWidth: Self.lineWidth)
                Circle()
                    .trim(from: 0, to: CGFloat(min(max(progress, 0), 1)))
                    .stroke(
                        Color.indigo,
                        style: StrokeStyle(lineWidth: Self.lineWidth, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.indigo)
                    // 三角形重心偏左，往右挪一点才真正居中
                    .offset(x: isPlaying ? 0 : 1)
            }
            .frame(width: Self.side, height: Self.side)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("mini-play")
        .accessibilityLabel(isPlaying ? L("Pause") : L("Play"))
    }
}
