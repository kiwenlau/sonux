import Foundation
import AVFoundation

/// 书库服务：扫描 File Sharing 目录，把音频文件组织成书，并持久化播放进度
@MainActor
final class LibraryService: ObservableObject {
    @Published private(set) var books: [Book] = []
    /// key: bookId，value: 该书最后播放位置
    @Published private(set) var positions: [String: PlayPosition] = [:]

    static let supportedExtensions: Set<String> = ["mp3", "m4a", "m4b", "aac", "wav", "wave"]

    private let documentsDir: URL
    private let progressURL: URL

    init() {
        documentsDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        progressURL = appSupport.appendingPathComponent("progress.json")
    }

    /// 重新扫描 Documents 目录，生成书库（保留已有进度）
    func rescan() {
        let fm = FileManager.default
        var books: [Book] = []

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
        }

        for entry in topItems {
            let isDir = (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            if isDir {
                if let book = makeBook(fromFolder: entry) {
                    books.append(book)
                }
            } else if Self.supportedExtensions.contains(entry.pathExtension.lowercased()) {
                let bookId = "file:\(relativePath(entry))"
                if let chapter = makeChapter(file: entry, bookId: bookId, index: 0) {
                    books.append(Book(
                        id: bookId,
                        title: entry.deletingPathExtension().lastPathComponent,
                        author: nil,
                        chapters: [chapter]
                    ))
                }
            }
        }

        self.books = books
        // 清理已消失文件的进度
        let aliveBookIds = Set(books.map(\.id))
        positions = positions.filter { aliveBookIds.contains($0.key) }
        saveProgress()
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

    func position(forBook id: String) -> PlayPosition? {
        positions[id]
    }

    func recordPosition(_ position: PlayPosition, bookId: String) {
        positions[bookId] = position
        saveProgress()
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

    private func makeBook(fromFolder folder: URL) -> Book? {
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
        let bookId = "dir:\(relativePath(folder))"
        let chapters = audioFiles.enumerated().compactMap { index, file in
            makeChapter(file: file, bookId: bookId, index: index)
        }
        guard !chapters.isEmpty else { return nil }

        return Book(
            id: bookId,
            title: folder.lastPathComponent,
            author: nil,
            chapters: chapters
        )
    }

    private func makeChapter(file: URL, bookId: String, index: Int) -> Chapter? {
        let id = relativePath(file)
        let duration = Self.audioDuration(of: file)
        return Chapter(
            id: id,
            bookId: bookId,
            index: index,
            title: Self.chapterTitle(from: file),
            duration: duration,
            fileURL: file
        )
    }

    private func relativePath(_ url: URL) -> String {
        url.path.replacingOccurrences(of: documentsDir.path + "/", with: "")
    }

    /// 从文件名提取章节标题：去掉前导序号，如 "01 - 引言.mp3" -> "引言"
    private static func chapterTitle(from url: URL) -> String {
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

    private func saveProgress() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        guard let data = try? encoder.encode(positions) else { return }
        try? data.write(to: progressURL, options: .atomic)
    }

    private func loadProgress() {
        guard let data = try? Data(contentsOf: progressURL) else { return }
        positions = (try? JSONDecoder().decode([String: PlayPosition].self, from: data)) ?? [:]
    }

    /// 启动时先读进度再扫描（在 rescan 前调用）
    func bootstrap() {
        loadProgress()
        rescan()
    }
}
