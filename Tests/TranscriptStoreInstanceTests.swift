import XCTest
@testable import Sonux

/// TranscriptStore 的实例侧只有一份单例：`.shared`；linesByChapter 在 load 之前是空表，
/// 所有以 chapter id 索引的读接口都要按「没有该章」的兜底语义返回 nil/-1/[]/false，
/// 保证播放页在没有字幕的旧数据上也不崩。
/// 至于 load(book:) 会读 Documents/transcripts/<书>.json，走 async Task.detached，
/// 交给 UI 集成用例覆盖。
@MainActor
final class TranscriptStoreInstanceTests: XCTestCase {
    private let unknownChapterID = "unknown-chapter-\(UUID().uuidString)"

    func testText_returnsNilForUnknownChapter() {
        XCTAssertNil(TranscriptStore.shared.text(forChapter: unknownChapterID, at: 10))
    }

    func testText_returnsNilForNilChapter() {
        XCTAssertNil(TranscriptStore.shared.text(forChapter: nil, at: 10))
    }

    func testLines_returnsEmptyForUnknownChapter() {
        XCTAssertEqual(TranscriptStore.shared.lines(forChapter: unknownChapterID), [])
        XCTAssertEqual(TranscriptStore.shared.lines(forChapter: nil), [])
    }

    func testLine_returnsNilForUnknownChapter() {
        XCTAssertNil(TranscriptStore.shared.line(forChapter: unknownChapterID, at: 0))
    }

    func testLineIndex_returnsMinusOneForUnknownChapter() {
        // 界面拿 -1 判「落在第一句之前」，不能返回 0 或崩溃
        XCTAssertEqual(TranscriptStore.shared.lineIndex(forChapter: unknownChapterID, at: 5), -1)
        XCTAssertEqual(TranscriptStore.shared.lineIndex(forChapter: nil, at: 5), -1)
    }

    func testHasTranscript_returnsFalseForUnknownChapter() {
        XCTAssertFalse(TranscriptStore.shared.hasTranscript(for: unknownChapterID))
        XCTAssertFalse(TranscriptStore.shared.hasTranscript(for: nil))
    }

    // MARK: - 内部 lineIndex 二分的边界（借公开 API 间接触发）

    /// 二分内部：lines.first 存在但 time < first.start → 返回 -1；
    /// 通过手动塞 linesByChapter 到共享单例是有副作用的，这里改用「已知为空的 chapter id」
    /// 至少覆盖 lines 空 → guard 走 -1 的分支。
    func testEmptyStore_lineIndexHitsGuardShortCircuit() {
        // 空表下 first == nil，直接 return -1；这是 lineIndex(lines:at:) 的第一条守卫
        XCTAssertEqual(TranscriptStore.shared.lineIndex(forChapter: "any", at: 100), -1)
    }
}
