import SwiftUI

struct BookDetailView: View {
    let book: Book
    @EnvironmentObject private var library: LibraryService
    @EnvironmentObject private var player: PlayerService

    var body: some View {
        List {
            ForEach(book.chapters) { chapter in
                ChapterRow(
                    chapter: chapter,
                    isCurrent: player.currentChapter?.id == chapter.id,
                    position: library.position(forChapter: chapter.id)
                )
                .swipeActions {
                    Button("重置进度") {
                        library.resetChapterProgress(chapterId: chapter.id)
                    }
                    .tint(.orange)
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    // 默认从该音频的历史播放位置续播
                    let resume = library.position(forChapter: chapter.id)
                        .map { ProgressPolicy.resumeTime(time: $0.time, duration: chapter.duration) }
                        ?? 0
                    player.play(chapter: chapter, book: book, fromTime: resume)
                    player.showPlayer = true
                }
            }
        }
        .padding(.top, -30)
        .navigationTitle(book.title)
        .navigationBarTitleDisplayMode(.inline)
        .background(TransparentNavigationBar())
    }
}

/// 只让当前页的导航栏透明，去掉标题与列表之间的大段间距
private struct TransparentNavigationBar: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> UIViewController {
        let vc = UIViewController()
        DispatchQueue.main.async {
            guard let bar = vc.navigationController?.navigationBar else { return }
            let appearance = UINavigationBarAppearance()
            appearance.configureWithTransparentBackground()
            bar.standardAppearance = appearance
            bar.compactAppearance = appearance
            bar.scrollEdgeAppearance = appearance
        }
        return vc
    }

    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {}
}

private struct ChapterRow: View {
    let chapter: Chapter
    let isCurrent: Bool
    let position: PlayPosition?

    private var chapterTime: TimeInterval {
        guard let position, position.chapterId == chapter.id else { return 0 }
        return position.time
    }

    private var stateText: String {
        if ProgressPolicy.isFinished(time: chapterTime, duration: chapter.duration) {
            return "已听完"
        }
        if ProgressPolicy.isStarted(chapterTime) {
            return "\(TimeFormat.time(chapterTime)) / \(TimeFormat.time(chapter.duration))"
        }
        return TimeFormat.time(chapter.duration)
    }

    var body: some View {
        HStack(spacing: 12) {
            Text("\(chapter.index + 1)")
                .font(.system(.body, design: .rounded).monospacedDigit())
                .foregroundStyle(isCurrent ? Color.indigo : Color.secondary)
                .frame(width: 28, alignment: .leading)

            VStack(alignment: .leading, spacing: 3) {
                Text(chapter.title)
                    .font(.body)
                    .foregroundStyle(isCurrent ? .indigo : .primary)
                Text(stateText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if isCurrent {
                Image(systemName: "speaker.wave.2.fill")
                    .foregroundStyle(.indigo)
            }
        }
    }
}
