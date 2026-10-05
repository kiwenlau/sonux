import Foundation
import UIKit
import WidgetKit

/// 把播放状态推给桌面小组件：写一份快照到 App Group，再请系统刷新时间线。
/// 刷新是有日预算的（系统按天限额，超了就限速），所以只在状态真的变了的时候敲门——
/// 播/停/切章/变速/拖完进度；一秒一秒的前进由小组件拿快照时间戳自己算，不占预算。
@MainActor
enum WidgetSync {
    /// 两次刷新之间的最小间隔：拖进度条时一秒能收到十来次 seek，全发出去预算立刻就没了
    private static let reloadInterval: TimeInterval = 3
    /// 被节流挡下的那一次，稍后补发：否则拖完进度条，小组件会停在拖动途中的旧位置
    private static let trailingDelay: TimeInterval = 1.5

    private static var lastReloadAt = Date.distantPast
    private static var trailingScheduled = false
    /// 已经写过哪一版图：「哪本书 + 用的是内嵌封面还是书名占位图」。
    /// 换书要重写，占位图后来被真封面替掉也要重写——只记书名会让小组件一直拿着旧那张图
    private static var coverStamp: String?

    /// 写进共享目录的封面边长：小组件最大也就一块 170pt 见方，320px 足够清晰，
    /// 再大只是白占共享目录和扩展进程的内存
    private static let coverMaxPixel: CGFloat = 320

    /// 上报一次当前收听状态。封面只在换书或换了一版图（占位图→真封面）时重写（见 coverStamp）
    static func publish(book: Book, chapter: Chapter, chapterIndex: Int,
                        time: TimeInterval, duration: TimeInterval,
                        isPlaying: Bool, speed: Float) {
        let hasArtwork = CoverStore.shared.hasEmbeddedCover(for: book)
        let snapshot = NowPlayingSnapshot(
            bookId: book.id,
            bookTitle: book.title,
            author: book.author,
            chapterTitle: chapter.title,
            chapterIndex: chapterIndex,
            chapterCount: book.chapters.count,
            time: time,
            duration: duration,
            isPlaying: isPlaying,
            speed: Double(speed),
            stampedAt: Date(),
            // 有没有真封面决定小组件是「铺满封面」还是「把占位图糊成底色」，见 NowPlayingSnapshot
            hasArtwork: hasArtwork
        )
        let stamp = "\(book.id):\(hasArtwork ? "artwork" : "placeholder")"
        let cover: Data? = coverStamp == stamp ? nil : coverPNG(for: book)
        guard WidgetBridge.write(snapshot: snapshot, coverPNG: cover) else { return }
        if cover != nil { coverStamp = stamp }
        reloadThrottled()
    }

    /// 挂着没播的那本书被删掉了：清掉快照，小组件回到空状态
    static func clear() {
        WidgetBridge.clear()
        coverStamp = nil
        WidgetCenter.shared.reloadAllTimelines()
    }

    /// 当前这本书的封面：没有内嵌封面时 CoverStore 会画一张书名占位图，小组件因此不会缺图。
    /// 按比例缩到 coverMaxPixel 以内（不放大、不裁成正方，免得封面被拉变形）。
    /// 渲染器要按 1 倍画：默认会跟系统屏幕倍率放大三倍，一张 320px 的图能涨到 1 MB
    private static func coverPNG(for book: Book) -> Data? {
        let cover = CoverStore.shared.lockScreenCover(for: book)
        let size = cover.size
        guard size.width > 0, size.height > 0 else { return nil }
        let scale = min(1, coverMaxPixel / max(size.width, size.height))
        let target = CGSize(width: size.width * scale, height: size.height * scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let scaled = UIGraphicsImageRenderer(size: target, format: format).image { _ in
            cover.draw(in: CGRect(origin: .zero, size: target))
        }
        return scaled.pngData()
    }

    /// 节流刷新：间隔够了立刻发，太密就先记账、稍后补发一次（尾沿合并多次拖动）
    private static func reloadThrottled() {
        let now = Date()
        if now.timeIntervalSince(lastReloadAt) >= reloadInterval {
            lastReloadAt = now
            trailingScheduled = false
            WidgetCenter.shared.reloadAllTimelines()
            return
        }
        guard !trailingScheduled else { return }
        trailingScheduled = true
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(trailingDelay * 1_000_000_000))
            trailingScheduled = false
            lastReloadAt = Date()
            WidgetCenter.shared.reloadAllTimelines()
        }
    }
}
