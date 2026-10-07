import XCTest
@testable import Sonux

/// LibraryService 的三块实例侧公共 API：sorted / nextUnfinishedBook / book(id:)，
/// 都靠 SonuxRuntime.shared.library 现成的 books/positions/lastPlayedDates 状态跑。
/// 断言只讲「语义契约」，不断具体书——模拟器里跑什么书随同步脚本变。
@MainActor
final class LibraryServiceInstanceTests: XCTestCase {
    private var library: LibraryService { SonuxRuntime.shared.library }

    // MARK: - book(id:)

    func testBookByID_returnsNilForUnknown() {
        XCTAssertNil(library.book(id: "no-\(UUID().uuidString)"))
    }

    func testBookByID_returnsSameInstanceForKnown() throws {
        guard let first = library.books.first else { throw XCTSkip("空书库") }
        XCTAssertEqual(library.book(id: first.id)?.id, first.id)
    }

    // MARK: - sorted(_:by:)

    func testSorted_emptyArrayAlwaysEmpty() {
        for sort in LibrarySort.allCases {
            XCTAssertEqual(library.sorted([], by: sort).count, 0)
        }
    }

    func testSorted_fileNameKeepsOriginalOrder() {
        // .fileName 是「扫目录出来的自然序，原样返回」——传进去什么顺序就出来什么顺序
        guard library.books.count >= 2 else { return }
        let input = Array(library.books.prefix(5))
        let output = library.sorted(input, by: .fileName)
        XCTAssertEqual(output.map(\.id), input.map(\.id),
                       "fileName 排序不做任何变换")
    }

    func testSorted_lastPlayedReturnsSameCount() {
        // 全排序：出来的书数必须等于入参，且集合内容一致
        let input = library.books
        let output = library.sorted(input, by: .lastPlayed)
        XCTAssertEqual(output.count, input.count)
        XCTAssertEqual(Set(output.map(\.id)), Set(input.map(\.id)))
    }

    func testSorted_addedReturnsSameCount() {
        let input = library.books
        let output = library.sorted(input, by: .added)
        XCTAssertEqual(output.count, input.count)
        XCTAssertEqual(Set(output.map(\.id)), Set(input.map(\.id)))
    }

    func testSorted_isIdempotent() {
        // 排一次与排两次结果一致（不随调用次数漂）
        let once = library.sorted(library.books, by: .lastPlayed)
        let twice = library.sorted(once, by: .lastPlayed)
        XCTAssertEqual(once.map(\.id), twice.map(\.id))
    }

    // MARK: - nextUnfinishedBook

    func testNextUnfinishedBook_returnsNilOrValidBook() {
        // 空书库 → nil；有书 → 一定是 books 里的一员
        guard let next = library.nextUnfinishedBook() else {
            XCTAssertTrue(library.books.isEmpty, "非空书库里至少要有一本未完的")
            return
        }
        XCTAssertTrue(library.books.contains { $0.id == next.id })
    }

    // MARK: - position(forBook:) / position(forChapter:)

    func testPositionForBook_unknownIdReturnsNil() {
        XCTAssertNil(library.position(forBook: "no-\(UUID().uuidString)"))
    }

    func testPositionForChapter_unknownIdReturnsNil() {
        XCTAssertNil(library.position(forChapter: "no-\(UUID().uuidString)"))
    }

    // MARK: - listening 快照同步

    func testListening_totalSecondsMatchesSummary() {
        // listeningSummary.totalSeconds 就是 listening.totalSeconds 的搬运
        XCTAssertEqual(library.listening.totalSeconds,
                       library.listeningSummary().totalSeconds, accuracy: 1e-6)
    }
}
