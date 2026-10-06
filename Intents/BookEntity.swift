import AppIntents

/// 候选清单的长度：全库几百本一股脑交给系统，选书的列表反而没法看
private let voiceBookLimit = 10

/// 一本书在 Siri 与快捷指令那边的样子：只带 id 和书名两个字段。
/// 书名要跟着存进来而不是拿 id 现查——`displayRepresentation` 是同步接口，
/// 而书库是主线程上的状态，系统画候选列表时可等不了一个 await
struct BookEntity: AppEntity {
    let id: String
    let title: String

    static var typeDisplayRepresentation: TypeDisplayRepresentation = TypeDisplayRepresentation(name: "Book")
    static var defaultQuery = BookEntityQuery()

    init(id: String, title: String) {
        self.id = id
        self.title = title
    }

    init(book: Book) {
        self.init(id: book.id, title: book.title)
    }

    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(title)") }
}

/// 系统问「有哪些书可以播」：四种问法各管一处，答案都现问正在跑的那个书库，不另存一份
struct BookEntityQuery: EntityStringQuery {
    /// 快捷指令里存过的那本（按 id 回查）
    func entities(for identifiers: [String]) async throws -> [BookEntity] {
        await SonuxRuntime.shared.voiceBooks(ids: identifiers)
    }

    /// 用户把书名报进句子里了：《百年孤独》那本，书名著作者、章节名都算命中
    func entities(matching string: String) async throws -> [BookEntity] {
        await SonuxRuntime.shared.voiceBooks(matching: string)
    }

    /// 让用户挑一本的候选列表
    func suggestedEntities() async throws -> [BookEntity] {
        await SonuxRuntime.shared.suggestedVoiceBooks()
    }

    /// 什么都没报时的默认那本：最近收听的，正对上「播放我的书」这句话
    func defaultResult() async -> BookEntity? {
        await SonuxRuntime.shared.lastListenedVoiceBook
    }
}

// MARK: - 书库 → 语音实体
// 这几位待在 SonuxRuntime 的主线程隔离里（扩展继承类型的隔离），
// 实体这边只管 await 一下拿现成的结果，不跨 actor 摸 Book 和播放历史
extension SonuxRuntime {
    func voiceBooks(ids: [String]) -> [BookEntity] {
        library.books.filter { ids.contains($0.id) }.map(BookEntity.init(book:))
    }

    func voiceBooks(matching text: String) -> [BookEntity] {
        let hits = library.books.filter { $0.matches(searchText: text) }
        return Array(hits.prefix(voiceBookLimit)).map(BookEntity.init(book:))
    }

    func suggestedVoiceBooks() -> [BookEntity] {
        let recent = library.historyEntries().prefix(voiceBookLimit).map { BookEntity(book: $0.book) }
        guard recent.count < voiceBookLimit else { return Array(recent) }
        // 一本都没听过（刚导入的书）就拿书库开头补满，别让候选列表空着
        let known = Set(recent.map(\.id))
        let rest = library.books.filter { !known.contains($0.id) }.prefix(voiceBookLimit - recent.count)
        return recent + rest.map(BookEntity.init(book:))
    }

    var lastListenedVoiceBook: BookEntity? {
        library.historyEntries().first.map { BookEntity(book: $0.book) }
    }
}
