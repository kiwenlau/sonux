import Foundation

/// 一本书（对应 File Sharing 目录中的一个文件夹，或单个音频文件）
struct Book: Identifiable, Codable, Equatable {
    let id: String
    var title: String
    var author: String?
    var chapters: [Chapter]

    /// 全书总时长（秒）
    var totalDuration: TimeInterval {
        chapters.reduce(0) { $0 + $1.duration }
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

    static func isStarted(_ time: TimeInterval) -> Bool {
        time > epsilon
    }

    static func isFinished(time: TimeInterval, duration: TimeInterval) -> Bool {
        duration > 0 && duration - time <= completionThreshold
    }

    /// 播完的章节下次从头播放
    static func resumeTime(time: TimeInterval, duration: TimeInterval) -> TimeInterval {
        isFinished(time: time, duration: duration) ? 0 : time
    }
}
