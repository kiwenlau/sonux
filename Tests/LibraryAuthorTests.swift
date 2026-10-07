import XCTest
@testable import Sonux

/// LibraryService 的两块纯静态：作者名的归一化键与展示形式；
/// HistoryEntry 是播放历史一行的值对象，id 用 book.id 保证一本书在历史里只有一条。
/// 至于 sorted(_:by:) 与 nextUnfinishedBook / historyEntries() 这些实例方法都要 @MainActor
/// 起 LibraryService，会触发真实 FileManager 与 UserDefaults；留待下一 Phase 的集成用例。
final class LibraryAuthorTests: XCTestCase {
    // MARK: - authorKey

    func testAuthorKey_trimsWhitespace() {
        XCTAssertEqual(LibraryService.authorKey("  张三 "), "张三")
        XCTAssertEqual(LibraryService.authorKey("\n鲁迅\t"), "鲁迅")
    }

    func testAuthorKey_lowercasesLatin() {
        // 「Orwell」与「orwell」要认成同一个人
        XCTAssertEqual(LibraryService.authorKey("Orwell"), "orwell")
        XCTAssertEqual(LibraryService.authorKey("ORWELL"), "orwell")
    }

    func testAuthorKey_leavesCJKUntouched() {
        // 汉字没有大小写；lowercased() 不会改变它们，也不该改变
        XCTAssertEqual(LibraryService.authorKey("鲁迅"), "鲁迅")
    }

    func testAuthorKey_emptyStaysEmpty() {
        XCTAssertEqual(LibraryService.authorKey(""), "")
        XCTAssertEqual(LibraryService.authorKey("   "), "")
    }

    func testAuthorKey_deduplicatesSameAuthor() {
        // 「张三 」与「张三」归到同一 key，才能被 books(byAuthor:) 视作同一人
        XCTAssertEqual(LibraryService.authorKey("张三 "),
                       LibraryService.authorKey("张三"))
    }

    // MARK: - displayAuthor

    @MainActor
    func testDisplayAuthor_onlyTrims() {
        // 展示形式与归一化键的差别：大小写要保留，只裁两端空白
        XCTAssertEqual(LibraryService.displayAuthor("  Orwent  "), "Orwent")
        XCTAssertEqual(LibraryService.displayAuthor("鲁迅"), "鲁迅")
    }

    @MainActor
    func testDisplayAuthor_keepsInnerWhitespace() {
        // 「加西亚 · 马尔克斯」这种带空格的名字不能被裁坏
        XCTAssertEqual(LibraryService.displayAuthor("加西亚 · 马尔克斯"),
                       "加西亚 · 马尔克斯")
    }

    @MainActor
    func testDisplayAuthor_emptyForWhitespaceOnly() {
        XCTAssertEqual(LibraryService.displayAuthor("   "), "")
    }

    // MARK: - HistoryEntry

    func testHistoryEntry_idIsBookId() {
        let book = Book(id: "xyz", title: "T", author: nil, chapters: [], storagePath: "p")
        let entry = LibraryService.HistoryEntry(book: book, chapter: nil, position: nil,
                                                lastPlayed: Date(timeIntervalSince1970: 100))
        XCTAssertEqual(entry.id, "xyz", "一本书在历史里只应有一条，id 用 book.id 保证")
    }

    func testHistoryEntry_acceptsNilChapterAndPosition() {
        // 书被扫描回来但对应章节 ID 找不到（音频换了、章节被合并）时不能崩
        let book = Book(id: "b", title: "T", author: nil, chapters: [], storagePath: "p")
        let entry = LibraryService.HistoryEntry(book: book, chapter: nil, position: nil,
                                                lastPlayed: Date())
        XCTAssertNil(entry.chapter)
        XCTAssertNil(entry.position)
    }
}
