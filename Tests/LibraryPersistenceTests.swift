import XCTest
@testable import Sonux

/// 书库持久化落盘 / 冷启动回读的端到端测试。
///
/// 靠 `LibraryService(documentsDir:appSupportDir:)` 这个注入点把整个「读盘 + 写盘」指向
/// 每例独立的临时沙盒，绝不碰模拟器里用户真实的 progress.json / library-snapshot.json。
/// 覆盖的是此前 0% 的几块私有逻辑：loadSnapshot 剔不存在条目、SnapshotChapter 按 basePath
/// 重建 fileURL、saveProgress/loadProgress 的 ProgressStore 往返、旧格式（只有按书进度）兼容、
/// 以及 recordPosition → markFinishedIfNeeded → 完成日期落盘这条链。
@MainActor
final class LibraryPersistenceTests: XCTestCase {
    private var docs: URL!
    private var appSupport: URL!

    override func setUpWithError() throws {
        let base = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("sonux-persist-\(UUID().uuidString)", isDirectory: true)
        docs = base.appendingPathComponent("Documents", isDirectory: true)
        appSupport = base.appendingPathComponent("AppSupport", isDirectory: true)
        try FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: docs.deletingLastPathComponent())
    }

    private func writeSnapshotJSON(_ text: String) throws {
        try text.data(using: .utf8)!.write(
            to: appSupport.appendingPathComponent("library-snapshot.json"))
    }

    /// 一份「一本书两章、单文件一章」的快照 JSON；顶层条目名 MyBook 需在 Documents 下建目录才会被保留
    private var twoChapterSnapshotJSON: String {
        """
        [{"id":"dir:MyBook","title":"我的书","author":"某作者","storagePath":"MyBook","chapters":[
          {"path":"MyBook/01.mp3","title":"第一章","duration":100},
          {"path":"MyBook/02.mp3","title":"第二章","duration":200}
        ]}]
        """
    }

    // MARK: - loadSnapshot：读回书库 + 按文件系统剔幽灵

    func testInit_loadsSnapshotBooksWhenTopLevelExists() throws {
        try FileManager.default.createDirectory(
            at: docs.appendingPathComponent("MyBook", isDirectory: true), withIntermediateDirectories: true)
        try writeSnapshotJSON(twoChapterSnapshotJSON)

        let lib = LibraryService(documentsDir: docs, appSupportDir: appSupport)
        XCTAssertEqual(lib.books.count, 1)
        let book = try XCTUnwrap(lib.books.first)
        XCTAssertEqual(book.id, "dir:MyBook")
        XCTAssertEqual(book.title, "我的书")
        XCTAssertEqual(book.author, "某作者")
        XCTAssertEqual(book.chapters.count, 2)
        // fileURL 用当前 basePath 重建（绝对路径不写进快照，换容器也不失效）
        XCTAssertEqual(book.chapters[0].fileURL.path,
                       docs.appendingPathComponent("MyBook/01.mp3").path)
        XCTAssertEqual(book.chapters[0].duration, 100)
    }

    func testInit_dropsBooksWhoseFolderWasDeleted() throws {
        // 快照里有条目，但 Documents 下对应顶层目录已不存在 → 冷启动剔掉，不闪幽灵卡片
        try writeSnapshotJSON(twoChapterSnapshotJSON)
        let lib = LibraryService(documentsDir: docs, appSupportDir: appSupport)
        XCTAssertTrue(lib.books.isEmpty)
    }

    func testInit_survivesMissingOrGarbageSnapshot() throws {
        // 没有快照文件：正常空启动
        XCTAssertTrue(LibraryService(documentsDir: docs, appSupportDir: appSupport).books.isEmpty)
        // 快照是坏 JSON：解不出来也不崩、退化成空
        try "not json {{{".data(using: .utf8)!.write(
            to: appSupport.appendingPathComponent("library-snapshot.json"))
        XCTAssertTrue(LibraryService(documentsDir: docs, appSupportDir: appSupport).books.isEmpty)
    }

    // MARK: - recordPosition → saveProgress → 冷启动 loadProgress 往返

    func testRecordPosition_persistsAndReloads() throws {
        try FileManager.default.createDirectory(
            at: docs.appendingPathComponent("MyBook", isDirectory: true), withIntermediateDirectories: true)
        try writeSnapshotJSON(twoChapterSnapshotJSON)

        let first = LibraryService(documentsDir: docs, appSupportDir: appSupport)
        first.recordPosition(PlayPosition(chapterId: "MyBook/02.mp3", time: 60),
                             bookId: "dir:MyBook")
        // 落盘文件确实生成了
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: appSupport.appendingPathComponent("progress.json").path))

        // 全新实例只靠读盘恢复按书进度、章节历史、最后播放时间
        let second = LibraryService(documentsDir: docs, appSupportDir: appSupport)
        XCTAssertEqual(second.position(forBook: "dir:MyBook")?.time, 60)
        XCTAssertEqual(second.position(forChapter: "MyBook/02.mp3")?.time, 60)
        XCTAssertNotNil(second.lastPlayedDates["dir:MyBook"])
    }

    func testProgressJSON_usesSecondsSince1970AndFullStoreKeys() throws {
        try FileManager.default.createDirectory(
            at: docs.appendingPathComponent("MyBook", isDirectory: true), withIntermediateDirectories: true)
        try writeSnapshotJSON(twoChapterSnapshotJSON)
        let lib = LibraryService(documentsDir: docs, appSupportDir: appSupport)
        lib.recordPosition(PlayPosition(chapterId: "MyBook/01.mp3", time: 30), bookId: "dir:MyBook")

        let data = try Data(contentsOf: appSupport.appendingPathComponent("progress.json"))
        let obj = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        // 五族键齐全
        for key in ["books", "chapters", "lastPlayed", "listening", "added"] {
            XCTAssertNotNil(obj[key], "进度文件应含 \(key)")
        }
        // Date 用秒级 epoch（与工具链互通），不是 ISO 字符串
        let lastPlayed = obj["lastPlayed"] as! [String: Any]
        XCTAssertTrue(lastPlayed["dir:MyBook"] is NSNumber,
                      "lastPlayed 应是秒级 epoch 数字，实得 \(type(of: lastPlayed["dir:MyBook"]))")
    }

    // MARK: - 旧格式兼容：只有按书进度，从中派生章节历史

    func testLoadProgress_oldPerBookFormatDerivesChapterPositions() throws {
        // 早期 progress.json 就是 [String: PlayPosition]，没有 books/chapters 外层
        let old = #"{"MyBook/01.mp3":{"chapterId":"MyBook/01.mp3","time":42}}"#
        try old.data(using: .utf8)!.write(
            to: appSupport.appendingPathComponent("progress.json"))
        let lib = LibraryService(documentsDir: docs, appSupportDir: appSupport)
        XCTAssertEqual(lib.position(forChapter: "MyBook/01.mp3")?.time, 42,
                       "旧格式只有按书进度，章节历史位置要从中派生")
    }

    func testLoadProgress_garbageFileYieldsCleanEmptyState() throws {
        try "}{ not json".data(using: .utf8)!.write(
            to: appSupport.appendingPathComponent("progress.json"))
        let lib = LibraryService(documentsDir: docs, appSupportDir: appSupport)
        XCTAssertNil(lib.position(forBook: "dir:MyBook"))
        XCTAssertEqual(lib.listening.totalSeconds, 0)
    }

    // MARK: - 整本听完 → 完成日期落盘并回读

    func testMarkFinished_whenAllChaptersReachEnd_persistsFinishedDate() throws {
        try FileManager.default.createDirectory(
            at: docs.appendingPathComponent("MyBook", isDirectory: true), withIntermediateDirectories: true)
        try writeSnapshotJSON(twoChapterSnapshotJSON)
        let lib = LibraryService(documentsDir: docs, appSupportDir: appSupport)
        // 两章都记到接近结尾（isFinished：剩余 ≤ 15 s）
        lib.recordPosition(PlayPosition(chapterId: "MyBook/01.mp3", time: 100), bookId: "dir:MyBook")
        lib.recordPosition(PlayPosition(chapterId: "MyBook/02.mp3", time: 195), bookId: "dir:MyBook")
        XCTAssertNotNil(lib.listening.finished["dir:MyBook"], "整本播完应落下完成日期")

        // 完成日期跟着进度一起落盘，冷启动后仍在
        let reloaded = LibraryService(documentsDir: docs, appSupportDir: appSupport)
        XCTAssertNotNil(reloaded.listening.finished["dir:MyBook"])
    }

    // MARK: - removeFromHistory / resetChapterProgress 的落盘副作用

    func testResetChapterProgress_persistsClearedPosition() throws {
        try FileManager.default.createDirectory(
            at: docs.appendingPathComponent("MyBook", isDirectory: true), withIntermediateDirectories: true)
        try writeSnapshotJSON(twoChapterSnapshotJSON)
        let lib = LibraryService(documentsDir: docs, appSupportDir: appSupport)
        lib.recordPosition(PlayPosition(chapterId: "MyBook/01.mp3", time: 50), bookId: "dir:MyBook")
        lib.resetChapterProgress(chapterId: "MyBook/01.mp3")

        let reloaded = LibraryService(documentsDir: docs, appSupportDir: appSupport)
        XCTAssertNil(reloaded.position(forChapter: "MyBook/01.mp3"),
                     "重置章节进度要落盘，冷启动后不能再冒出来")
    }

    // MARK: - 进度链的上游：PlayerService.reportPosition → onPositionChange

    /// 播放器 seek 时会经 reportPosition 抛一次进度（生产里这个回调再接到 library.recordPosition）。
    /// 只挂了书没装音频时也照抛——用 seek 触发，全程不建 AVPlayerItem、不出声。
    func testPlayerSeek_firesPositionChangeCallback() {
        let p = PlayerService()
        let chapter = Chapter(id: "pc1", bookId: "pb", index: 0, title: "第一章",
                              duration: 120, fileURL: URL(fileURLWithPath: "/tmp/p.mp3"))
        let book = Book(id: "pb", title: "T", author: nil, chapters: [chapter], storagePath: "pb")
        p.prepareToResume(book: book, chapter: chapter, at: 0)

        var reported: PlayPosition?
        p.onPositionChange = { reported = $0 }
        p.seek(to: 42)
        XCTAssertEqual(reported?.chapterId, "pc1")
        XCTAssertEqual(reported?.time ?? -1, 42, accuracy: 1e-6)
    }

    /// onListening 回调：播放器把真实收听秒数交给上层累加，书库端按书记账。
    /// 这里把两端手工串起来，验证「播放器报秒 → 书库 addListening → 落盘」的接线契约。
    func testPlayerListeningCallbackFeedsLibraryAddListening() throws {
        try FileManager.default.createDirectory(
            at: docs.appendingPathComponent("MyBook", isDirectory: true), withIntermediateDirectories: true)
        try writeSnapshotJSON(twoChapterSnapshotJSON)
        let lib = LibraryService(documentsDir: docs, appSupportDir: appSupport)

        let p = PlayerService()
        p.onListening = { seconds, bookId in lib.addListening(seconds: seconds, bookId: bookId) }
        p.onListening?(10, "dir:MyBook")
        p.onListening?(15, "dir:MyBook")
        XCTAssertEqual(lib.listening.byBook["dir:MyBook"], 25)

        // 让这条统计随进度一起落盘（addListening 只进内存，recordPosition 才 saveProgress）
        lib.recordPosition(PlayPosition(chapterId: "MyBook/01.mp3", time: 5), bookId: "dir:MyBook")
        let reloaded = LibraryService(documentsDir: docs, appSupportDir: appSupport)
        XCTAssertEqual(reloaded.listening.byBook["dir:MyBook"] ?? -1, 25, accuracy: 1e-6)
    }
}
