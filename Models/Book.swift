import Foundation

/// 一本书（对应 File Sharing 目录中的一个文件夹，或单个音频文件）
struct Book: Identifiable, Codable, Equatable {
    let id: String
    var title: String
    var author: String?
    var chapters: [Chapter]
    /// 对应 Documents 下的相对路径（文件夹或单个音频文件），用于删除等操作
    var storagePath: String

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

/// 一个章节（对应一个音频文件）
struct Chapter: Identifiable, Codable, Equatable {
    let id: String
    var bookId: String
    var index: Int
    var title: String
    var duration: TimeInterval
    var fileURL: URL
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
