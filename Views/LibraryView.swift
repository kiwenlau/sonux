import SwiftUI
import UniformTypeIdentifiers

struct LibraryView: View {
    @EnvironmentObject private var library: LibraryService
    @EnvironmentObject private var player: PlayerService
    @State private var showImporter = false
    @State private var importMessage: String?
    @State private var bookToDelete: Book?
    @State private var deleteErrorMessage: String?

    var body: some View {
        Group {
            if library.books.isEmpty {
                EmptyLibraryView(onImport: { showImporter = true })
            } else {
                List {
                    ForEach(library.books) { book in
                        NavigationLink(value: book.id) {
                            BookRow(book: book, position: library.position(forBook: book.id))
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button(role: .destructive) {
                                NSLog("[sonux] ui: 点击滑动删除按钮《%@》", book.title)
                                bookToDelete = book
                            } label: {
                                Label("删除", systemImage: "trash")
                            }
                        }
                        .contextMenu {
                            Button(role: .destructive) {
                                NSLog("[sonux] ui: 点击长按菜单删除《%@》", book.title)
                                bookToDelete = book
                            } label: {
                                Label("删除", systemImage: "trash")
                            }
                        }
                        .accessibilityIdentifier("book-row-\(book.id)")
                    }
                }
                .listStyle(.plain)
                .navigationDestination(for: String.self) { bookId in
                    if let book = library.book(id: bookId) {
                        BookDetailView(book: book)
                    }
                }
            }
        }
        .navigationTitle("书库")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showImporter = true
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .fileImporter(
            isPresented: $showImporter,
            allowedContentTypes: [.audio, .folder],
            allowsMultipleSelection: true
        ) { result in
            handleImport(result)
        }
        .alert("导入完成", isPresented: Binding(
            get: { importMessage != nil },
            set: { if !$0 { importMessage = nil } }
        )) {
            Button("好", role: .cancel) { importMessage = nil }
        } message: {
            Text(importMessage ?? "")
        }
        .alert("删除「\(bookToDelete?.title ?? "")」", isPresented: Binding(
            get: { bookToDelete != nil },
            set: { if !$0 { bookToDelete = nil } }
        )) {
            Button("取消", role: .cancel) { bookToDelete = nil }
            Button("删除", role: .destructive) {
                NSLog("[sonux] ui: 确认弹窗点了删除《%@》", bookToDelete?.title ?? "?")
                if let book = bookToDelete {
                    do {
                        try library.delete(
                            book: book,
                            playingBookId: player.currentBook?.id
                        ) { player.stop() }
                    } catch {
                        NSLog("[sonux] ui: 删除抛出错误 %@", error.localizedDescription)
                        deleteErrorMessage = error.localizedDescription
                    }
                }
                bookToDelete = nil
            }
        } message: {
            Text("将从书库中移除该音频文件，此操作不可撤销。")
        }
        .alert("删除失败", isPresented: Binding(
            get: { deleteErrorMessage != nil },
            set: { if !$0 { deleteErrorMessage = nil } }
        )) {
            Button("好", role: .cancel) { deleteErrorMessage = nil }
        } message: {
            Text(deleteErrorMessage ?? "")
        }
    }

    private func handleImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            let count = library.importItems(from: urls)
            if count == 0 {
                importMessage = "没有可导入的音频（支持 m4a / m4b / mp3 / aac / wav 或含这些文件的文件夹）"
            } else {
                importMessage = "已导入 \(count) 项"
            }
        case .failure:
            importMessage = "导入失败，请重试"
        }
    }
}

private struct BookRow: View {
    let book: Book
    let position: PlayPosition?

    private var progressText: String {
        guard let position,
              let chapter = book.chapters.first(where: { $0.id == position.chapterId }) else {
            return "未开始 · \(TimeFormat.duration(book.totalDuration))"
        }
        let finished = ProgressPolicy.isFinished(time: position.time, duration: chapter.duration)
        let isLastChapter = chapter.index == book.chapters.count - 1
        if finished && isLastChapter {
            return "已听完"
        }
        let chapterProgress = position.time / max(chapter.duration, 1)
        return "第 \(chapter.index + 1) 章 · 进度 \(Int(chapterProgress * 100))%"
    }

    private var progressValue: Double? {
        guard let position,
              let chapter = book.chapters.first(where: { $0.id == position.chapterId }) else {
            return nil
        }
        return min(max(position.time / max(chapter.duration, 1), 0), 1)
    }

    var body: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.indigo.opacity(0.15))
                .frame(width: 50, height: 50)
                .overlay {
                    Image(systemName: book.chapters.count > 1 ? "books.vertical.fill" : "music.note")
                        .foregroundStyle(.indigo)
                }

            VStack(alignment: .leading, spacing: 4) {
                Text(book.title)
                    .font(.headline)
                    .lineLimit(2)
                Text(progressText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let progressValue {
                    ProgressView(value: progressValue)
                        .progressViewStyle(.linear)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

private struct EmptyLibraryView: View {
    @EnvironmentObject private var library: LibraryService
    let onImport: () -> Void

    var body: some View {
        ContentUnavailableWrapper(
            title: "书库是空的",
            action: {
                Button {
                    onImport()
                } label: {
                    Label("导入音频", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)

                Button("重新扫描") { library.rescan() }
                    .buttonStyle(.bordered)
            }
        )
    }
}

struct ContentUnavailableWrapper<ActionView: View>: View {
    let title: String
    var message: String = ""
    @ViewBuilder let action: () -> ActionView

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "tray.and.arrow.down.fill")
                .font(.system(size: 48))
                .foregroundStyle(.indigo)
            Text(title)
                .font(.title2.bold())
            if !message.isEmpty {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }
            action()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
