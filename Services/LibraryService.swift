import Foundation
import AVFoundation
import QuartzCore

enum LibraryError: LocalizedError {
    case deleteFailed(String, underlying: Error)

    var errorDescription: String? {
        switch self {
        case .deleteFailed(let name, let underlying):
            return "删除「\(name)」失败：\(underlying.localizedDescription)"
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
    /// 收听时长统计（累计/按天/按书），由播放器每秒累加
    @Published private(set) var listening = ListeningStats()
    /// 首次扫描是否已出结果：未出结果前界面显示 loading，而不是「书库是空的」
    @Published private(set) var hasFinishedFirstScan = false

    nonisolated static let supportedExtensions: Set<String> = ["mp3", "m4a", "m4b", "aac", "wav", "wave"]

    private let documentsDir: URL
    private let progressURL: URL
    private let metaCacheURL: URL
    private let snapshotURL: URL
    /// 后台扫描任务防重入：上一次还没跑完时再触发，记下来结束后补扫一次
    private var scanning = false
    private var rescanRequestedWhileScanning = false

    init() {
        documentsDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        progressURL = appSupport.appendingPathComponent("progress.json")
        metaCacheURL = appSupport.appendingPathComponent("audio-meta.json")
        snapshotURL = appSupport.appendingPathComponent("library-snapshot.json")
        // 冷启动的第一帧就要有内容：进度和上次扫描出的书库在 init 里同步读盘，
        // 真正的文件扫描留给 bootstrap 异步做，结果没变就不重绘，避免闪空状态
        let t0 = CACurrentMediaTime()
        loadProgress()
        let t1 = CACurrentMediaTime()
        loadSnapshot()
        NSLog("[sonux] init: 读进度 %.1f ms + 读书库快照 %.1f ms（%d 本书）",
              (t1 - t0) * 1000, (CACurrentMediaTime() - t1) * 1000, books.count)
    }

    /// 重新扫描 Documents 目录，生成书库（保留已有进度）
    /// 扫描与元数据读取在后台线程执行，避免阻塞主线程（真机上 1300+ 文件同步读时长要 3 秒）
    func rescan() {
        if scanning {
            rescanRequestedWhileScanning = true
            return
        }
        scanning = true
        let documentsDir = self.documentsDir
        let supportedExtensions = Self.supportedExtensions
        Task.detached(priority: .userInitiated) {
            let t0 = CACurrentMediaTime()
            NSLog("[sonux] rescan: 后台开始扫描 documentsDir=%@", documentsDir.path)
            let scanned = Self.scanBooks(in: documentsDir, supportedExtensions: supportedExtensions, cacheURL: self.metaCacheURL)
            NSLog("[sonux] rescan: 识别出 %d 本书，耗时 %.1f ms", scanned.count, (CACurrentMediaTime() - t0) * 1000)
            // 书库快照另起低优先级任务落盘，不拖慢结果上屏
            let snapshotURL = self.snapshotURL
            Task.detached(priority: .utility) {
                Self.writeSnapshot(scanned, to: snapshotURL)
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
        positions = positions.filter { aliveBookIds.contains($0.key) }
        let aliveChapterIds = Set(scanned.flatMap { $0.chapters.map(\.id) })
        chapterPositions = chapterPositions.filter { aliveChapterIds.contains($0.key) }
        lastPlayedDates = lastPlayedDates.filter { aliveBookIds.contains($0.key) }
        saveProgress()
    }

    /// 第一帧渲染用的书库快照：只存相对路径、标题、时长等纯数据，
    /// 章节 fileURL 由当前 Documents 路径重建，避免绝对路径在模拟器/真机间失效
    private struct SnapshotChapter: Codable {
        var path: String
        var title: String
        var duration: TimeInterval

        init(_ chapter: Chapter) {
            path = chapter.id
            title = chapter.title
            duration = chapter.duration
        }

        func chapter(bookId: String, index: Int, basePath: String) -> Chapter {
            // 章节上千个，直接拼已规范化的相对路径比逐段 appendingPathComponent 便宜
            Chapter(id: path, bookId: bookId, index: index, title: title, duration: duration,
                    fileURL: URL(fileURLWithPath: "\(basePath)/\(path)"))
        }
    }

    private struct SnapshotBook: Codable {
        var id: String
        var title: String
        var author: String?
        var storagePath: String
        var chapters: [SnapshotChapter]

        init(_ book: Book) {
            id = book.id
            title = book.title
            author = book.author
            storagePath = book.storagePath
            chapters = book.chapters.map(SnapshotChapter.init)
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
    nonisolated private static func writeSnapshot(_ books: [Book], to url: URL) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        guard let data = try? encoder.encode(books.map(SnapshotBook.init)) else { return }
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
    }

    /// 后台执行：遍历目录并读取每个音频的时长/作者等元数据（优先命中磁盘缓存）
    nonisolated private static func scanBooks(in documentsDir: URL, supportedExtensions: Set<String>, cacheURL: URL) -> [Book] {
        let fm = FileManager.default
        var books: [Book] = []
        var cache = loadMetaCache(from: cacheURL)
        var fresh: [String: AudioFileMeta] = [:]
        var misses = 0

        // 顶层条目：文件夹 = 多章节书；音频文件 = 单本书
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
            if isDir {
                if let book = makeBook(fromFolder: entry, documentsDir: documentsDir, cache: cache, fresh: &fresh, misses: &misses) {
                    books.append(book)
                }
            } else if supportedExtensions.contains(entry.pathExtension.lowercased()) {
                let path = relativePath(entry, documentsDir: documentsDir)
                let bookId = "file:\(path)"
                if let chapter = makeChapter(file: entry, bookId: bookId, index: 0, documentsDir: documentsDir, cache: cache, fresh: &fresh, misses: &misses) {
                    books.append(Book(
                        id: bookId,
                        title: entry.deletingPathExtension().lastPathComponent,
                        author: fresh[path]?.author,
                        chapters: [chapter],
                        storagePath: path
                    ))
                }
            }
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
        let meta = AudioFileMeta(size: size, mtime: mtime,
                                 duration: audioDuration(of: file),
                                 author: audioAuthor(of: file))
        fresh[path] = meta
        misses += 1
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

    func position(forBook id: String) -> PlayPosition? {
        positions[id]
    }

    /// 某个音频的历史播放位置
    func position(forChapter id: String) -> PlayPosition? {
        chapterPositions[id]
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
        let listenedDays: Int
        let averagePerDay: TimeInterval
        /// 近 7 天逐日时长，旧的在前
        let recentDays: [ListeningDay]
        /// 收听最多的书（最多 5 本）
        let topBooks: [ListenedBook]
        /// 收听过（有秒数记录且仍在书库里）的书本数
        let listenedBookCount: Int

        var isEmpty: Bool { totalSeconds < 1 }
    }

    func listeningSummary(now: Date = Date()) -> ListeningSummary {
        let recent = listening.recentDays(7, endingOn: now)
        let top = listening.topBooks(limit: 5, books: books)
        let days = listening.listenedDays
        // 收听过且仍在书库里的书本数
        let listenedBooks = books.filter { (listening.byBook[$0.id] ?? 0) > 0 }
        return ListeningSummary(
            totalSeconds: listening.totalSeconds,
            todaySeconds: listening.seconds(on: now),
            last7Seconds: listening.seconds(in: 7, endingOn: now),
            streakDays: listening.streakDays(endingOn: now),
            listenedDays: days,
            averagePerDay: days > 0 ? listening.totalSeconds / Double(days) : 0,
            recentDays: recent,
            topBooks: top,
            listenedBookCount: listenedBooks.count
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
        saveProgress()
    }

    /// 重置某个音频的历史播放位置（下次从头播放）
    func resetChapterProgress(chapterId: String) {
        chapterPositions[chapterId] = nil
        saveProgress()
    }

    /// 删除一本书：移除 Documents 里对应的文件或文件夹，并清理播放进度
    /// 整个目录删除失败时（真机上可能因沙盒扩展属性报 EPERM），退化为逐个删除文件再清空目录
    func delete(book: Book, playingBookId: String? = nil, onStopPlaying: (() -> Void)? = nil) throws {
        NSLog("[sonux] delete: 开始删除《%@》storagePath=%@", book.title, book.storagePath)
        // 若删的正是当前播放的书，先停止播放，避免播放器持有已删除的文件
        if let playingBookId, playingBookId == book.id { onStopPlaying?() }

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

        positions[book.id] = nil
        for chapter in book.chapters { chapterPositions[chapter.id] = nil }
        lastPlayedDates[book.id] = nil
        listening.removeBook(book.id)
        // 直接从内存书库移除并保存；全量 rescan 会阻塞主线程，改为后台异步补扫一次
        books.removeAll { $0.id == book.id }
        saveProgress()
        rescan()
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

    /// 从「文件」App 导入音频文件或文件夹：复制进 Documents 后重新扫描
    /// - 文件夹 → 一本多章节书；单个音频 → 一本单章书
    /// - 返回成功导入的条目数
    @discardableResult
    func importItems(from urls: [URL]) -> Int {
        var imported = 0
        for url in urls {
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            let isAudio = Self.supportedExtensions.contains(url.pathExtension.lowercased())
            guard isDir || isAudio else { continue }

            let dest = uniqueDestination(forName: url.lastPathComponent)
            do {
                if FileManager.default.fileExists(atPath: dest.path) {
                    try FileManager.default.removeItem(at: dest)
                }
                try FileManager.default.copyItem(at: url, to: dest)
                imported += 1
            } catch {
                // 单个条目复制失败则跳过，不影响其余
                continue
            }
        }
        if imported > 0 { rescan() }
        return imported
    }

    /// 生成不与现有文件冲突的目标路径（重名时追加 " (2)" 等后缀）
    private func uniqueDestination(forName name: String) -> URL {
        let direct = documentsDir.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: direct.path) else { return direct }

        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var index = 2
        while true {
            let candidateName = ext.isEmpty ? "\(base) (\(index))" : "\(base) (\(index)).\(ext)"
            let candidate = documentsDir.appendingPathComponent(candidateName)
            if !FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            index += 1
        }
    }

    // MARK: - Private

    nonisolated private static func makeBook(fromFolder folder: URL, documentsDir: URL, cache: [String: AudioFileMeta], fresh: inout [String: AudioFileMeta], misses: inout Int) -> Book? {
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
        let bookId = "dir:\(relativePath(folder, documentsDir: documentsDir))"
        let chapters = audioFiles.enumerated().compactMap { index, file in
            makeChapter(file: file, bookId: bookId, index: index, documentsDir: documentsDir, cache: cache, fresh: &fresh, misses: &misses)
        }
        guard !chapters.isEmpty else { return nil }

        return Book(
            id: bookId,
            title: folder.lastPathComponent,
            author: fresh[relativePath(audioFiles[0], documentsDir: documentsDir)]?.author,
            chapters: chapters,
            storagePath: relativePath(folder, documentsDir: documentsDir)
        )
    }

    nonisolated private static func makeChapter(file: URL, bookId: String, index: Int, documentsDir: URL, cache: [String: AudioFileMeta], fresh: inout [String: AudioFileMeta], misses: inout Int) -> Chapter? {
        let id = relativePath(file, documentsDir: documentsDir)
        let duration = meta(for: file, path: id, cache: cache, fresh: &fresh, misses: &misses).duration
        return Chapter(
            id: id,
            bookId: bookId,
            index: index,
            title: Self.chapterTitle(from: file),
            duration: duration,
            fileURL: file
        )
    }

    nonisolated private static func relativePath(_ url: URL, documentsDir: URL) -> String {
        // 不能用字符串前缀裁剪：真机上 documentsDir.path 带 /private 前缀而目录遍历结果不带，
        // 前缀替换会残留 “private”。先统一规范化，再按路径分量逐段比较裁剪
        let base = Self.normalized(documentsDir).pathComponents
        let parts = Self.normalized(url).pathComponents
        guard parts.count > base.count, Array(parts.prefix(base.count)) == base else {
            return url.path
        }
        return parts.dropFirst(base.count).joined(separator: "/")
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

    nonisolated private static func audioDuration(of url: URL) -> TimeInterval {
        let asset = AVURLAsset(url: url)
        let seconds = CMTimeGetSeconds(asset.duration)
        return seconds.isFinite && seconds > 0 ? seconds : 0
    }

    /// 从音频元数据提取作者（artist / album artist 字段，取第一个非空值）
    nonisolated private static func audioAuthor(of url: URL) -> String? {
        let asset = AVURLAsset(url: url)
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

    /// 持久化结构：书本进度 + 章节进度 + 最后播放时间 + 收听时长统计
    private struct ProgressStore: Codable {
        var books: [String: PlayPosition]
        var chapters: [String: PlayPosition]
        var lastPlayed: [String: Date]?
        var listening: ListeningStats?
    }

    private func saveProgress() {
        let t0 = CACurrentMediaTime()
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        // 进度里存有 Date（最后播放时间）：统一用秒级 epoch，与工具链生成的 JSON 互通
        encoder.dateEncodingStrategy = .secondsSince1970
        let store = ProgressStore(books: positions, chapters: chapterPositions, lastPlayed: lastPlayedDates, listening: listening)
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
