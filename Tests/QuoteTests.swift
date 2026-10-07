import XCTest
@testable import Sonux

/// Quote 是摘录卡片的值对象：id 靠「书 id + 章名 + 秒（四舍五入）」拼出，
/// author 计算属性把空串归成 nil 免得卡片上留个孤零零的分隔点；
/// 三个 init 只是把不同来源（章+字幕行 / 全文搜索命中 / 手工）折叠到同一份字段。
final class QuoteTests: XCTestCase {
    private func makeBook(title: String = "T", author: String? = "A", chapterCount: Int = 3) -> Book {
        let chapters = (0..<chapterCount).map { i in
            Chapter(id: "c\(i)", bookId: "b1", index: i, title: "第\(i)章",
                    duration: 60, fileURL: URL(fileURLWithPath: "/tmp/\(i).mp3"))
        }
        return Book(id: "b1", title: title, author: author, chapters: chapters,
                    storagePath: "b1")
    }

    // MARK: - id 组合

    func testId_usesBookChapterAndRoundedTime() {
        let q = Quote(book: makeBook(), chapterTitle: "第三章", showsChapter: true,
                      time: 12.4, text: "内容")
        XCTAssertEqual(q.id, "b1|第三章|12")
    }

    func testId_roundsTimeToNearestSecond() {
        let q = Quote(book: makeBook(), chapterTitle: "c", showsChapter: true,
                      time: 12.6, text: "x")
        XCTAssertEqual(q.id, "b1|c|13")
    }

    func testId_differsWhenAnyComponentDiffers() {
        let base = Quote(book: makeBook(), chapterTitle: "c", showsChapter: true, time: 5, text: "x")
        let otherChapter = Quote(book: makeBook(), chapterTitle: "d", showsChapter: true, time: 5, text: "x")
        let otherTime = Quote(book: makeBook(), chapterTitle: "c", showsChapter: true, time: 6, text: "x")
        XCTAssertNotEqual(base.id, otherChapter.id)
        XCTAssertNotEqual(base.id, otherTime.id)
    }

    // MARK: - author 归一

    func testAuthor_nilStaysNil() {
        let q = Quote(book: makeBook(author: nil), chapterTitle: "c", showsChapter: true,
                      time: 0, text: "x")
        XCTAssertNil(q.author)
    }

    func testAuthor_emptyStringBecomesNil() {
        // 关键：书里 author 是空串时，卡片不能留孤零零的「·」分隔点，计算属性把它归 nil
        let q = Quote(book: makeBook(author: ""), chapterTitle: "c", showsChapter: true,
                      time: 0, text: "x")
        XCTAssertNil(q.author)
    }

    func testAuthor_nonEmptyPassesThrough() {
        let q = Quote(book: makeBook(author: "鲁迅"), chapterTitle: "c", showsChapter: true,
                      time: 0, text: "x")
        XCTAssertEqual(q.author, "鲁迅")
    }

    // MARK: - 三个 init

    func testInit_fromChapterAndLine_propagatesFields() {
        let book = makeBook(chapterCount: 3)
        let chapter = book.chapters[1]
        let line = TranscriptLine(start: 12.5, end: 14.0, text: "一句正文")
        let q = Quote(book: book, chapter: chapter, line: line)
        XCTAssertEqual(q.chapterTitle, "第1章")
        XCTAssertEqual(q.showsChapter, true)     // 多章书要显示章名
        XCTAssertEqual(q.time, 12.5)              // 用 line.start
        XCTAssertEqual(q.text, "一句正文")
    }

    func testInit_fromChapterAndLine_singleChapterBookHidesChapter() {
        let book = makeBook(chapterCount: 1)
        let q = Quote(book: book, chapter: book.chapters[0],
                      line: TranscriptLine(start: 0, end: 1, text: "x"))
        XCTAssertFalse(q.showsChapter, "单章书不显示章名，免得跟书名重复一遍")
    }

    func testInit_fromTextMatch_usesSentenceAndStart() {
        let book = makeBook(chapterCount: 3)
        let match = TextMatch(bookID: book.id, chapterID: "c0", chapterTitle: "第一章",
                              start: 30, segments: [.init(text: "前半 ", marked: false),
                                                    .init(text: "关键词", marked: true),
                                                    .init(text: " 后半", marked: false)])
        let q = Quote(book: book, match: match)
        XCTAssertEqual(q.time, 30)
        XCTAssertEqual(q.text, "前半 关键词 后半")   // sentence 拼三段
        XCTAssertTrue(q.showsChapter)
    }
}
