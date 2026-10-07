import XCTest
@testable import Sonux

/// SonuxRuntime 的四个「书库 → 语音实体」扩展方法（在 BookEntity.swift 里定义）：
/// 都在主线程隔离里现取当前 library.books 与 historyEntries()。
/// 单元测试不能真导入音频，但可以拿运行时里已经扫出来的书库（可能为空）验它们各自的语义契约：
///   - voiceBooks(ids:) 按 id 精确过滤，缺失不报错；
///   - voiceBooks(matching:) 用 Book.matches 判据，命中最多 10 条；
///   - suggestedVoiceBooks 先给最近听过的、再用书库开头补足到 10；
///   - lastListenedVoiceBook = historyEntries().first 拍扁。
@MainActor
final class VoiceBookQueryTests: XCTestCase {
    private var runtime: SonuxRuntime { SonuxRuntime.shared }

    func testVoiceBooks_byUnknownIdsReturnsEmpty() {
        // 传一堆随机 UUID，都不该在库里
        let unknown = (0..<3).map { _ in "no-\(UUID().uuidString)" }
        XCTAssertEqual(runtime.voiceBooks(ids: unknown).count, 0)
    }

    func testVoiceBooks_byEmptyIdsReturnsEmpty() {
        XCTAssertEqual(runtime.voiceBooks(ids: []).count, 0)
    }

    func testVoiceBooks_matchingEmptyStringReturnsUpToLimit() {
        // Book.matches 空 query 恒 true → 全库命中；但函数会截到 10 条
        // （voiceBookLimit 私有了，只能间接验「≤10」和「≤ books.count」）
        let hits = runtime.voiceBooks(matching: "")
        XCTAssertLessThanOrEqual(hits.count, 10)
        XCTAssertLessThanOrEqual(hits.count, runtime.library.books.count)
    }

    func testVoiceBooks_matchingGibberishReturnsEmpty() {
        // 一堆随机字符不太可能真在书名/作者/章节里
        let nonsense = "zzqx-\(UUID().uuidString)"
        XCTAssertEqual(runtime.voiceBooks(matching: nonsense).count, 0)
    }

    func testSuggestedVoiceBooks_neverExceedsTen() {
        let list = runtime.suggestedVoiceBooks()
        XCTAssertLessThanOrEqual(list.count, 10)
    }

    func testSuggestedVoiceBooks_idsAreUnique() {
        // 补「未听过的开头」时靠 known 集合去重，重复 id 会让候选列表画两遍同一本
        let ids = runtime.suggestedVoiceBooks().map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count)
    }

    func testLastListenedVoiceBook_matchesHistoryHead() {
        let head = runtime.library.historyEntries().first
        let last = runtime.lastListenedVoiceBook
        XCTAssertEqual(last?.id, head?.book.id,
                       "「播我的书」默认落到最近收听的第一本；两边必须一致")
    }
}
