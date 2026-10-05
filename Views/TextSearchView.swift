import SwiftUI

/// 全库字幕搜索的结果页：命中句按书分组，关键词加粗染色，点一句就直接从那句开播
///
/// 入口在书库搜索栏（回车或点搜索栏下方的入口行），所以这里的 query 就是用户输的那串词，
/// 标题也直接用它——和系统搜索页一样，结果页的标题就是关键词本身。
struct TextSearchView: View {
    let query: String
    /// 作者页里发起的搜索只在这位作者的作品里找；nil 是全库
    var author: String? = nil

    @EnvironmentObject private var library: LibraryService
    @EnvironmentObject private var player: PlayerService
    @State private var groups: [TextBookHits] = []
    @State private var searching = true
    /// 一本有字幕的书都没扫到（字幕还没同步进沙盒）：空态要说的是这件事，而不是「没找到」
    @State private var hasAnyTranscript = false

    var body: some View {
        content
            .background(Color(.systemGroupedBackground).ignoresSafeArea())
            .toolbarBackground(.hidden, for: .navigationBar)
            .navigationTitle(query)
            .navigationBarTitleDisplayMode(.inline)
            .task { await search() }
    }

    @ViewBuilder
    private var content: some View {
        if searching {
            ProgressView()
                .controlSize(.large)
                .tint(.indigo)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityLabel(L("Searching"))
        } else if groups.isEmpty {
            ContentUnavailableWrapper(
                title: hasAnyTranscript
                    ? LF("No Results for \"%@\"", query)
                    : L("No Transcripts to Search"),
                systemImage: hasAnyTranscript ? "magnifyingglass" : "doc.text"
            ) { EmptyView() }
        } else {
            hitsList
        }
    }

    /// 结果列表：一本书一个分组，组内按阅读顺序排；组按命中多少排，讲得最多的书在最上面
    private var hitsList: some View {
        List {
            ForEach(groups) { group in
                Section {
                    ForEach(group.matches) { match in
                        HitCard(match: match, chapterCount: chapterCount(of: group.bookID)) {
                            play(match, in: group.bookID)
                        }
                        .listRowSeparator(.hidden)
                        // 行本身透明，白卡由 HitCard 自己画（与书库列表行同一套做法）
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets(top: 0, leading: 14, bottom: 0, trailing: 14))
                    }
                    if group.hidden > 0 {
                        Text(LF("%d More Hits Not Listed", group.hidden))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                            .listRowInsets(EdgeInsets(top: 4, leading: 14, bottom: 8, trailing: 14))
                    }
                } header: {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(library.book(id: group.bookID)?.title ?? "")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        Text(LF("%d Hits", group.totalHits))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .textCase(nil)
                    .padding(.top, 6)
                }
            }
        }
        .listStyle(.plain)
        // List 默认会铺一层不透明白底，挡住后面的分组灰
        .scrollContentBackground(.hidden)
    }

    /// 逐本扫字幕：一本书一次后台运算，扫完一本就上屏（全库一趟 Release 0.3 秒、Debug 1 秒，先让结果出来比等齐更重要）
    /// 两本之间检查取消，换关键词或退页时旧结果不会盖到新结果上
    private func search() async {
        let books = author.map { library.books(byAuthor: $0) } ?? library.books
        let transcriptsDir = TranscriptStore.transcriptsDirectory
        var found: [TextBookHits] = []
        var scanned = 0
        for book in books {
            let hits = await Task.detached(priority: .userInitiated) {
                LibraryTextSearch.scan(book: book, query: query, transcriptsDir: transcriptsDir)
            }.value
            if Task.isCancelled { return }
            guard let hits else { continue }
            scanned += 1
            guard hits.totalHits > 0 else { continue }
            // 每次按命中数重排：讲得最多的书一直在最上面，新来的书插在它该在的位置
            found.append(hits)
            found.sort { $0.totalHits > $1.totalHits }
            groups = found
            searching = false
        }
        hasAnyTranscript = scanned > 0
        searching = false
        NSLog("[sonux] textsearch: 「%@」命中 %d 句，涉及 %d 本（扫了 %d 本有字幕的）",
              query, found.reduce(0) { $0 + $1.totalHits }, found.count, scanned)
    }

    /// 这句所在的书有多少章（只有一章的书不再重复报章名）
    private func chapterCount(of bookID: String) -> Int {
        library.book(id: bookID)?.chapters.count ?? 0
    }

    /// 点句：装载这一章并从这一句的起点出声，同时展开全屏播放页
    /// 时间口径与播放页文案页点句一致（都是章内秒），所以不做额外回退
    private func play(_ match: TextMatch, in bookID: String) {
        guard let book = library.book(id: bookID),
              let chapter = book.chapters.first(where: { $0.id == match.chapterID }) else { return }
        NSLog("[sonux] ui: 全文搜索点句《%@》%@ %.1fs", book.title, chapter.title, match.start)
        player.play(chapter: chapter, book: book, fromTime: match.start)
        withAnimation(.spring(response: 0.38, dampingFraction: 0.86)) { player.showPlayer = true }
    }
}

/// 一张命中卡片：上面是关键词高亮的句子，下面是「第几章 · 第几秒」
private struct HitCard: View {
    let match: TextMatch
    /// 这本书的章数：单章书就不写章名了，免得整页重复一句话
    let chapterCount: Int
    let onPlay: () -> Void

    var body: some View {
        Button(action: onPlay) {
            VStack(alignment: .leading, spacing: 6) {
                sentence
                    .font(.body)
                    .lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Text(byline)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(RoundedRectangle(cornerRadius: 14))
            .background(RoundedRectangle(cornerRadius: 14).fill(Color(.secondarySystemGroupedBackground)))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("text-hit-\(match.chapterID)@\(Int(match.start))")
        .accessibilityLabel(LF("Play \"%1$@\" at %2$@", byline, TimeFormat.time(match.start)))
    }

    /// 句子按命中情况切段拼接：命中的那几段加粗染主题色，其余照常
    /// 用 Text 相加而不是 AttributedString，是因为 Text 的字体/颜色修饰符返回的还是 Text，
    /// 相加才成立；换成 some View 的修饰符就没法再拼起来了
    private var sentence: Text {
        match.segments.reduce(Text(verbatim: "")) { result, segment in
            result + Text(segment.text)
                .foregroundColor(segment.marked ? .indigo : .primary)
                .fontWeight(segment.marked ? .semibold : .regular)
        }
    }

    /// 第二行：章节名 + 章内时刻（一章的书只给时刻）
    private var byline: String {
        chapterCount > 1 ? "\(match.chapterTitle) · \(TimeFormat.time(match.start))"
                         : TimeFormat.time(match.start)
    }
}
