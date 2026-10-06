import Foundation
import AVFoundation
import QuartzCore

enum LibraryError: LocalizedError {
    case deleteFailed(String, underlying: Error)

    var errorDescription: String? {
        switch self {
        case .deleteFailed(let name, let underlying):
            return LF("Failed to Delete \"%1$@\": %2$@", name, underlying.localizedDescription)
        }
    }
}

/// 书库的排序方式：默认按最近收听（最后播放时间从新到旧），菜单顺序就是这个 case 顺序
enum LibrarySort: String, CaseIterable, Identifiable {
    case lastPlayed
    case added
    case fileName

    var id: String { rawValue }

    var label: String {
        switch self {
        case .lastPlayed: return L("Recently Played")
        case .added: return L("Recently Added")
        case .fileName: return L("File Name")
        }
    }
}

/// 书库服务：扫描 File Sharing 目录，把音频文件组织成书，并持久化播放进度
@MainActor
final class LibraryService: ObservableObject {
    @Published private(set) var books: [Book] = []
    /// key: bookId，value: 该书最后播放位置（用于「继续收听」和书库列表进度）
    @Published private(set) var positions: [String: PlayPosition] = [:]
    /// key: chapterId，value: 该音频自己的历史播放位置（重新播放时从此处续播）
    @Published private(set) var chapterPositions: [String: PlayPosition] = [:]
    /// key: bookId，value: 该书最后一次播放时间（播放历史页按它排序）
    @Published private(set) var lastPlayedDates: [String: Date] = [:]
    /// key: bookId，value: 该书进书库的时间（按「最近添加」排序用），第一次扫到时补记，之后不再改
    @Published private(set) var addedDates: [String: Date] = [:]
    /// 收听时长统计（累计/按天/按书），由播放器每秒累加
    @Published private(set) var listening = ListeningStats()
    /// 首次扫描是否已出结果：未出结果前界面显示 loading，而不是「书库是空的」
    @Published private(set) var hasFinishedFirstScan = false

    nonisolated static let supportedExtensions: Set<String> = ["mp3", "m4a", "m4b", "aac", "wav", "wave"]

    /// 一条外部引用：只记下「音频在哪」的书签，不把音频拷进沙盒
    nonisolated private struct LibraryLink: Codable, Equatable {
        /// 引用 id：8 位随机串，给进度记账划命名空间用
        let id: String
        /// 导入时的条目名：书签读不到时还能在日志里说清是哪一条
        var name: String
        /// security-scoped bookmark，指向 iCloud Drive / 「文件」里的文件夹或音频
        var bookmark: Data
    }

    private let documentsDir: URL
    private let progressURL: URL
    private let metaCacheURL: URL
    private let snapshotURL: URL
    /// 外部引用清单（一条引用 = 导入时选中的一个条目 = 一本书）
    private let linksURL: URL
    private var links: [LibraryLink] = []
    /// 引用 id → 书签解析出来的条目地址（已占住安全域访问权）
    private var linkURLs: [String: URL] = [:]
    /// 引用 id → 记账基准目录，也就是条目自己的父目录：章节的相对路径都以它为底
    private var linkBases: [String: URL] = [:]
    /// 后台扫描任务防重入：上一次还没跑完时再触发，记下来结束后补扫一次
    private var scanning = false
    private var rescanRequestedWhileScanning = false

    init() {
        documentsDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        progressURL = appSupport.appendingPathComponent("progress.json")
        metaCacheURL = appSupport.appendingPathComponent("audio-meta.json")
        snapshotURL = appSupport.appendingPathComponent("library-snapshot.json")
        linksURL = appSupport.appendingPathComponent("links.json")
        // 冷启动的第一帧就要有内容：进度和上次扫描出的书库在 init 里同步读盘，
        // 真正的文件扫描留给 bootstrap 异步做，结果没变就不重绘，避免闪空状态
        let t0 = CACurrentMediaTime()
        loadProgress()
        let t1 = CACurrentMediaTime()
        loadSnapshot()
        NSLog("[sonux] init: 读进度 %.1f ms + 读书库快照 %.1f ms（%d 本书）",
              (t1 - t0) * 1000, (CACurrentMediaTime() - t1) * 1000, books.count)
        loadLinks()
    }

    /// 重新扫描书库（Documents + 外部引用），生成书目并保留已有进度
    /// 扫描与元数据读取在后台线程执行，避免阻塞主线程（真机上 1300+ 文件同步读时长要 3 秒）
    func rescan() {
        if scanning {
            rescanRequestedWhileScanning = true
            return
        }
        scanning = true
        let documentsDir = self.documentsDir
        let supportedExtensions = Self.supportedExtensions
        // 书签解析留在主线程：只在「没解析过」或「地址已失效」时才动书签，通常一条都不解析
        let tLink = CACurrentMediaTime()
        let linked = ensureLinkAccess()
        if !linked.isEmpty {
            NSLog("[sonux] rescan: 解析外部引用 %d 条，耗时 %.1f ms", linked.count, (CACurrentMediaTime() - tLink) * 1000)
        }
        Task.detached(priority: .userInitiated) {
            let t0 = CACurrentMediaTime()
            NSLog("[sonux] rescan: 后台开始扫描 documentsDir=%@", documentsDir.path)
            let scanned = Self.scanBooks(in: documentsDir, supportedExtensions: supportedExtensions,
                                         cacheURL: self.metaCacheURL, linked: linked)
            NSLog("[sonux] rescan: 识别出 %d 本书，耗时 %.1f ms", scanned.count, (CACurrentMediaTime() - t0) * 1000)
            // 书库快照另起低优先级任务落盘，不拖慢结果上屏
            let snapshotURL = self.snapshotURL
            Task.detached(priority: .utility) {
                Self.writeSnapshot(scanned, to: snapshotURL, documentsDir: documentsDir)
            }
            await MainActor.run {
                self.applyScanResult(scanned)
                self.hasFinishedFirstScan = true
                self.scanning = false
                if self.rescanRequestedWhileScanning {
                    self.rescanRequestedWhileScanning = false
                    self.rescan()
                }
            }
        }
    }

    /// 扫描结果回到主线程后赋值：清理已消失文件的进度并落盘
    private func applyScanResult(_ scanned: [Book]) {
        let previous = Set(books.map { "\($0.id):\($0.chapters.count)" })
        let current = Set(scanned.map { "\($0.id):\($0.chapters.count)" })
        if previous != current {
            self.books = scanned
        }
        let aliveBookIds = Set(scanned.map(\.id))
        let aliveChapterIds = Set(scanned.flatMap { $0.chapters.map(\.id) })
        // 书签这一时会儿解析不出来（iCloud 没连上）不等于书被删了：这些 id 是稳定的，
        // 进度留着，等引用恢复还能接着听
        let waiting = Set(links.filter { linkURLs[$0.id] == nil }.map { Self.namespace(forLink: $0.id) })
        func kept(_ id: String, alive: Set<String>) -> Bool {
            alive.contains(id) || waiting.contains { id.hasPrefix($0) }
        }
        positions = positions.filter { kept($0.key, alive: aliveBookIds) }
        chapterPositions = chapterPositions.filter { kept($0.key, alive: aliveChapterIds) }
        lastPlayedDates = lastPlayedDates.filter { kept($0.key, alive: aliveBookIds) }
        addedDates = addedDates.filter { kept($0.key, alive: aliveBookIds) }
        backfillAddedDates(scanned)
        backfillFinishedBooks()
        saveProgress()
    }

    /// 补记「哪天进的书库」：只处理没记过的书（也就是新导入的那几本），
    /// 取对应条目的创建时间；拿不到就按发现当天记，之后不再改
    private func backfillAddedDates(_ books: [Book]) {
        for book in books where addedDates[book.id] == nil {
            let values = url(for: book).flatMap { try? $0.resourceValues(forKeys: [.creationDateKey]) }
            addedDates[book.id] = values?.creationDate ?? Date()
        }
    }

    /// 补记完成日期：早先的版本不记「哪天听完的」，这里把已经听完但没日期的书
    /// 按它最后播放那天补一条，免得升级后「本月/本年听完几本」直接归零
    private func backfillFinishedBooks() {
        for book in books where listening.finished[book.id] == nil && isBookFinished(book) {
            listening.markFinished(bookId: book.id, at: lastPlayedDates[book.id] ?? Date())
        }
    }

    /// 第一帧渲染用的书库快照：只存 Documents 内条目的相对路径、标题、时长等纯数据，
    /// 章节 fileURL 由当前 Documents 路径重建，避免绝对路径在模拟器/真机间失效。
    /// 外部引用不进快照：它的地址要先解析书签才知道，冷启动不该在主线程上等 iCloud
    private struct SnapshotChapter: Codable {
        /// 章节 id：单章文件就是相对路径，内嵌章节的书是「相对路径#章号」
        var path: String
        /// 音频文件的相对路径；只在跟 id 不同时写（内嵌章节共用一个文件），旧快照没这个键
        var audio: String?
        var title: String
        var duration: TimeInterval
        /// 本章在文件里的起始秒；只在非 0 时写，旧快照没这个键按 0 处理
        var start: TimeInterval?

        init(_ chapter: Chapter, documentsDir: URL) {
            path = chapter.id
            title = chapter.title
            duration = chapter.duration
            // 内嵌章节的书多章共用一个文件：id 带「#章号」后缀，另存文件相对路径，别从 id 里猜
            if chapter.id.contains("#") {
                let file = LibraryService.relativePath(chapter.fileURL, base: documentsDir)
                audio = file == chapter.id ? nil : file
            }
            start = chapter.fileStart > 0 ? chapter.fileStart : nil
        }

        func chapter(bookId: String, index: Int, basePath: String) -> Chapter {
            // 章节上千个，直接拼已规范化的相对路径比逐段 appendingPathComponent 便宜
            Chapter(id: path, bookId: bookId, index: index, title: title, duration: duration,
                    fileURL: URL(fileURLWithPath: "\(basePath)/\(audio ?? path)"),
                    fileStart: start ?? 0)
        }
    }

    private struct SnapshotBook: Codable {
        var id: String
        var title: String
        var author: String?
        var storagePath: String
        var chapters: [SnapshotChapter]

        init(_ book: Book, documentsDir: URL) {
            id = book.id
            title = book.title
            author = book.author
            storagePath = book.storagePath
            chapters = book.chapters.map { SnapshotChapter($0, documentsDir: documentsDir) }
        }

        func book(basePath: String) -> Book {
            Book(id: id, title: title, author: author,
                 chapters: chapters.enumerated().map { $0.element.chapter(bookId: id, index: $0.offset, basePath: basePath) },
                 storagePath: storagePath)
        }
    }

    /// 读取书库快照，并按当前文件系统剔掉已消失的顶层条目
    private func loadSnapshot() {
        let t0 = CACurrentMediaTime()
        guard let data = try? Data(contentsOf: snapshotURL),
              let snapshot = try? JSONDecoder().decode([SnapshotBook].self, from: data) else { return }
        let t1 = CACurrentMediaTime()
        // 一次列目录就拿到全部顶层条目，避免逐本书 stat
        let existing = Set((try? FileManager.default.contentsOfDirectory(
            at: documentsDir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ).map { $0.lastPathComponent }) ?? [])
        let basePath = documentsDir.path
        books = snapshot.compactMap { item in
            let top = String(item.storagePath.prefix { $0 != "/" })
            guard existing.contains(top) else { return nil }
            return item.book(basePath: basePath)
        }
        NSLog("[sonux] loadSnapshot: 读盘+解码 %.1f ms（%d 字节），校验存在性+重建 %.1f ms",
              (t1 - t0) * 1000, data.count, (CACurrentMediaTime() - t1) * 1000)
    }

    /// 后台写入快照，供下次冷启动第一帧直接渲染
    /// 每次扫描成功都写，不比较差异：删除书后内存与扫描结果已经一致，
    /// 只有无条件落盘才不会把被删的书留在快照里（下次启动会闪出幽灵条目）
    nonisolated private static func writeSnapshot(_ books: [Book], to url: URL, documentsDir: URL) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let local = books.filter { $0.link == nil }
        guard let data = try? encoder.encode(local.map { SnapshotBook($0, documentsDir: documentsDir) }) else { return }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        } catch {
            NSLog("[sonux] writeSnapshot: 写入失败 %@", error.localizedDescription)
        }
    }

    /// 音频元数据缓存：按「相对路径 + 文件大小 + 修改时间」判断是否复用，
    /// 只有新增/替换过的文件才真正读元数据，扫描从秒级降到毫秒级
    nonisolated private struct AudioFileMeta: Codable, Equatable {
        var size: Int
        var mtime: Int
        var duration: TimeInterval
        var author: String?
        /// 内嵌章节 TOC（m4b 一类「一个文件装整本书」）：各章起点与章名；没有则为 nil
        var chapters: [EmbeddedChapter]?
    }

    /// 内嵌章节 TOC 的一条：本章在文件时间轴上的起始秒 + 内嵌章名
    nonisolated private struct EmbeddedChapter: Codable, Equatable {
        var start: TimeInterval
        var title: String
    }

    /// 后台执行：遍历目录并读取每个音频的时长/作者等元数据（优先命中磁盘缓存）
    /// - Parameters
    ///   - documentsDir: 本地书库根目录，这里的条目不带记账命名空间（历史进度才继续有效）
    ///   - linked: 已解析好的外部引用（引用 id + 条目地址），音频原地躺在 iCloud Drive / 「文件」里
    nonisolated private static func scanBooks(in documentsDir: URL, supportedExtensions: Set<String>, cacheURL: URL,
                                              linked: [(id: String, url: URL)]) -> [Book] {
        let fm = FileManager.default
        var books: [Book] = []
        let cache = loadMetaCache(from: cacheURL)
        var fresh: [String: AudioFileMeta] = [:]
        var misses = 0

        // 顶层条目：文件夹 = 多章节书；音频文件 = 单本书（内嵌章节 TOC 的一个文件也能出多章）
        let topItems: [URL]
        if let entries = try? fm.contentsOfDirectory(
            at: documentsDir,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) {
            topItems = entries.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        } else {
            topItems = []
            NSLog("[sonux] rescan: 读取 Documents 失败")
        }
        NSLog("[sonux] rescan: 顶层条目 %d 个", topItems.count)

        for entry in topItems {
            let isDir = (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            let book = isDir
                ? makeBook(fromFolder: entry, base: documentsDir, link: nil, cache: cache, fresh: &fresh, misses: &misses)
                : makeBook(fromFile: entry, base: documentsDir, link: nil,
                           supportedExtensions: supportedExtensions, cache: cache, fresh: &fresh, misses: &misses)
            if let book { books.append(book) }
        }

        // 外部引用：一条引用就是当初选中的那一个条目，跟它被拷进 Documents 时的待遇一致；
        // 记账基准目录取它的父目录，书名还是它自己的名字，字幕包也还能按同名找到
        for item in linked {
            let isDir = (try? item.url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            let base = item.url.deletingLastPathComponent()
            let book = isDir
                ? makeBook(fromFolder: item.url, base: base, link: item.id, cache: cache, fresh: &fresh, misses: &misses)
                : makeBook(fromFile: item.url, base: base, link: item.id,
                           supportedExtensions: supportedExtensions, cache: cache, fresh: &fresh, misses: &misses)
            if let book { books.append(book) }
        }
        // 只保留本次扫描仍存在的有效条目，避免缓存无限增长
        saveMetaCache(fresh, to: cacheURL)
        NSLog("[sonux] rescan: 元数据缓存命中 %d / 需读取 %d", fresh.count - misses, misses)
        return books
    }

    /// 取单个音频的元数据：大小和修改时间都没变则用缓存，否则重新读取并写入缓存
    nonisolated private static func meta(for file: URL, path: String, cache: [String: AudioFileMeta], fresh: inout [String: AudioFileMeta], misses: inout Int) -> AudioFileMeta {
        if let cached = fresh[path] {
            return cached
        }
        let values = try? file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let size = values?.fileSize ?? -1
        let mtime = Int((values?.contentModificationDate ?? .distantPast).timeIntervalSince1970)
        if let cached = cache[path], cached.size == size, cached.mtime == mtime {
            fresh[path] = cached
            return cached
        }
        // 一个文件只开一次 asset：时长、作者、内嵌章节都从它读
        let asset = AVURLAsset(url: file)
        let duration = audioDuration(of: asset)
        let meta = AudioFileMeta(size: size, mtime: mtime,
                                 duration: duration,
                                 author: audioAuthor(of: asset),
                                 chapters: embeddedChapters(of: asset, duration: duration))
        fresh[path] = meta
        misses += 1
        if let toc = meta.chapters {
            NSLog("[sonux] meta: %@ 读到内嵌章节 %d 条", path, toc.count)
        }
        return meta
    }

    nonisolated private static func loadMetaCache(from cacheURL: URL) -> [String: AudioFileMeta] {
        guard let data = try? Data(contentsOf: cacheURL),
              let map = try? JSONDecoder().decode([String: AudioFileMeta].self, from: data) else { return [:] }
        return map
    }

    nonisolated private static func saveMetaCache(_ cache: [String: AudioFileMeta], to cacheURL: URL) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        guard let data = try? encoder.encode(cache) else { return }
        do {
            try FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: cacheURL, options: .atomic)
        } catch {
            NSLog("[sonux] saveMetaCache: 写入失败 %@", error.localizedDescription)
        }
    }

    /// 第一本未听完的书（用于「继续收听」）
    func nextUnfinishedBook() -> Book? {
        books.first { book in
            guard let pos = positions[book.id] else { return true }
            guard let chapter = book.chapters.first(where: { $0.id == pos.chapterId }) else { return true }
            return !ProgressPolicy.isFinished(time: pos.time, duration: chapter.duration)
                || book.chapters.count > (chapter.index + 1)
        }
    }

    func book(id: String) -> Book? {
        books.first { $0.id == id }
    }

    /// 作者名归一化键：去首尾空白并忽略大小写，避免「张三 」与「张三」被当成两个人
    nonisolated static func authorKey(_ author: String) -> String {
        author.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// 某位作者的全部书，顺序沿用书库本身的排序
    func books(byAuthor author: String) -> [Book] {
        let key = Self.authorKey(author)
        guard !key.isEmpty else { return [] }
        return books.filter { $0.author.map { Self.authorKey($0) == key } ?? false }
    }

    /// 作者名去空格后的展示形式，供作者页标题使用
    static func displayAuthor(_ author: String) -> String {
        author.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 按用户选的排序方式排一组书：最近收听、最近添加从新到旧；
    /// 文件名称就是扫目录出来的自然序，原样返回（没听过的书没有日期，与同键值的书一起按书名兜底排最后）
    /// 排序键先算好再排，免得比较器里反复取字典与换算日期
    func sorted(_ books: [Book], by sort: LibrarySort) -> [Book] {
        guard sort != .fileName else { return books }
        let keyed = books.map { book -> (book: Book, key: Double, title: String) in
            let key: Double
            switch sort {
            case .fileName: key = 0
            case .added: key = addedDates[book.id]?.timeIntervalSince1970 ?? 0
            case .lastPlayed: key = lastPlayedDates[book.id]?.timeIntervalSince1970 ?? 0
            }
            return (book, key, book.title)
        }
        // 键值相同（都没听过、时长一样…）的书按书名自然序兜底，重排结果才不会每刷一次就跳一次
        return keyed.sorted {
            if $0.key != $1.key { return $0.key > $1.key }
            return $0.title.localizedStandardCompare($1.title) == .orderedAscending
        }.map(\.book)
    }

    func position(forBook id: String) -> PlayPosition? {
        positions[id]
    }

    /// 某个音频的历史播放位置
    func position(forChapter id: String) -> PlayPosition? {
        chapterPositions[id]
    }

    /// 全书收听进度 0...1：每章取「听到过的位置」相加再除以全书总时长，供书库卡片进度环使用
    /// 章节位置都持久化在 chapterPositions 里，所以跳过某章、听了中间某章都能算进来；
    /// 正在播的那章由播放器每秒上报 recordPosition，进度环会跟着实时增长
    func listeningProgress(for book: Book) -> Double {
        let total = book.totalDuration
        guard total > 0 else { return 0 }
        let listened = book.chapters.reduce(0.0) { sum, chapter in
            guard let time = chapterPositions[chapter.id]?.time else { return sum }
            // 已听完的章按整章计（位置可能差结尾 15 秒内，不该在进度里留个小缺口）
            if ProgressPolicy.isFinished(time: time, duration: chapter.duration) { return sum + chapter.duration }
            return sum + min(time, chapter.duration)
        }
        return min(max(listened / total, 0), 1)
    }

    /// 播放历史的一条：一本书 + 最后听到的章节与位置 + 最后播放时间
    struct HistoryEntry: Identifiable {
        let book: Book
        /// 最后播放的章节（书被删或章节对不上时为 nil）
        let chapter: Chapter?
        let position: PlayPosition?
        let lastPlayed: Date

        var id: String { book.id }
    }

    /// 播放历史：按最后播放时间从新到旧排序，只收录仍在书库里的书
    func historyEntries() -> [HistoryEntry] {
        lastPlayedDates.compactMap { bookId, date -> HistoryEntry? in
            guard let book = book(id: bookId) else { return nil }
            let position = positions[bookId]
            let chapter = position.flatMap { pos in book.chapters.first { $0.id == pos.chapterId } }
            return HistoryEntry(book: book, chapter: chapter, position: position, lastPlayed: date)
        }
        .sorted { $0.lastPlayed > $1.lastPlayed }
    }

    /// 把一本书从播放历史里移除（不动音频文件与播放进度）
    func removeFromHistory(bookId: String) {
        lastPlayedDates[bookId] = nil
        saveProgress()
    }

    // MARK: - 收听时长统计

    /// 播放器每秒上报的真实收听秒数：只累加到内存，落盘交给同一秒内的 recordPosition
    func addListening(seconds: TimeInterval, bookId: String) {
        listening.add(seconds: seconds, bookId: bookId)
    }

    /// 「我」页要用的收听统计快照：一次算完，避免视图 body 里反复遍历
    struct ListeningSummary {
        let totalSeconds: TimeInterval
        let todaySeconds: TimeInterval
        let last7Seconds: TimeInterval
        let streakDays: Int
        /// 近 7 天逐日时长（从旧到新，最后一个是今天），给「我」页的柱状图用
        let recentDays: [ListeningDay]
        /// 本月（自然月）累计收听秒数
        let monthSeconds: TimeInterval
        /// 本月整本听完的书数
        let monthFinished: Int

        var isEmpty: Bool { totalSeconds < 1 }
        /// 这个月有没有痕迹：一个月既没听也没听完，就不必在页面上摆一张空卡
        var hasMonthActivity: Bool { monthSeconds >= 1 || monthFinished > 0 }
    }

    func listeningSummary(now: Date = Date()) -> ListeningSummary {
        let month = ListeningStats.monthKey(now)
        return ListeningSummary(
            totalSeconds: listening.totalSeconds,
            todaySeconds: listening.seconds(on: now),
            last7Seconds: listening.seconds(in: 7, endingOn: now),
            streakDays: listening.streakDays(endingOn: now),
            recentDays: listening.recentDays(7, endingOn: now),
            monthSeconds: listening.seconds(in: month),
            monthFinished: listening.booksFinished(in: month)
        )
    }

    /// 收听报告页的快照：一整年一档
    struct ListeningReport {
        let year: Int
        let totalSeconds: TimeInterval
        let daysListened: Int
        let booksFinished: Int
        /// 逐月收听秒数，下标 0 是 1 月
        let monthly: [TimeInterval]
        /// 柱状图里该实心那一格（0 = 1 月），即报告这一年的本月
        let currentMonth: Int
    }

    func listeningReport(now: Date = Date(), calendar: Calendar = .current) -> ListeningReport {
        let year = calendar.component(.year, from: now)
        let bucket = ListeningStats.yearKey(now, calendar: calendar)
        return ListeningReport(
            year: year,
            totalSeconds: listening.seconds(in: bucket),
            daysListened: listening.daysListened(in: bucket),
            booksFinished: listening.booksFinished(in: bucket),
            monthly: listening.monthlySeconds(inYear: year),
            currentMonth: calendar.component(.month, from: now) - 1
        )
    }

    func recordPosition(_ position: PlayPosition, bookId: String, alsoForChapter: Bool = false) {
        positions[bookId] = position
        // 章节进度单独记一份，保证每章都有独立的历史位置
        if !alsoForChapter {
            chapterPositions[position.chapterId] = position
        }
        // 每次上报进度都刷新最后播放时间，播放历史页据此排序
        lastPlayedDates[bookId] = Date()
        markFinishedIfNeeded(bookId: bookId)
        saveProgress()
    }

    /// 一本书是否整本听完：每一章都播到了结尾附近（从没点开的章不算，跳过的章也不算听完）
    private func isBookFinished(_ book: Book) -> Bool {
        guard !book.chapters.isEmpty else { return false }
        return book.chapters.allSatisfy { chapter in
            guard let time = chapterPositions[chapter.id]?.time else { return false }
            return ProgressPolicy.isFinished(time: time, duration: chapter.duration)
        }
    }

    /// 跨过「整本听完」这条线时落一笔完成日期；听过的书都要每秒走到这里，
    /// 所以先按有没有记过筛掉，已经听完的书不再翻章
    private func markFinishedIfNeeded(bookId: String) {
        guard listening.finished[bookId] == nil, let book = book(id: bookId), isBookFinished(book) else { return }
        listening.markFinished(bookId: bookId)
    }

    /// 重置某个音频的历史播放位置（下次从头播放）
    func resetChapterProgress(chapterId: String) {
        chapterPositions[chapterId] = nil
        saveProgress()
    }

    /// 删除一本书：Documents 里的条目连文件一起删，外部引用只摘掉书签（原地的音频不动），
    /// 两者都清理播放进度
    /// 整个目录删除失败时（真机上可能因沙盒扩展属性报 EPERM），退化为逐个删除文件再清空目录
    func delete(book: Book, playingBookId: String? = nil, onStopPlaying: (() -> Void)? = nil) throws {
        NSLog("[sonux] delete: 开始删除《%@》storagePath=%@ 引用=%@", book.title, book.storagePath, book.link ?? "无")
        // 若删的正是当前播放的书，先停止播放，避免播放器持有已删除的文件
        if let playingBookId, playingBookId == book.id { onStopPlaying?() }

        if let link = book.link {
            removeLink(id: link)
        } else {
            let fm = FileManager.default
            let target = documentsDir.appendingPathComponent(book.storagePath)
            do {
                try fm.removeItem(at: target)
                NSLog("[sonux] delete: removeItem 整体删除成功")
            } catch {
                NSLog("[sonux] delete: 整体删除失败 %@，尝试逐个递归删除", String(describing: error))
                guard removeRecursively(at: target) else {
                    NSLog("[sonux] delete: 递归删除也失败，抛出错误")
                    throw LibraryError.deleteFailed(book.title, underlying: error)
                }
                NSLog("[sonux] delete: 递归删除成功")
            }
        }

        clearBookProgress(book)
        // 直接从内存书库移除并保存；全量 rescan 会阻塞主线程，改为后台异步补扫一次
        books.removeAll { $0.id == book.id }
        saveProgress()
        rescan()
    }

    /// 一本书的全部记账：进度、历史位置、最后播放时间、进书库的时间、收听时长
    private func clearBookProgress(_ book: Book) {
        positions[book.id] = nil
        for chapter in book.chapters { chapterPositions[chapter.id] = nil }
        lastPlayedDates[book.id] = nil
        addedDates[book.id] = nil
        listening.removeBook(book.id)
    }

    /// 递归删除：先删尽目录内所有文件，再从最深层开始删空目录；全部成功返回 true
    /// 注意：目标不存在时返回 false（路径错误应报错，不能当成删除成功）
    private func removeRecursively(at url: URL) -> Bool {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { return false }

        if isDir.boolValue {
            let children = (try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
            for child in children {
                guard removeRecursively(at: child) else { return false }
            }
        }
        do {
            try fm.removeItem(at: url)
        } catch {
            return false
        }
        return !fm.fileExists(atPath: url.path)
    }

    // MARK: - 外部引用：导入只记书签，不拷音频

    /// 从「文件」App 导入音频文件或文件夹：登记一条指向原地的 security-scoped 书签，
    /// 不把音频拷进沙盒——34 本、1300+ 文件复制一份等于同一批音频占两份空间
    /// - 文件夹 → 一本多章节书；单个音频 → 一本书（章节数由该文件的内嵌 TOC 决定）
    /// - 返回成功导入的条目数
    @discardableResult
    func importItems(from urls: [URL]) -> Int {
        var imported = 0
        for url in urls {
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            let isAudio = Self.supportedExtensions.contains(url.pathExtension.lowercased())
            guard isDir || isAudio else { continue }
            // 「文件」里能看到 Sonux 自己的 Documents，从那儿挑的条目本来就在书库里，不用再引一遍
            guard !Self.isInside(documentsDir, url) else { continue }
            // fileImporter 给的是「只在回调期间有效」的临时访问权，书签必须在这里当场建好
            guard let bookmark = Self.makeBookmark(for: url) else { continue }
            guard !alreadyLinked(to: url) else {
                NSLog("[sonux] import: 「%@」已经引用过，跳过", url.lastPathComponent)
                continue
            }
            links.append(LibraryLink(id: Self.newLinkID(), name: url.lastPathComponent, bookmark: bookmark))
            imported += 1
        }
        guard imported > 0 else { return 0 }
        saveLinks()
        rescan()
        return imported
    }

    /// 同一个条目记两份书签会在书库里出现两本同名书，所以先比一比书签指向哪儿
    private func alreadyLinked(to url: URL) -> Bool {
        let target = Self.normalized(url).path
        for link in links {
            // 只为比对而解析：读的是路径字符串，不必占安全域访问权，也不关心书签有没有过期
            var stale = false
            guard let resolved = try? URL(resolvingBookmarkData: link.bookmark, options: [],
                                          relativeTo: nil, bookmarkDataIsStale: &stale) else { continue }
            if Self.normalized(resolved).path == target { return true }
        }
        return false
    }

    /// 解析全部外部引用并占住安全域访问权：之后扫描元数据和播放器读文件都靠这一次授权。
    /// 每条引用只在「没解析过」或「原地址已经不在了」时才动书签，反复授权会把计数叠上去
    private func ensureLinkAccess() -> [(id: String, url: URL)] {
        let fm = FileManager.default
        var refreshed = false
        for index in links.indices {
            let link = links[index]
            if let url = linkURLs[link.id], fm.fileExists(atPath: url.path) { continue }
            if let old = linkURLs[link.id] { old.stopAccessingSecurityScopedResource() }
            linkURLs[link.id] = nil
            linkBases[link.id] = nil
            guard let resolved = Self.acquire(link.bookmark) else {
                NSLog("[sonux] link: 引用「%@」这次读不到，等下次扫描再试", link.name)
                continue
            }
            linkURLs[link.id] = resolved.url
            linkBases[link.id] = resolved.url.deletingLastPathComponent()
            // 书签会因卷标改名之类过期：解析出来的新书签就地换掉，下次启动就不用兜底
            if let data = resolved.refreshed { links[index].bookmark = data; refreshed = true }
            NSLog("[sonux] link: 引用「%@」指向 %@", link.name, resolved.url.path)
        }
        if refreshed { saveLinks() }
        return links.compactMap { link in linkURLs[link.id].map { (id: link.id, url: $0) } }
    }

    /// 摘掉一条外部引用：交回访问权、删掉书签。磁盘上的音频一点没动
    private func removeLink(id: String) {
        if let url = linkURLs[id] { url.stopAccessingSecurityScopedResource() }
        linkURLs[id] = nil
        linkBases[id] = nil
        links.removeAll { $0.id == id }
        saveLinks()
    }

    /// 一本书对应的磁盘位置：本地条目在 Documents 下，外部引用在它自己的基准目录下
    private func url(for book: Book) -> URL? {
        guard let link = book.link else { return documentsDir.appendingPathComponent(book.storagePath) }
        guard let base = linkBases[link] else { return nil }
        return base.appendingPathComponent(book.storagePath)
    }

    /// 给选中的条目建安全域书签：这是「不拷文件也能长期读到它」的唯一办法
    nonisolated private static func makeBookmark(for url: URL) -> Data? {
        let started = url.startAccessingSecurityScopedResource()
        defer { if started { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? url.bookmarkData(options: [.minimalBookmark],
                                               includingResourceValuesForKeys: nil, relativeTo: nil) else {
            NSLog("[sonux] import: 建书签失败 %@", url.lastPathComponent)
            return nil
        }
        return data
    }

    /// 解析书签并占住安全域访问权；第二个返回值是刷新过的书签（原书签过期时才给）
    nonisolated private static func acquire(_ bookmark: Data) -> (url: URL, refreshed: Data?)? {
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: bookmark, options: [],
                                 relativeTo: nil, bookmarkDataIsStale: &stale) else {
            NSLog("[sonux] link: 书签解析失败")
            return nil
        }
        guard url.startAccessingSecurityScopedResource() else {
            NSLog("[sonux] link: 拿不到安全域访问权 %@", url.lastPathComponent)
            return nil
        }
        guard stale else { return (url, nil) }
        return (url, try? url.bookmarkData(options: [.minimalBookmark],
                                          includingResourceValuesForKeys: nil, relativeTo: nil))
    }

    /// 引用 id：8 位随机串，短到能读进日志，也够避开碰撞
    nonisolated private static func newLinkID() -> String {
        String(UUID().uuidString.prefix(8)).lowercased()
    }

    private func loadLinks() {
        guard let data = try? Data(contentsOf: linksURL),
              let stored = try? JSONDecoder().decode([LibraryLink].self, from: data) else { return }
        links = stored
        NSLog("[sonux] loadLinks: %d 条外部引用", stored.count)
    }

    private func saveLinks() {
        let encoder = JSONEncoder()
        // 书签是 base64 大串，排序键让每次落盘的 diff 稳定
        encoder.outputFormatting = .sortedKeys
        guard let data = try? encoder.encode(links) else { return }
        do {
            // Data.write 不会创建中间目录，而 iOS 不预建 Application Support
            try FileManager.default.createDirectory(at: linksURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: linksURL, options: .atomic)
        } catch {
            NSLog("[sonux] saveLinks: 写入失败 %@", error.localizedDescription)
        }
    }

    // MARK: - Private

    nonisolated private static func makeBook(fromFolder folder: URL, base: URL, link: String?,
                                             cache: [String: AudioFileMeta], fresh: inout [String: AudioFileMeta],
                                             misses: inout Int) -> Book? {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: folder,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return nil }

        var audioFiles: [URL] = []
        for case let fileURL as URL in enumerator {
            if Self.supportedExtensions.contains(fileURL.pathExtension.lowercased()) {
                audioFiles.append(fileURL)
            }
        }
        guard !audioFiles.isEmpty else { return nil }

        audioFiles.sort { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        let namespace = namespace(forLink: link)
        let path = relativePath(folder, base: base)
        let bookId = namespace + "dir:\(path)"
        // 一个文件可能展开成多个逻辑章节（内嵌 TOC），章号按全书顺序累加
        var chapters: [Chapter] = []
        for file in audioFiles {
            chapters += makeChapters(file: file, bookId: bookId, firstIndex: chapters.count,
                                     base: base, link: link, cache: cache, fresh: &fresh, misses: &misses)
        }
        guard !chapters.isEmpty else { return nil }

        return Book(
            id: bookId,
            title: folder.lastPathComponent,
            author: fresh[namespace + relativePath(audioFiles[0], base: base)]?.author,
            chapters: chapters,
            storagePath: path,
            link: link
        )
    }

    /// 单个音频文件 = 一本书（章节数由它的内嵌 TOC 决定）
    nonisolated private static func makeBook(fromFile file: URL, base: URL, link: String?,
                                             supportedExtensions: Set<String>, cache: [String: AudioFileMeta],
                                             fresh: inout [String: AudioFileMeta], misses: inout Int) -> Book? {
        guard supportedExtensions.contains(file.pathExtension.lowercased()) else { return nil }
        let path = relativePath(file, base: base)
        let bookId = namespace(forLink: link) + "file:\(path)"
        let chapters = makeChapters(file: file, bookId: bookId, firstIndex: 0,
                                    base: base, link: link, cache: cache, fresh: &fresh, misses: &misses)
        guard !chapters.isEmpty else { return nil }
        return Book(
            id: bookId,
            title: file.deletingPathExtension().lastPathComponent,
            author: fresh[namespace(forLink: link) + path]?.author,
            chapters: chapters,
            storagePath: path,
            link: link
        )
    }

    /// 一个音频文件展开成若干章节：
    /// - 有内嵌章节 TOC（m4b 一类）：同一个 fileURL 拆成 N 个逻辑章节，各带自己的起点，
    ///   id 形如「记账键#章号」，进度、字幕、定时关闭都按这一章的粒度记账
    /// - 没有 TOC（或 TOC 只有一条）：仍是「一个文件 = 一章」，id 就是记账键，历史进度不失效
    /// 记账键 = 命名空间 + 相对基准目录的路径：外部引用冠上「link:<id>:」，
    /// 免得 iCloud 里的「XX/01.mp3」跟 Documents 里的同名文件串了进度
    nonisolated private static func makeChapters(file: URL, bookId: String, firstIndex: Int, base: URL, link: String?,
                                                 cache: [String: AudioFileMeta], fresh: inout [String: AudioFileMeta],
                                                 misses: inout Int) -> [Chapter] {
        let key = namespace(forLink: link) + relativePath(file, base: base)
        let meta = meta(for: file, path: key, cache: cache, fresh: &fresh, misses: &misses)
        guard var toc = meta.chapters, meta.duration > 0 else {
            return [Chapter(id: key, bookId: bookId, index: firstIndex, title: chapterTitle(from: file),
                            duration: meta.duration, fileURL: file)]
        }
        // TOC 的第一条可能不从 0 开始（片头没打点）：把开头空隙并进第一章，否则那一段永远听不到
        if let head = toc.first, head.start > 0 {
            toc[0] = EmbeddedChapter(start: 0, title: head.title)
        }
        return toc.enumerated().map { offset, item in
            // 本章到下一章的起点为止；最后一章取到文件结尾，免得结尾一小段没有章认领
            let end = offset + 1 < toc.count ? toc[offset + 1].start : meta.duration
            return Chapter(
                id: "\(key)#\(offset)",
                bookId: bookId,
                index: firstIndex + offset,
                title: item.title.isEmpty ? "\(firstIndex + offset + 1)" : item.title,
                duration: max(0, end - item.start),
                fileURL: file,
                fileStart: item.start
            )
        }
    }

    /// 外部引用的记账命名空间；Documents 里的条目不带前缀，老进度数据才继续有效
    nonisolated private static func namespace(forLink link: String?) -> String {
        guard let link else { return "" }
        return "link:\(link):"
    }

    nonisolated private static func relativePath(_ url: URL, base: URL) -> String {
        relativeComponents(url, under: base)?.joined(separator: "/") ?? url.path
    }

    /// url 是否落在 dir 里面
    nonisolated private static func isInside(_ dir: URL, _ url: URL) -> Bool {
        relativeComponents(url, under: dir) != nil
    }

    /// url 在 base 之下时返回去掉 base 之后的路径分量，否则返回 nil
    /// 不能用字符串前缀裁剪：真机上基准目录.path 带 /private 前缀而目录遍历结果不带，
    /// 前缀替换会残留 “private”。先统一规范化，再按路径分量逐段比较裁剪
    nonisolated private static func relativeComponents(_ url: URL, under base: URL) -> [String]? {
        let baseParts = Self.normalized(base).pathComponents
        let parts = Self.normalized(url).pathComponents
        guard parts.count > baseParts.count, Array(parts.prefix(baseParts.count)) == baseParts else { return nil }
        return Array(parts.dropFirst(baseParts.count))
    }

    /// 去掉 /var 路径的 /private 前缀，统一两种写法便于比较
    nonisolated private static func normalized(_ url: URL) -> URL {
        var path = url.standardizedFileURL.path
        if path.hasPrefix("/private/var") {
            path.removeFirst("/private".count)
        }
        return URL(fileURLWithPath: path)
    }

    /// 从文件名提取章节标题：去掉前导序号，如 "01 - 引言.mp3" -> "引言"
    nonisolated private static func chapterTitle(from url: URL) -> String {
        let base = url.deletingPathExtension().lastPathComponent
        let pattern = "^[0-9]+[\\.\\-−—\\s]+(.+)$"
        if let range = base.range(of: pattern, options: .regularExpression) {
            let title = base[range].replacingOccurrences(of: "^[0-9]+[\\.\\-−—\\s]+", with: "", options: .regularExpression)
            return title.trimmingCharacters(in: .whitespaces)
        }
        return base
    }

    nonisolated private static func audioDuration(of asset: AVAsset) -> TimeInterval {
        let seconds = CMTimeGetSeconds(asset.duration)
        return seconds.isFinite && seconds > 0 ? seconds : 0
    }

    /// 读音频内嵌的章节 TOC（章节轨或 chpl 原子），返回按起点排好的章列表；
    /// 没有 TOC、只有 1 条、或时间轴都落在文件之外时返回 nil，交给「一个文件 = 一章」的常规路径。
    ///
    /// 注意 locale：制作工具（ffmpeg、Calibre、各种转码器）常把章名标成 "und"（未标注语言），
    /// 只按用户偏好语言匹配会一条都取不到，所以匹配为空时再逐个 locale 取一次
    nonisolated private static func embeddedChapters(of asset: AVAsset, duration: TimeInterval) -> [EmbeddedChapter]? {
        guard duration > 0 else { return nil }
        var groups = asset.chapterMetadataGroups(bestMatchingPreferredLanguages: Locale.preferredLanguages)
        if groups.isEmpty {
            for locale in asset.availableChapterLocales {
                let found = asset.chapterMetadataGroups(withTitleLocale: locale,
                                                        containingItemsWithCommonKeys: [.commonKeyTitle])
                if !found.isEmpty {
                    groups = found
                    break
                }
            }
        }
        var toc: [EmbeddedChapter] = []
        for group in groups {
            let start = CMTimeGetSeconds(group.timeRange.start)
            guard start.isFinite, start >= 0, start < duration else { continue }
            // 比上一章起点还不挪 1 秒的条目（重复打点、空章）不要，否则会切出一段听不到的章
            if let last = toc.last, start <= last.start + 1 { continue }
            let title = group.items.first { $0.commonKey == .commonKeyTitle }?.stringValue
                ?? group.items.first?.stringValue
            toc.append(EmbeddedChapter(start: start,
                                       title: (title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)))
        }
        return toc.count > 1 ? toc : nil
    }

    /// 从音频元数据提取作者（artist / album artist 字段，取第一个非空值）
    nonisolated private static func audioAuthor(of asset: AVAsset) -> String? {
        let authorIDs: [AVMetadataIdentifier] = [
            .iTunesMetadataArtist, .iTunesMetadataAlbumArtist, .iTunesMetadataOriginalArtist,
            .quickTimeMetadataArtist, .quickTimeUserDataArtist,
        ]
        for item in asset.commonMetadata {
            let isAuthor = item.commonKey == .commonKeyArtist || authorIDs.contains { $0 == item.identifier }
            guard isAuthor else { continue }
            if let value = item.value as? String, !value.trimmingCharacters(in: .whitespaces).isEmpty {
                return value
            }
        }
        return nil
    }

    /// 持久化结构：书本进度 + 章节进度 + 最后播放时间 + 收听时长统计 + 添加时间
    /// 除两份进度外都写成可选：旧档缺键要能解出来（解码失败会整份丢掉进度），
    /// 缺的那部分由扫描时按文件的创建时间补记
    private struct ProgressStore: Codable {
        var books: [String: PlayPosition]
        var chapters: [String: PlayPosition]
        var lastPlayed: [String: Date]?
        var listening: ListeningStats?
        var added: [String: Date]?
    }

    private func saveProgress() {
        let t0 = CACurrentMediaTime()
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        // 进度里存有 Date（最后播放时间）：统一用秒级 epoch，与工具链生成的 JSON 互通
        encoder.dateEncodingStrategy = .secondsSince1970
        let store = ProgressStore(books: positions, chapters: chapterPositions,
                                  lastPlayed: lastPlayedDates, listening: listening, added: addedDates)
        guard let data = try? encoder.encode(store) else { return }
        do {
            // Data.write 不会创建中间目录，而 iOS 不预建 Application Support，先确保父目录存在
            try FileManager.default.createDirectory(
                at: progressURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: progressURL, options: .atomic)
        } catch {
            NSLog("[sonux] saveProgress: 写入失败 %@", error.localizedDescription)
        }
        let ms = (CACurrentMediaTime() - t0) * 1000
        if ms > 30 { NSLog("[sonux] saveProgress: 耗时 %.1f ms (bytes=%d, chapters=%d)", ms, data.count, chapterPositions.count) }
    }

    private func loadProgress() {
        guard let data = try? Data(contentsOf: progressURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        if let store = try? decoder.decode(ProgressStore.self, from: data) {
            positions = store.books
            chapterPositions = store.chapters
            lastPlayedDates = store.lastPlayed ?? [:]
            listening = store.listening ?? ListeningStats()
            addedDates = store.added ?? [:]
        } else if let old = try? decoder.decode([String: PlayPosition].self, from: data) {
            // 兼容旧格式：只有按书记录的进度，从中派生出章节历史位置
            positions = old
            chapterPositions = [:]
            for pos in old.values {
                chapterPositions[pos.chapterId] = pos
            }
        }
    }

    /// 启动时先读进度和书库快照（已在 init 完成）再后台扫描校验
    func bootstrap() {
        rescan()
    }
}
