import XCTest
@testable import Sonux

/// TranscriptFile 是 Documents/transcripts/*.json 的解码壳：每行是 [起,止,文] 三元数组。
/// lines(forChapterFile:) 里做三件事：trim 空白、丢空句、丢 end ≤ start 的脏行、按 start 排序。
final class TranscriptFileTests: XCTestCase {
    private func decode(_ json: String) throws -> TranscriptFile {
        try JSONDecoder().decode(TranscriptFile.self, from: json.data(using: .utf8)!)
    }

    func testDecode_minimalShape() throws {
        let file = try decode("""
        {"v":1,"chapters":{"01.mp3":[[0.0,2.5,"你好"],[2.5,5.0,"世界"]]}}
        """)
        XCTAssertEqual(file.chapters.count, 1)
        XCTAssertEqual(file.chapters["01.mp3"]?.count, 2)
        XCTAssertEqual(file.chapters["01.mp3"]?[0].start, 0)
        XCTAssertEqual(file.chapters["01.mp3"]?[0].end, 2.5)
        XCTAssertEqual(file.chapters["01.mp3"]?[0].text, "你好")
    }

    func testDecode_missingChaptersKeyYieldsEmpty() throws {
        // 只有版本号没有 chapters 也不能崩，全库空表更利于兜底
        let file = try decode(#"{"v":1}"#)
        XCTAssertTrue(file.chapters.isEmpty)
    }

    func testDecode_explicitNullChaptersYieldsEmpty() throws {
        let file = try decode(#"{"v":1,"chapters":null}"#)
        XCTAssertTrue(file.chapters.isEmpty)
    }

    // MARK: - lines(forChapterFile:)

    func testLines_missingChapterReturnsEmpty() throws {
        let file = try decode(#"{"v":1,"chapters":{"a.mp3":[[0,1,"x"]]}}"#)
        XCTAssertEqual(file.lines(forChapterFile: "missing.mp3"), [])
    }

    func testLines_returnsSortedAscendingByStart() throws {
        // 故意把时间戳打乱写入，读出来必须按 start 排好
        let file = try decode("""
        {"v":1,"chapters":{"a.mp3":[[5,6,"e"],[1,2,"b"],[3,4,"c"]]}}
        """)
        let lines = file.lines(forChapterFile: "a.mp3")
        XCTAssertEqual(lines.map(\.start), [1, 3, 5])
        XCTAssertEqual(lines.map(\.text), ["b", "c", "e"])
    }

    func testLines_dropsBlankText() throws {
        // 只有空格/换行的行被丢弃，因为播放页会把它们当成空白闪一下
        let file = try decode("""
        {"v":1,"chapters":{"a.mp3":[[0,1,"  "],[1,2,"\\n\\t"],[2,3,"有内容"]]}}
        """)
        let lines = file.lines(forChapterFile: "a.mp3")
        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(lines[0].text, "有内容")
    }

    func testLines_dropsInvertedTimestamps() throws {
        // end ≤ start 是脏数据（转写偶发），要过滤，否则字幕会瞬闪
        let file = try decode("""
        {"v":1,"chapters":{"a.mp3":[[5,3,"倒挂"],[2,2,"等长"],[0,1,"正常"]]}}
        """)
        let lines = file.lines(forChapterFile: "a.mp3")
        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(lines[0].text, "正常")
    }

    func testLines_trimsWhitespaceAroundRealText() throws {
        // 首尾都是空格（U+0020）：JSON 里直接放就 OK，不用转义 \n 那种坑
        let file = try decode(#"{"v":1,"chapters":{"a.mp3":[[0,1,"  中间有内容  "]]}}"#)
        let lines = file.lines(forChapterFile: "a.mp3")
        XCTAssertEqual(lines.first?.text, "中间有内容")
    }

    func testLines_equatableValue() throws {
        let file = try decode(#"{"v":1,"chapters":{"a.mp3":[[1.5,2.5,"hi"]]}}"#)
        let lines = file.lines(forChapterFile: "a.mp3")
        XCTAssertEqual(lines.first, TranscriptLine(start: 1.5, end: 2.5, text: "hi"))
    }
}
