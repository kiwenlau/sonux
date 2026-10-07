import XCTest
@testable import Sonux

/// Chapter 是纯值类型：三个转换方法 localTime / fileTime / fileEnd 只做加减，
/// 外加 init(from:) 的 fileStart 向后兼容分支——旧进度 JSON 里根本没这个键。
final class ChapterTests: XCTestCase {
    private func makeChapter(fileStart: TimeInterval, duration: TimeInterval) -> Chapter {
        Chapter(id: "c1", bookId: "b1", index: 0, title: "T",
                duration: duration, fileURL: URL(fileURLWithPath: "/tmp/x.mp3"),
                fileStart: fileStart)
    }

    func testFileEnd_equalsStartPlusDuration() {
        XCTAssertEqual(makeChapter(fileStart: 0, duration: 60).fileEnd, 60)
        XCTAssertEqual(makeChapter(fileStart: 100, duration: 30).fileEnd, 130)
    }

    func testFileStartDefaultsToZero() {
        let chapter = Chapter(id: "c", bookId: "b", index: 0, title: "t",
                              duration: 10, fileURL: URL(fileURLWithPath: "/tmp/x.mp3"))
        XCTAssertEqual(chapter.fileStart, 0)
    }

    func testLocalTime_clampsToNonNegative() {
        let chapter = makeChapter(fileStart: 100, duration: 50)
        // 章内秒不能负：文件时间比 chapter 起点还早时截到 0
        XCTAssertEqual(chapter.localTime(90), 0)
        XCTAssertEqual(chapter.localTime(100), 0)
        XCTAssertEqual(chapter.localTime(120), 20)
        XCTAssertEqual(chapter.localTime(150), 50)
        // 超出章尾也保持减法结果（截断由调用方处理）
        XCTAssertEqual(chapter.localTime(200), 100)
    }

    func testFileTime_isSimpleOffset() {
        let chapter = makeChapter(fileStart: 100, duration: 50)
        XCTAssertEqual(chapter.fileTime(0), 100)
        XCTAssertEqual(chapter.fileTime(20), 120)
        // fileTime 不做截断，越界由调用方负责
        XCTAssertEqual(chapter.fileTime(-5), 95)
    }

    // MARK: - Codable 兼容

    /// 用一份份不带 fileStart 的 JSON 手动解码，验证 init(from:) 里的 decodeIfPresent 兜底路径。
    func testDecode_missingFileStartDefaultsToZero() throws {
        let json = """
        {"id":"c","bookId":"b","index":0,"title":"T","duration":60,
         "fileURL":"file:///tmp/x.mp3"}
        """.data(using: .utf8)!
        let chapter = try JSONDecoder().decode(Chapter.self, from: json)
        XCTAssertEqual(chapter.fileStart, 0)
        XCTAssertEqual(chapter.duration, 60)
        XCTAssertEqual(chapter.id, "c")
    }

    func testDecode_presentFileStartIsPreserved() throws {
        let chapter = makeChapter(fileStart: 250.5, duration: 100)
        let data = try JSONEncoder().encode(chapter)
        let decoded = try JSONDecoder().decode(Chapter.self, from: data)
        XCTAssertEqual(decoded, chapter)
        XCTAssertEqual(decoded.fileStart, 250.5)
    }

    func testRoundtrip_allFieldsSurvive() throws {
        let original = Chapter(id: "c1", bookId: "b9", index: 7, title: "第七章",
                               duration: 1234.5, fileURL: URL(fileURLWithPath: "/tmp/dir/07.m4a"),
                               fileStart: 42.0)
        let decoded = try JSONDecoder().decode(Chapter.self, from: JSONEncoder().encode(original))
        XCTAssertEqual(decoded, original)
    }
}
