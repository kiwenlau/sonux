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

struct MiniPlayerView: View {
    @EnvironmentObject private var player: PlayerService
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                // 左侧书籍封面：与书库列表行共用同一缩略图，无封面时自动退回图标占位
                if let book = player.currentBook {
                    BookCoverView(book: book)
                } else {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.gray.opacity(0.1))
                        .frame(width: 50, height: 50)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(player.currentBook?.title ?? "")
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Text(player.currentChapter?.title ?? "")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                Button {
                    player.previousChapter()
                } label: {
                    Image(systemName: "backward.fill")
                }
                .buttonStyle(.plain)

                Button {
                    player.togglePlayPause()
                } label: {
                    Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 34))
                }
                .buttonStyle(.plain)

                Button {
                    player.nextChapter()
                } label: {
                    Image(systemName: "forward.fill")
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.bar)
        }
        .overlay(alignment: .top) {
            GeometryReader { geo in
                let progress = player.duration > 0 ? player.currentTime / player.duration : 0
                // 已播放部分（左侧）着色：从 0 开始，宽度随进度增长
                Rectangle()
                    .fill(Color.indigo)
                    .frame(width: geo.size.width * CGFloat(min(max(progress, 0), 1)), height: 2)
            }
            .frame(height: 2)
            .clipShape(Rectangle())
            .allowsHitTesting(false)
        }
    }
}
