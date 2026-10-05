import Foundation

/// 一条摘录：从字幕里挑出来的一句话，连同它出自哪本书、哪一章、第几秒
///
/// 光有句子不够——一张要发出去的卡片必须让人认得出出处，也正因如此
/// 摘录只能来自字幕（书里真说过的话），不能由谁另抄一份。
/// 时刻一律用「本章内」的秒，与播放器、字幕行、全文搜索同一口径。
struct Quote: Identifiable, Equatable {
    /// 封面与主色都按这本书取，卡片才和 App 里看到的同一本书对得上
    let book: Book
    let chapterTitle: String
    /// 单章书不写章名，免得整张卡片把书名重复一遍（与全文搜索卡片同一判据）
    let showsChapter: Bool
    let time: TimeInterval
    let text: String

    var id: String { "\(book.id)|\(chapterTitle)|\(Int(time.rounded()))" }

    /// 这本书没标作者时不留一个孤零零的分隔点
    var author: String? {
        book.author.flatMap { $0.isEmpty ? nil : $0 }
    }

    init(book: Book, chapterTitle: String, showsChapter: Bool, time: TimeInterval, text: String) {
        self.book = book
        self.chapterTitle = chapterTitle
        self.showsChapter = showsChapter
        self.time = time
        self.text = text
    }

    /// 整章文案页与播放页字幕：摘的就是手里这一句
    init(book: Book, chapter: Chapter, line: TranscriptLine) {
        self.init(book: book, chapterTitle: chapter.title,
                  showsChapter: book.chapters.count > 1, time: line.start, text: line.text)
    }

    /// 全文搜索的命中句：关键词只占了句里几个字，摘录要的是整句
    init(book: Book, match: TextMatch) {
        self.init(book: book, chapterTitle: match.chapterTitle,
                  showsChapter: book.chapters.count > 1, time: match.start, text: match.sentence)
    }
}
