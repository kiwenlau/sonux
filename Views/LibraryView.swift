import SwiftUI
import UniformTypeIdentifiers

struct LibraryView: View {
    @EnvironmentObject private var library: LibraryService
    @EnvironmentObject private var player: PlayerService
    /// 书库 → 详情页的导航栈路径
    @Binding var path: [String]
    @AppStorage("libraryGridView") private var gridView = true
    /// 用于过滤的关键词：由搜索栏停顿后同步过来，不跟随每一下击键
    @State private var searchQuery = ""
    /// 自定义搜索框是否聚焦中
    @FocusState private var searchFocused: Bool
    @State private var showImporter = false
    @State private var importMessage: String?
    @State private var bookToDelete: Book?
    @State private var deleteErrorMessage: String?

    /// 正在搜索：搜索框聚焦中或已输入关键词
    private var isSearching: Bool {
        searchFocused || !searchQuery.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// 按搜索关键词过滤后的书，空关键词时返回全部
    private var visibleBooks: [Book] {
        library.books.filter { $0.matches(searchText: searchQuery) }
    }

    /// 书库主体：空态 / 无搜索结果 / 卡片网格 / 列表四种情况
    @ViewBuilder
    private var libraryContent: some View {
        Group {
            if library.books.isEmpty {
                // 区分「真没数据」和「首次扫描还没出结果」：后者只给轻量 loading，不闪空状态
                if library.hasFinishedFirstScan {
                    EmptyLibraryView(onImport: { showImporter = true })
                } else {
                    LoadingLibraryView()
                }
            } else if visibleBooks.isEmpty {
                NoSearchResultView(searchText: searchQuery)
            } else if gridView {
                BookGridView(
                    books: visibleBooks,
                    path: $path,
                    deleteBook: { bookToDelete = $0 },
                    playBook: { playFromLastPosition($0) }
                )
            } else {
                List {
                    ForEach(visibleBooks) { book in
                        // 不用 NavigationLink（行根视图会带系统箭头），改成点行入栈
                        BookRow(
                            book: book,
                            isNowPlaying: player.currentBook?.id == book.id,
                            onOpen: { path.append(book.id) },
                            onPlay: { playFromLastPosition(book) }
                        )
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
                .scrollDismissesKeyboard(.interactively)
                .navigationDestination(for: String.self) { bookId in
                    if let book = library.book(id: bookId) {
                        BookDetailView(book: book)
                    }
                }
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // 不用系统 .searchable：它聚焦时会把工具栏右侧按钮整个换成「取消」，
            // 做不到「隐藏添加、保留视图切换」，所以搜索栏自己画
            if !library.books.isEmpty {
                LibrarySearchBar(query: $searchQuery, focused: $searchFocused)
                    .padding(.horizontal, 14)
                    .padding(.top, 6)
                    .padding(.bottom, 8)
            }
            libraryContent
        }
        .background(Color(.systemBackground))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                // 搜索时收起「添加」入口（此时导入会打乱搜索结果），视图切换按钮保留
                if !isSearching {
                    Button {
                        showImporter = true
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                // 列表 / 卡片视图切换
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { gridView.toggle() }
                } label: {
                    Image(systemName: gridView ? "list.bullet" : "square.grid.2x2")
                }
                .accessibilityIdentifier("toggle-view")
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
                        CoverStore.shared.remove(bookId: book.id)
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

    /// 从该书最后记录的位置开始播放，并打开全屏播放页
    private func playFromLastPosition(_ book: Book) {
        NSLog("[sonux] ui: 点击列表播放按钮《%@》", book.title)
        player.play(book: book, at: library.position(forBook: book.id))
        withAnimation(.spring(response: 0.38, dampingFraction: 0.86)) { player.showPlayer = true }
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

/// 列表行：封面、书名、作者（点击进详情页），右侧一个从上次位置续播的播放按钮
/// 该书正在播放时：封面加靛蓝描边、书名变靛蓝、作者变浅靛蓝，不再叠加音柱等额外元素
private struct BookRow: View {
    let book: Book
    /// 该书是否为当前播放的书（无论暂停与否）
    let isNowPlaying: Bool
    let onOpen: () -> Void
    let onPlay: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            BookCoverView(book: book)
                .overlay {
                    if isNowPlaying {
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(Color.indigo, lineWidth: 2)
                    }
                }

            VStack(alignment: .leading, spacing: 4) {
                Text(book.title)
                    .font(.headline)
                    .foregroundStyle(isNowPlaying ? Color.indigo : Color.primary)
                    .lineLimit(2)
                // 有作者显作者，否则退而显总时长；正在播放时作者也染浅靛蓝
                Text(book.author ?? TimeFormat.duration(book.totalDuration))
                    .font(.subheadline)
                    .foregroundStyle(isNowPlaying ? Color.indigo.opacity(0.55) : Color.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            Button(action: onPlay) {
                Image(systemName: "play.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.indigo)
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(Color.indigo.opacity(0.12)))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("从上次位置播放《\(book.title)》")
            .accessibilityIdentifier("book-play-\(book.id)")
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onOpen)
        // 只给「打开详情」的命名操作，不占默认操作，否则行内播放按钮会被父层合并抢走
        .accessibilityAction(named: "打开《\(book.title)》详情") { onOpen() }
        .padding(.vertical, 4)
    }
}

/// 书库卡片网格：双列，点卡片进详情页，点封面中央按钮续播，长按可删除
private struct BookGridView: View {
    let books: [Book]
    @Binding var path: [String]
    let deleteBook: (Book) -> Void
    let playBook: (Book) -> Void

    @EnvironmentObject private var library: LibraryService
    @EnvironmentObject private var player: PlayerService

    private let columns = [
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12),
    ]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 14) {
                ForEach(books) { book in
                    // 不用 NavigationLink 包卡片，否则封面上的播放按钮抢不到点击
                    BookGridCard(
                        book: book,
                        isNowPlaying: player.currentBook?.id == book.id,
                        onOpen: { path.append(book.id) },
                        onPlay: { playBook(book) }
                    )
                    .contextMenu {
                        Button(role: .destructive) {
                            NSLog("[sonux] ui: 卡片长按菜单删除《%@》", book.title)
                            deleteBook(book)
                        } label: {
                            Label("删除", systemImage: "trash")
                        }
                    }
                    .accessibilityIdentifier("book-card-\(book.id)")
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
        .scrollDismissesKeyboard(.interactively)
        .navigationDestination(for: String.self) { bookId in
            if let book = library.book(id: bookId) {
                BookDetailView(book: book)
            }
        }
    }
}

/// 书库搜索栏：长得像系统搜索框，但聚焦时不会顶掉工具栏按钮
/// 文本存在子视图自己的 @State 里，击键只重绘这个搜索栏；
/// 停顿 180ms 后才把关键词交给父视图过滤，否则中文输入法每敲一个拼音字母都要重排整个书库
private struct LibrarySearchBar: View {
    /// 已生效的关键词（父视图用它过滤）
    @Binding var query: String
    @FocusState.Binding var focused: Bool
    /// 输入框里的实时文本
    @State private var text = ""

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.secondary)

            // 按规范不出占位文案，所以标题给空字符串，另补无障碍标签
            TextField("", text: $text)
                .focused($focused)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled(true)
                .submitLabel(.search)
                .onSubmit {
                    focused = false
                    apply()
                }
                .accessibilityLabel("搜索书库")
                .accessibilityIdentifier("library-search")

            if !text.isEmpty {
                Button {
                    text = ""
                    apply()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(.secondary)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("清空搜索关键词")
                .accessibilityIdentifier("library-search-clear")
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 36)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(.systemGray6)))
        .contentShape(RoundedRectangle(cornerRadius: 10))
        // 点输入框周围的空白也能聚焦，和系统搜索框手感一致
        .onTapGesture { focused = true }
        // 文本每次变化都重新计时：只有停手不再敲了才提交过滤
        .task(id: text) {
            try? await Task.sleep(nanoseconds: 180_000_000)
            guard !Task.isCancelled else { return }
            apply()
        }
    }

    private func apply() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if query != trimmed { query = trimmed }
    }
}

/// 搜索无结果：只提示关键词，不出导入按钮
private struct NoSearchResultView: View {
    let searchText: String

    var body: some View {
        ContentUnavailableWrapper(
            title: "没有找到「\(searchText.trimmingCharacters(in: .whitespacesAndNewlines))」",
            message: "换个书名、作者或章节关键词试试",
            systemImage: "magnifyingglass"
        ) { EmptyView() }
    }
}

/// 首次扫描期间的轻量占位：只有一个转圈，不出文字不出按钮，避免与空状态互相跳变
private struct LoadingLibraryView: View {
    var body: some View {
        ProgressView()
            .controlSize(.large)
            .tint(.indigo)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityLabel("正在载入书库")
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
    var systemImage: String = "tray.and.arrow.down.fill"
    @ViewBuilder let action: () -> ActionView

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: systemImage)
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
