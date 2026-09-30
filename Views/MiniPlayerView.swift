import SwiftUI

struct MiniPlayerView: View {
    @EnvironmentObject private var player: PlayerService
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                Image(systemName: "music.note.list")
                    .font(.title2)
                    .foregroundStyle(.indigo)
                    .frame(width: 40, height: 40)
                    .background(Color.indigo.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))

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
                Rectangle()
                    .fill(Color.indigo)
                    .frame(height: 2)
                    .offset(x: geo.size.width * CGFloat(min(max(progress, 0), 1)))
            }
            .frame(height: 2)
            .clipShape(Rectangle())
            .allowsHitTesting(false)
        }
    }
}
