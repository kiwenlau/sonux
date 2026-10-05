import SwiftUI
import UniformTypeIdentifiers

struct LibraryView: View {
    @EnvironmentObject private var library: LibraryService
    @EnvironmentObject private var player: PlayerService
    @EnvironmentObject private var routers: TabRouters
    @AppStorage("libraryGridView") private var gridView = true
    /// 排序方式：默认按最近收听；@AppStorage 只存原始值，脏值（如已删掉的 duration、progress）也回落到这个默认
    @AppStorage("librarySort") private var sortRaw = LibrarySort.lastPlayed.rawValue
    /// 限定只看某一位作者的作品（作者页）：整套界面与书库共用，
    /// 差别只有顶部标题、隐藏「添加」入口与空态文案；nil 就是书库本身
    var author: String? = nil
    /// 用于过滤的关键词：由搜索栏停顿后同步过来，不跟随每一下击键
    @State private var searchQuery = ""
    /// 自定义搜索框是否聚焦中
    @FocusState private var searchFocused: Bool
    @State private var showImporter = false
    @State private var importMessage: String?
    @State private var bookToDelete: Book?
    @State private var deleteErrorMessage: String?

    /// 入栈统一走当前 tab 的导航栈
    private var router: AppRouter { routers.active }

    /// 正在搜索：搜索框聚焦中或已输入关键词
    private var isSearching: Bool {
        searchFocused || !searchQuery.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// 本页的书源：作者页只取该作者的作品，书库取全部
    private var sourceBooks: [Book] {
        guard let author else { return library.books }
        return library.books(byAuthor: author)
    }

    /// 顶部标题：作者页显作者名，书库不出标题
    private var pageTitle: String {
        author.map(LibraryService.displayAuthor) ?? ""
    }

    /// 当前选择的排序方式（解不出来的原始值按默认「最近收听」处理）
    private var sort: LibrarySort {
        LibrarySort(rawValue: sortRaw) ?? .lastPlayed
    }

    /// 按搜索关键词过滤并按用户选的排序方式重排的书，空关键词时返回全部
    private var visibleBooks: [Book] {
        library.sorted(sourceBooks.filter { $0.matches(searchText: searchQuery) }, by: sort)
    }

    /// 书库主体：空态 / 无搜索结果 / 卡片网格 / 列表四种情况
    @ViewBuilder
    private var libraryContent: some View {
        Group {
            if sourceBooks.isEmpty {
                if author != nil {
                    // 作者页只在书被删空时走到这里，不给导入入口
                    ContentUnavailableWrapper(
                        title: LF("Works by \"%@\" Are No Longer in the Library", pageTitle),
                        systemImage: "person"
                    ) { EmptyView() }
                } else if library.hasFinishedFirstScan {
                    // 区分「真没数据」和「首次扫描还没出结果」：后者只给轻量 loading，不闪空状态
                    EmptyLibraryView(onImport: { showImporter = true })
                } else {
                    LoadingLibraryView()
                }
            } else if visibleBooks.isEmpty {
                NoSearchResultView(searchText: searchQuery)
            } else if gridView {
                BookGridView(
                    books: visibleBooks,
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
                            onOpen: { router.openBook(id: book.id) },
                            onPlay: { playFromLastPosition(book) }
                        )
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button(role: .destructive) {
                                NSLog("[sonux] ui: 点击滑动删除按钮《%@》", book.title)
                                bookToDelete = book
                            } label: {
                                Label(L("Delete"), systemImage: "trash")
                            }
                        }
                        .contextMenu {
                            Button(role: .destructive) {
                                NSLog("[sonux] ui: 点击长按菜单删除《%@》", book.title)
                                bookToDelete = book
                            } label: {
                                Label(L("Delete"), systemImage: "trash")
                            }
                        }
                        .accessibilityIdentifier("book-row-\(book.id)")
                        .listRowSeparator(.hidden)
                        // 行本身透明，卡片底色由 BookRow 自己画，两侧留出网格同款间距
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets(top: 0, leading: 14, bottom: 0, trailing: 14))
                    }
                }
                .listStyle(.plain)
                // List 默认会铺一层不透明白底，挡住上面的分组灰
                .scrollContentBackground(.hidden)
                .scrollDismissesKeyboard(.interactively)
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // 不用系统 .searchable：它聚焦时会把工具栏右侧按钮整个换成「取消」，
            // 做不到「隐藏添加、保留视图切换」，所以搜索栏自己画
            if !sourceBooks.isEmpty {
                LibrarySearchBar(query: $searchQuery, focused: $searchFocused) { committed in
                    // 按键盘上的「搜索」= 直接进字幕搜索页：书名与章节名之外的第三种搜法
                    router.openTextSearch(query: committed, author: author)
                }
                    .padding(.horizontal, 14)
                    .padding(.top, 6)
                    .padding(.bottom, 8)
            }
            // 关键词一定下来就露出全文搜索入口（此时还没到一屏书名，加一行不显拥挤）：
            // 有声书的搜索重心在正文里，只按书名过滤会让人觉得「搜不到」
            if !sourceBooks.isEmpty, !searchQuery.isEmpty {
                FullTextSearchRow(query: searchQuery) {
                    router.openTextSearch(query: searchQuery, author: author)
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 8)
            }
            libraryContent
        }
        // 页面底色用分组灰（微信听书那种浅灰），白色卡片才浮得出来；
        // 底色往上铺进状态栏与导航栏，整片顶部是一个颜色不断层
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
        .toolbarBackground(.hidden, for: .navigationBar)
        .navigationTitle(pageTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // 三个图标形状差别大（加号偏方、上下箭头偏高、列表偏扁），套同一个系统字号会
            // 一高一矮（实测墨迹高 17.7 / 21.0 / 14.4 pt），所以各配一档字号把高度配平：
            // 加号用系统默认 17pt，上下箭头 14pt，列表 19pt、网格 15pt
            // （配平后依次 17.7 / 16.7 / 17.3 / 17.3 pt）
            ToolbarItem(placement: .topBarTrailing) {
                // 搜索时收起「添加」入口（此时导入会打乱搜索结果），视图切换按钮保留；
                // 作者页也没有导入的语境，同样不显示
                if author == nil, !isSearching {
                    Button {
                        showImporter = true
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                // 排序：三种方式收进一个下拉菜单，选中的打勾，选择记进偏好下次启动沿用。
                // 书库空的时候没得排，不摆这个入口
                if !sourceBooks.isEmpty {
                    Menu {
                        ForEach(LibrarySort.allCases) { option in
                            Button {
                                NSLog("[sonux] ui: 书库排序改为 %@", option.rawValue)
                                sortRaw = option.rawValue
                            } label: {
                                if sort == option {
                                    Label(option.label, systemImage: "checkmark")
                                } else {
                                    Text(option.label)
                                }
                            }
                        }
                    } label: {
                        Image(systemName: "arrow.up.arrow.down")
                            .font(.system(size: 14))
                    }
                    .accessibilityLabel(L("Sort By"))
                    .accessibilityIdentifier("library-sort")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                // 列表 / 卡片视图切换：两个符号一扁一方，各自一档字号才跟得上旁边两个
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { gridView.toggle() }
                } label: {
                    Image(systemName: gridView ? "list.bullet" : "square.grid.2x2")
                        .font(.system(size: gridView ? 19 : 15))
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
        .alert(L("Import Finished"), isPresented: Binding(
            get: { importMessage != nil },
            set: { if !$0 { importMessage = nil } }
        )) {
            Button(L("OK"), role: .cancel) { importMessage = nil }
        } message: {
            Text(importMessage ?? "")
        }
        .alert(LF("Delete \"%@\"", bookToDelete?.title ?? ""), isPresented: Binding(
            get: { bookToDelete != nil },
            set: { if !$0 { bookToDelete = nil } }
        )) {
            Button(L("Cancel"), role: .cancel) { bookToDelete = nil }
            Button(L("Delete"), role: .destructive) {
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
            Text(L("This will remove the audio files from your library. This action can't be undone."))
        }
        .alert(L("Delete Failed"), isPresented: Binding(
            get: { deleteErrorMessage != nil },
            set: { if !$0 { deleteErrorMessage = nil } }
        )) {
            Button(L("OK"), role: .cancel) { deleteErrorMessage = nil }
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
                importMessage = L("Nothing to import (supports m4a / m4b / mp3 / aac / wav, or folders containing these files)")
            } else {
                importMessage = LF("Imported %d items", count)
            }
        case .failure:
            importMessage = L("Import Failed, Please Try Again")
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
        // 整行「打开详情」与行尾播放键是平级兄弟（与书库卡片同一套做法）：
        // 真 Button 才有按下高亮，也不会被 List 的滑动删除/长按菜单抢走点击
        ZStack {
            Button(action: onOpen) {
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

                    // 给上层播放键占好位置，整行宽度与原来一致
                    Color.clear
                        .frame(width: 34, height: 34)
                }
                .padding(12)
                // 与卡片网格、历史页同一套白卡：浅色模式下 secondarySystemGroupedBackground 就是纯白
                .background(RoundedRectangle(cornerRadius: 14).fill(Color(.secondarySystemGroupedBackground)))
            }
            .buttonStyle(PressableCardStyle(logName: book.title))

            HStack(spacing: 0) {
                Spacer(minLength: 0)
                Button(action: onPlay) {
                    Image(systemName: "play.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.indigo)
                        .frame(width: 34, height: 34)
                        .background(Circle().fill(Color.indigo.opacity(0.12)))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(LF("Play \"%@\" from Where You Left Off", book.title))
                .accessibilityIdentifier("book-play-\(book.id)")
            }
            .padding(.horizontal, 12)
        }
        // 行间距：放在卡片背景之外，不算进白底
        .padding(.vertical, 6)
    }
}

/// 书库卡片网格：双列，点卡片进详情页，点封面中央按钮续播，长按可删除
private struct BookGridView: View {
    let books: [Book]
    let deleteBook: (Book) -> Void
    let playBook: (Book) -> Void

    @EnvironmentObject private var player: PlayerService
    @EnvironmentObject private var routers: TabRouters

    private var router: AppRouter { routers.active }

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
                        onOpen: { router.openBook(id: book.id) },
                        onPlay: { playBook(book) }
                    )
                    .contextMenu {
                        Button(role: .destructive) {
                            NSLog("[sonux] ui: 卡片长按菜单删除《%@》", book.title)
                            deleteBook(book)
                        } label: {
                            Label(L("Delete"), systemImage: "trash")
                        }
                    }
                    .accessibilityIdentifier("book-card-\(book.id)")
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
        .scrollDismissesKeyboard(.interactively)
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
    /// 回车提交后的动作：把关键词交给父视图跳字幕搜索页。
    /// 显式传值而不是让父视图回读 query —— 写入的是存储，这一趟渲染还没重算，
    /// 传值能保证跳过去用的就是刚提交的那个词
    var onSubmitText: (String) -> Void = { _ in }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 15, weight: .regular))
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
                    let committed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !committed.isEmpty else { return }
                    onSubmitText(committed)
                }
                .accessibilityLabel(L("Search Library"))
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
                .accessibilityLabel(L("Clear Search Keywords"))
                .accessibilityIdentifier("library-search-clear")
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 36)
        .frame(maxWidth: .infinity)
        // 灰底页面上搜索框用白色卡片色，跟微信听书一致
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(.secondarySystemGroupedBackground)))
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

/// 全文搜索入口：书名与章节名之外的第三种搜法——把关键词带进字幕搜索页。
/// 与搜索栏同样式的一张白卡，右端一个箭头表明它是个去处而不是筛选结果
private struct FullTextSearchRow: View {
    let query: String
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 8) {
                Image(systemName: "text.magnifyingglass")
                    .font(.system(size: 15, weight: .regular))
                    .foregroundStyle(.indigo)

                Text(LF("Search All Text for \"%@\"", query))
                    .font(.subheadline)
                    .foregroundStyle(.indigo)
                    .lineLimit(1)

                Spacer(minLength: 4)

                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 10)
            .frame(height: 36)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color(.secondarySystemGroupedBackground)))
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("library-fulltext")
    }
}

/// 搜索无结果：只提示关键词，不出导入按钮
private struct NoSearchResultView: View {
    let searchText: String

    var body: some View {
        ContentUnavailableWrapper(
            title: LF("No Results for \"%@\"", searchText.trimmingCharacters(in: .whitespacesAndNewlines)),
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
            .accessibilityLabel(L("Loading Library"))
    }
}

private struct EmptyLibraryView: View {
    @EnvironmentObject private var library: LibraryService
    let onImport: () -> Void

    var body: some View {
        ContentUnavailableWrapper(
            title: L("Library Is Empty"),
            action: {
                Button {
                    onImport()
                } label: {
                    Label(L("Import Audio"), systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)

                Button(L("Rescan")) { library.rescan() }
                    .buttonStyle(.bordered)
            }
        )
    }
}

struct ContentUnavailableWrapper<ActionView: View>: View {
    let title: String
    var systemImage: String = "tray.and.arrow.down.fill"
    @ViewBuilder let action: () -> ActionView

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: systemImage)
                .font(.system(size: 48))
                .foregroundStyle(.indigo)
            Text(title)
                .font(.title2.bold())
                // 关键词可能被用户贴进一整句话，标题要能折行但不能把整页顶没（居中三行为止）
                .multilineTextAlignment(.center)
                .lineLimit(3)
                .padding(.horizontal, 24)
            action()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
