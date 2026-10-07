import XCTest
@testable import Sonux

/// PlayPosition 是章节进度 JSON 里的最小单元：chapterId + time；两个字段都是 required。
/// NowPlayingSnapshot 是 App Group 桥的小组件快照：每个字段都给了缺省值，
/// 为的是将来加字段时旧快照不至于整份解不出来（画空态比凭空丢一本更糟）。
final class ProgressValueTests: XCTestCase {
    // MARK: - PlayPosition

    func testPlayPosition_roundtrip() throws {
        let p = PlayPosition(chapterId: "c1", time: 42.5)
        let decoded = try JSONDecoder().decode(PlayPosition.self, from: JSONEncoder().encode(p))
        XCTAssertEqual(decoded, p)
    }

    func testPlayPosition_equatable() {
        XCTAssertEqual(PlayPosition(chapterId: "a", time: 1), PlayPosition(chapterId: "a", time: 1))
        XCTAssertNotEqual(PlayPosition(chapterId: "a", time: 1), PlayPosition(chapterId: "b", time: 1))
        XCTAssertNotEqual(PlayPosition(chapterId: "a", time: 1), PlayPosition(chapterId: "a", time: 2))
    }

    func testPlayPosition_decodesRequiredFields() throws {
        let json = #"{"chapterId":"c1","time":10.5}"#
        let p = try JSONDecoder().decode(PlayPosition.self, from: json.data(using: .utf8)!)
        XCTAssertEqual(p.chapterId, "c1")
        XCTAssertEqual(p.time, 10.5)
    }

    // MARK: - NowPlayingSnapshot

    func testSnapshot_roundtripKeepsAllFields() throws {
        let s = NowPlayingSnapshot(bookId: "b1", bookTitle: "百年孤独",
                                   author: "马尔克斯", chapterTitle: "第七章",
                                   isPlaying: true, hasArtwork: true)
        let decoded = try JSONDecoder().decode(NowPlayingSnapshot.self, from: JSONEncoder().encode(s))
        XCTAssertEqual(decoded, s)
    }

    func testSnapshot_hasArtworkDefaultsToFalseInInit() {
        // 不显式传 hasArtwork 时默认 false，因为占位封面才是常见情况
        let s = NowPlayingSnapshot(bookId: "b", bookTitle: "T", author: nil,
                                   chapterTitle: "C", isPlaying: false)
        XCTAssertFalse(s.hasArtwork)
        XCTAssertNil(s.author)
    }

    /// 关键：将来加字段（例如 hasArtwork）之前，小组件容器里可能残留旧格式的 now-playing.json；
    /// 逐字段 decodeIfPresent 让整份 JSON 依然能解出来，只是缺的字段用缺省值。
    func testSnapshot_decodesLegacyJSONWithoutNewFields() throws {
        // 假设这是加 hasArtwork 之前的旧快照
        let legacy = """
        {"bookId":"b1","bookTitle":"旧格式","chapterTitle":"C","isPlaying":true}
        """.data(using: .utf8)!
        let s = try JSONDecoder().decode(NowPlayingSnapshot.self, from: legacy)
        XCTAssertEqual(s.bookId, "b1")
        XCTAssertEqual(s.bookTitle, "旧格式")
        XCTAssertTrue(s.isPlaying)
        XCTAssertNil(s.author)
        XCTAssertFalse(s.hasArtwork, "缺失字段应回退到 false，不能崩")
    }

    func testSnapshot_emptyJSONYieldsAllDefaults() throws {
        // 极端脏数据：{} 也要能解出可用的空快照，小组件画「暂无播放」而不是消失
        let s = try JSONDecoder().decode(NowPlayingSnapshot.self, from: "{}".data(using: .utf8)!)
        XCTAssertEqual(s.bookId, "")
        XCTAssertEqual(s.bookTitle, "")
        XCTAssertEqual(s.chapterTitle, "")
        XCTAssertFalse(s.isPlaying)
        XCTAssertFalse(s.hasArtwork)
        XCTAssertNil(s.author)
    }

    func testSnapshot_sampleIsPlayable() {
        // 组件画廊里的占位数据：isPlaying=true 让预览能看到音柱动画
        XCTAssertTrue(NowPlayingSnapshot.sample.isPlaying)
        XCTAssertFalse(NowPlayingSnapshot.sample.bookTitle.isEmpty)
    }
}
