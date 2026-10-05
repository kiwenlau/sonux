import Foundation
import ImageIO
import UIKit

/// App 与桌面小组件之间的桥。
/// 小组件跑在另一个进程里，读不到 App 自己的沙盒，双方只能靠 App Group 这块共享目录传话：
/// App 把「此刻在听什么」写成一份快照 JSON（外加一张封面），小组件读出来画。
enum WidgetBridge {
    /// App Group 标识：两个 target 的 entitlements 里必须一字不差地相同
    static let groupIdentifier = "group.com.kiwenlau.sonux"

    /// 共享容器根目录。没配好 App Group（例如描述文件里没这个组）时是 nil，
    /// 调用方一律静默跳过——小组件收不到数据，但不该因此拖垮播放
    static var containerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupIdentifier)
    }

    private static var snapshotURL: URL? { containerURL?.appendingPathComponent("now-playing.json") }
    private static var coverURL: URL? { containerURL?.appendingPathComponent("now-playing.png") }
    private static var didWarnNoContainer = false

    /// 落盘一份快照，顺带封面（传 nil 表示封面没换，不重写）。
    /// 必须原子写：小组件随时可能来读，不能让它读到半份 JSON 或半张图
    @discardableResult
    static func write(snapshot: NowPlayingSnapshot, coverPNG: Data?) -> Bool {
        guard let snapshotURL, let coverURL else {
            if !didWarnNoContainer {
                didWarnNoContainer = true
                NSLog("[sonux] widget: 拿不到 App Group 容器 %@，小组件收不到收听状态", groupIdentifier)
            }
            return false
        }
        if let coverPNG {
            do { try coverPNG.write(to: coverURL, options: .atomic) }
            catch { NSLog("[sonux] widget: 写封面失败 %@", error.localizedDescription) }
        }
        do {
            try JSONEncoder().encode(snapshot).write(to: snapshotURL, options: .atomic)
            return true
        } catch {
            NSLog("[sonux] widget: 写快照失败 %@", error.localizedDescription)
            return false
        }
    }

    /// 读快照；没有快照或解不出来（格式换代、文件被清）都返回 nil，小组件画空状态
    static func readSnapshot() -> NowPlayingSnapshot? {
        guard let url = snapshotURL, let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(NowPlayingSnapshot.self, from: data)
    }

    /// 读封面：按需要的边长生成缩略图，别把 App 那份 900px 大图整搬进扩展进程
    static func readCover(maxPixel: CGFloat) -> UIImage? {
        guard let url = coverURL else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return UIImage(cgImage: image)
    }

    /// 撤掉快照（挂着没播的那本书被删了）：只删 JSON，封面留着不碍事
    static func clear() {
        guard let url = snapshotURL else { return }
        try? FileManager.default.removeItem(at: url)
    }
}

/// 「正在收听」的一份快照：App 写、小组件读。
/// 解码时每个字段都给了缺省值，为的是将来加字段时旧快照不至于整份解不出来
/// （整份解不出来 = 小组件凭空变空），而不是只丢那一个新字段。
struct NowPlayingSnapshot: Codable, Equatable {
    /// 书的 id：小组件用它判断封面是不是该换
    var bookId: String
    var bookTitle: String
    var author: String?
    var chapterTitle: String
    /// 本章是全书第几章、一共几章（1 起算），小组件上画成「7/20」这种数字对照
    var chapterIndex: Int
    var chapterCount: Int
    /// 本章内的秒数与本章时长（与 App 里进度条同一套记账口径）
    var time: TimeInterval
    var duration: TimeInterval
    var isPlaying: Bool
    /// 倍速：外推进度时按它换算，1.5 倍速听一分钟等于走了一分半
    var speed: Double
    /// 这份快照是哪一刻拍的：小组件拿它对表推算现在走到哪
    var stampedAt: Date
    /// 封面是音频自带的还是按书名画的占位图：占位图上已经写着书名，
    /// 小组件再叠一层书名就成了两行重复，所以这时要把底图糊开只留颜色
    var hasArtwork: Bool

    init(bookId: String, bookTitle: String, author: String?, chapterTitle: String,
         chapterIndex: Int, chapterCount: Int, time: TimeInterval, duration: TimeInterval,
         isPlaying: Bool, speed: Double, stampedAt: Date, hasArtwork: Bool = false) {
        self.bookId = bookId
        self.bookTitle = bookTitle
        self.author = author
        self.chapterTitle = chapterTitle
        self.chapterIndex = chapterIndex
        self.chapterCount = chapterCount
        self.time = time
        self.duration = duration
        self.isPlaying = isPlaying
        self.speed = speed
        self.stampedAt = stampedAt
        self.hasArtwork = hasArtwork
    }

    private enum CodingKeys: String, CodingKey {
        case bookId, bookTitle, author, chapterTitle, chapterIndex, chapterCount
        case time, duration, isPlaying, speed, stampedAt, hasArtwork
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        bookId = try container.decodeIfPresent(String.self, forKey: .bookId) ?? ""
        bookTitle = try container.decodeIfPresent(String.self, forKey: .bookTitle) ?? ""
        author = try container.decodeIfPresent(String.self, forKey: .author)
        chapterTitle = try container.decodeIfPresent(String.self, forKey: .chapterTitle) ?? ""
        chapterIndex = try container.decodeIfPresent(Int.self, forKey: .chapterIndex) ?? 1
        chapterCount = try container.decodeIfPresent(Int.self, forKey: .chapterCount) ?? 1
        time = try container.decodeIfPresent(TimeInterval.self, forKey: .time) ?? 0
        duration = try container.decodeIfPresent(TimeInterval.self, forKey: .duration) ?? 0
        isPlaying = try container.decodeIfPresent(Bool.self, forKey: .isPlaying) ?? false
        speed = try container.decodeIfPresent(Double.self, forKey: .speed) ?? 1
        stampedAt = try container.decodeIfPresent(Date.self, forKey: .stampedAt) ?? Date()
        hasArtwork = try container.decodeIfPresent(Bool.self, forKey: .hasArtwork) ?? false
    }

    /// 快照之后又播到的位置：还在播就按墙钟时间往外推，推满本章就封顶
    /// （本章确实播完了）；暂停着则原样返回，不跟着时间走
    func time(at date: Date) -> TimeInterval {
        let base = min(max(time, 0), max(duration, 0))
        guard isPlaying, date > stampedAt, duration > base else { return base }
        let wallPlayed = date.timeIntervalSince(stampedAt) * max(speed, 0.1)
        return base + min(wallPlayed, duration - base)
    }

    /// 本章进度 0...1
    func progress(at date: Date) -> Double {
        guard duration > 0 else { return 0 }
        return min(max(time(at: date) / duration, 0), 1)
    }

    /// 小组件在组件画廊里的占位数据：拿一段真实感的排版演示样式
    static let sample = NowPlayingSnapshot(
        bookId: "sample",
        bookTitle: "百年孤独",
        author: "加西亚·马尔克斯",
        chapterTitle: "第七章",
        chapterIndex: 7,
        chapterCount: 20,
        time: 612,
        duration: 2043,
        isPlaying: true,
        speed: 1,
        stampedAt: Date()
    )
}
