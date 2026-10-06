import Foundation

/// 一本书（对应 File Sharing 目录中的一个文件夹、一个音频文件，或一条指向外部音频的引用）
struct Book: Identifiable, Codable, Equatable {
    let id: String
    var title: String
    var author: String?
    var chapters: [Chapter]
    /// 对应「这本书所在书库根目录」下的相对路径（文件夹或单个音频文件），用于删除等操作
    var storagePath: String
    /// 外部引用的 id：音频原地躺在 iCloud Drive / 「文件」里，只记了个书签；
    /// nil 表示文件就在 App 的 Documents 下（旧数据没这个键，按 nil 解）
    var link: String? = nil

    /// 这本书的音频不在沙盒里，删除只能断开引用，不能动用户磁盘上的文件
    var isLinked: Bool { link != nil }

    /// 全书总时长（秒）
    var totalDuration: TimeInterval {
        chapters.reduce(0) { $0 + $1.duration }
    }

    /// 是否匹配搜索关键词：书名、作者或任一章节标题包含即算命中（忽略大小写）
    func matches(searchText: String) -> Bool {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return true }
        if title.localizedCaseInsensitiveContains(query) { return true }
        if let author, author.localizedCaseInsensitiveContains(query) { return true }
        return chapters.contains { $0.title.localizedCaseInsensitiveContains(query) }
    }
}

/// 一个章节：通常对应一个音频文件；
/// m4b 内嵌章节 TOC 时对应同一文件里的一段（从 fileStart 起、长 duration 秒）
struct Chapter: Identifiable, Codable, Equatable {
    let id: String
    var bookId: String
    var index: Int
    var title: String
    var duration: TimeInterval
    var fileURL: URL
    /// 本章在音频文件时间轴上的起始秒：一个文件一章时恒为 0
    var fileStart: TimeInterval

    init(id: String, bookId: String, index: Int, title: String, duration: TimeInterval,
         fileURL: URL, fileStart: TimeInterval = 0) {
        self.id = id
        self.bookId = bookId
        self.index = index
        self.title = title
        self.duration = duration
        self.fileURL = fileURL
        self.fileStart = fileStart
    }

    /// 本章在文件时间轴上的结束秒（最后一章就是文件结尾）
    var fileEnd: TimeInterval { fileStart + duration }

    /// 文件时间轴的秒 → 本章内的秒（界面与进度都按章内秒记账）
    func localTime(_ fileTime: TimeInterval) -> TimeInterval {
        max(0, fileTime - fileStart)
    }

    /// 本章内的秒 → 文件时间轴的秒
    func fileTime(_ local: TimeInterval) -> TimeInterval {
        fileStart + local
    }

    private enum CodingKeys: String, CodingKey {
        case id, bookId, index, title, duration, fileURL, fileStart
    }

    /// fileStart 是后加的字段：旧数据（含按章节进度 JSON）里没这个键，缺省按 0 处理
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        bookId = try container.decode(String.self, forKey: .bookId)
        index = try container.decode(Int.self, forKey: .index)
        title = try container.decode(String.self, forKey: .title)
        duration = try container.decode(TimeInterval.self, forKey: .duration)
        fileURL = try container.decode(URL.self, forKey: .fileURL)
        fileStart = try container.decodeIfPresent(TimeInterval.self, forKey: .fileStart) ?? 0
    }
}

/// 播放位置：某章节的某秒
struct PlayPosition: Codable, Equatable {
    var chapterId: String
    var time: TimeInterval
}

enum ProgressPolicy {
    /// 误差 3 秒以内视为未开始
    static let epsilon: TimeInterval = 3
    /// 距离结尾 15 秒以内视为已播完
    static let completionThreshold: TimeInterval = 15
    /// 续播回退秒数：停了一会儿再听，人接不上话，起点往回退几秒找语感（Audible 的同款选项）
    static let resumeRewind: TimeInterval = 5

    static func isStarted(_ time: TimeInterval) -> Bool {
        time > epsilon
    }

    static func isFinished(time: TimeInterval, duration: TimeInterval) -> Bool {
        duration > 0 && duration - time <= completionThreshold
    }

    /// 下次播放的起点：播完的章节从头开始，没播完的续播并回退几秒（章头几秒不再退）
    /// rewind: false 用于连续播放中的切章——人没离开，不该被往回拽
    static func resumeTime(time: TimeInterval, duration: TimeInterval, rewind: Bool = true) -> TimeInterval {
        if isFinished(time: time, duration: duration) { return 0 }
        return rewind && time > resumeRewind ? time - resumeRewind : time
    }
}
