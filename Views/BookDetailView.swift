import SwiftUI

struct BookDetailView: View {
    let book: Book
    @EnvironmentObject private var library: LibraryService
    @EnvironmentObject private var player: PlayerService

    var body: some View {
        List {
            Section {
                Button {
                    player.play(book: book, at: library.position(forBook: book.id))
                } label: {
                    Label(resumeTitle, systemImage: "play.fill")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                }
                .listRowBackground(Color.indigo.opacity(0.12))
            }

            Section("章节 · \(book.chapters.count)") {
                ForEach(book.chapters) { chapter in
                    ChapterRow(
                        chapter: chapter,
                        isCurrent: player.currentChapter?.id == chapter.id,
                        position: library.position(forBook: book.id)
                    )
                    .swipeActions {
                        Button("重置进度") {
                            library.recordPosition(PlayPosition(chapterId: chapter.id, time: 0), bookId: book.id)
                        }
                        .tint(.orange)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        player.play(chapter: chapter, book: book)
                    }
                }
            }
        }
        .navigationTitle(book.title)
        .navigationBarTitleDisplayMode(.inline)
    }

    private var resumeTitle: String {
        guard let position = library.position(forBook: book.id),
              let chapter = book.chapters.first(where: { $0.id == position.chapterId }) else {
            return "播放"
        }
        if ProgressPolicy.isFinished(time: position.time, duration: chapter.duration)
            && chapter.index == book.chapters.count - 1 {
            return "从头播放"
        }
        return "继续收听 · 第 \(chapter.index + 1) 章"
    }
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
            return "听到 \(TimeFormat.time(chapterTime)) / \(TimeFormat.time(chapter.duration))"
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
