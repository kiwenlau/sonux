import XCTest
@testable import Sonux

/// Book 里两块纯逻辑：totalDuration（章节秒数累加）与 matches（大小写无关的书名/作者/章名包含判断）。
/// 顺便盖住 isLinked（link 键缺失即视为原生文件）与 link 的向后兼容解码。
final class BookTests: XCTestCase {
    private func chapter(_ id: String, title: String, duration: TimeInterval) -> Chapter {
        Chapter(id: id, bookId: "b", index: 0, title: title,
                duration: duration, fileURL: URL(fileURLWithPath: "/tmp/\(id).mp3"))
    }

    private func book(title: String = "Test Book", author: String? = nil,
                      chapters: [Chapter], link: String? = nil) -> Book {
        var book = Book(id: "b", title: title, author: author, chapters: chapters,
                        storagePath: "test-book")
        book.link = link
        return book
    }

    // MARK: - totalDuration

    func testTotalDuration_noChaptersIsZero() {
        XCTAssertEqual(book(chapters: []).totalDuration, 0)
    }

    func testTotalDuration_sumsAllChapters() {
        let b = book(chapters: [chapter("1", title: "a", duration: 10),
                                 chapter("2", title: "b", duration: 20.5),
                                 chapter("3", title: "c", duration: 30)])
        XCTAssertEqual(b.totalDuration, 60.5)
    }

    // MARK: - isLinked

    func testIsLinked_reflectsLinkPresence() {
        XCTAssertFalse(book(chapters: []).isLinked)
        XCTAssertTrue(book(chapters: [], link: "abc123").isLinked)
    }

    // MARK: - matches

    func testMatches_emptyQueryAlwaysTrue() {
        let b = book(title: "Any", chapters: [chapter("1", title: "x", duration: 1)])
        XCTAssertTrue(b.matches(searchText: ""))
        XCTAssertTrue(b.matches(searchText: "   "))    // 只有空白也算空
        XCTAssertTrue(b.matches(searchText: "\n"))
    }

    func testMatches_titleHit() {
        let b = book(title: "Swift Concurrency", chapters: [])
        XCTAssertTrue(b.matches(searchText: "swift"))
        XCTAssertTrue(b.matches(searchText: "CONCURRENCY"))
        XCTAssertTrue(b.matches(searchText: "concur"))     // 前缀/中间包含都算
    }

    func testMatches_authorHit() {
        let b = book(title: "T", author: "Apple Inc.", chapters: [])
        XCTAssertTrue(b.matches(searchText: "apple"))
        XCTAssertTrue(b.matches(searchText: "INC"))
    }

    func testMatches_nilAuthorDoesNotCrash() {
        let b = book(title: "T", author: nil, chapters: [])
        XCTAssertFalse(b.matches(searchText: "author"))
    }

    func testMatches_chapterTitleHit() {
        let b = book(title: "T", author: nil,
                     chapters: [chapter("1", title: "序章", duration: 1),
                                chapter("2", title: "The Grand End", duration: 1)])
        XCTAssertTrue(b.matches(searchText: "grand"))
        XCTAssertTrue(b.matches(searchText: "序"))
    }

    func testMatches_noHitReturnsFalse() {
        let b = book(title: "A", author: "B",
                     chapters: [chapter("1", title: "C", duration: 1)])
        XCTAssertFalse(b.matches(searchText: "zzz"))
    }

    // MARK: - Codable 向后兼容

    /// 旧 progress.json 里没有 link 键：解出来必须是 nil（而不是崩掉或误判非 nil）
    func testDecode_missingLinkFieldIsNil() throws {
        let json = """
        {"id":"b","title":"T","chapters":[],"storagePath":"p"}
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(Book.self, from: json)
        XCTAssertNil(decoded.link)
        XCTAssertFalse(decoded.isLinked)
    }

    /// 同理 author 缺失也 OK（它是 Optional）
    func testDecode_missingAuthorIsNil() throws {
        let json = """
        {"id":"b","title":"T","chapters":[],"storagePath":"p","link":"lnk"}
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(Book.self, from: json)
        XCTAssertNil(decoded.author)
        XCTAssertEqual(decoded.link, "lnk")
        XCTAssertTrue(decoded.isLinked)
    }

    func testRoundtrip_fullBook() throws {
        let original = book(title: "_round", author: "me",
                            chapters: [chapter("1", title: "x", duration: 3)],
                            link: "xyz")
        let decoded = try JSONDecoder().decode(Book.self, from: JSONEncoder().encode(original))
        XCTAssertEqual(decoded, original)
    }
}
