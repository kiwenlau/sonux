import SwiftUI

struct BookDetailView: View {
    let book: Book
    @EnvironmentObject private var library: LibraryService
    @EnvironmentObject private var player: PlayerService
    @EnvironmentObject private var router: AppRouter
    @ObservedObject private var coverStore = CoverStore.shared

    var body: some View {
        List {
            // MARK: - 顶部书籍信息区
            BookInfoHeader(
                book: book,
                coverImage: coverStore.image(for: book),
                openAuthor: { if let author = book.author { router.openAuthor(author) } }
            )
                .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                .listRowSeparator(.hidden)

            // MARK: - 章节列表
            ForEach(book.chapters) { chapter in
                ChapterRow(
                    chapter: chapter,
                    isCurrent: player.currentBook?.id == book.id && player.currentChapter?.id == chapter.id,
                    isPlaying: player.isPlaying,
                    position: library.position(forChapter: chapter.id)
                )
                .swipeActions {
                    Button("重置进度") {
                        library.resetChapterProgress(chapterId: chapter.id)
                    }
                    .tint(.orange)
                }
                .contentShape(Rectangle())
                .listRowSeparator(.hidden)
                .onTapGesture {
                    let resume = library.position(forChapter: chapter.id)
                        .map { ProgressPolicy.resumeTime(time: $0.time, duration: chapter.duration) }
                        ?? 0
                    player.play(chapter: chapter, book: book, fromTime: resume)
                    player.showPlayer = true
                }
            }
        }
        .listStyle(.plain)
        .navigationTitle(book.title)
        .navigationBarTitleDisplayMode(.inline)
        .background(TransparentNavigationBar())
        .task(id: book.id) {
            await coverStore.load(for: book)
        }
    }
}

/// Apple Music 风格的书籍信息头部：大封面 + 书名 + 作者 + 章节数/总时长
private struct BookInfoHeader: View {
    let book: Book
    let coverImage: UIImage?
    /// 点作者名跳作者页
    let openAuthor: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            // 封面
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.gray.opacity(0.1))
                    .frame(width: 220, height: 220 * (4.0 / 3.0))

                if let cover = coverImage {
                    Image(uiImage: cover)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: 220, maxHeight: 220 * (4.0 / 3.0))
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                } else {
                    Image(systemName: book.chapters.count > 1 ? "books.vertical.fill" : "music.note")
                        .font(.system(size: 56))
                        .foregroundStyle(.indigo)
                }
            }
            .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
            .padding(.top, 20)

            // 书名
            Text(book.title)
                .font(.title2.bold())
                .multilineTextAlignment(.center)
                .padding(.horizontal, 20)

            // 作者：染成主题色提示可点，跳该作者的作品页
            if let author = book.author, !author.isEmpty {
                Button(action: openAuthor) {
                    Text(author)
                        .font(.headline)
                        .foregroundStyle(.indigo)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("查看作者「\(author)」的全部书籍")
            }

            Spacer().frame(height: 8)
        }
        .frame(maxWidth: .infinity)
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
    /// 本章是否为当前播放的章节（无论暂停与否）
    let isCurrent: Bool
    /// 当前是否处于播放中（控制音柱是否跳动）
    let isPlaying: Bool
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
                // 与书库卡片/列表行用同一套音柱标记，播放时跳动、暂停时静止
                NowPlayingBars(height: 16, isPlaying: isPlaying)
                    .accessibilityLabel("正在播放")
            }
        }
        .padding(.leading, 6)
    }
}
