import SwiftUI
import AVFoundation
import CryptoKit

/// 音频封面服务：从音频元数据中提取内嵌封面，内存 + 磁盘双级缓存
/// 提取在后台异步完成，避免 AVAsset 同步读取卡住列表；失败/无封面会记负面标记，不重复尝试
@MainActor
final class CoverStore: ObservableObject {
    static let shared = CoverStore()

    @Published private var images: [String: UIImage] = [:]
    /// 已尝试过提取但无封面（或提取失败）的书 id，避免每次上屏重试
    private var attempted: Set<String> = []

    private nonisolated static let memoryLimit = 60
    private nonisolated static let maxPixel: CGFloat = 400

    private lazy var cacheDir: URL = {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Covers", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    func image(for book: Book) -> UIImage? {
        images[book.id]
    }

    func load(for book: Book) async {
        guard images[book.id] == nil, !attempted.contains(book.id) else { return }

        // 先查磁盘缓存（对已提取过的书是同步开销，无 IO 才落后台）
        let cacheURL = diskURL(for: book.id)
        if FileManager.default.fileExists(atPath: cacheURL.path) {
            if let image = await Self.decode(from: cacheURL) {
                remember(book.id, image: image)
                return
            }
        }

        guard let first = book.chapters.min(by: { $0.index < $1.index }) else {
            attempted.insert(book.id)
            return
        }
        let data = await Self.extractArtwork(from: first.fileURL)
        if let data, let image = await Self.downscale(data) {
            try? data.write(to: cacheURL)   // 缓存原始封面，下次直接读盘
            remember(book.id, image: image)
        } else {
            attempted.insert(book.id)
        }
    }

    /// 书被删除时清理内存标记与磁盘缓存
    func remove(bookId: String) {
        images[bookId] = nil
        attempted.remove(bookId)
        try? FileManager.default.removeItem(at: diskURL(for: bookId))
    }

    private func remember(_ bookId: String, image: UIImage) {
        // 简单容量上限：超出后清掉最早的一半，需要时会自动重新提取
        if images.count >= Self.memoryLimit {
            for key in images.keys.prefix(images.count / 2) { images[key] = nil }
        }
        images[bookId] = image
    }

    private func diskURL(for bookId: String) -> URL {
        let digest = SHA256.hash(data: Data(bookId.utf8))
        let name = digest.map { String(format: "%02x", $0) }.joined()
        return cacheDir.appendingPathComponent(name).appendingPathExtension("jpg")
    }

    // MARK: - 后台提取

    /// 读取音频元数据中的 artwork（封面）数据；AVURLAsset 非 MainActor，放后台线程
    nonisolated private static func extractArtwork(from url: URL) async -> Data? {
        let asset = AVURLAsset(url: url)
        guard let items = try? await asset.load(.commonMetadata) else { return nil }
        for item in items where item.commonKey == .commonKeyArtwork {
            if let data = try? await item.load(.dataValue), data.count > 0 {
                return data
            }
        }
        return nil
    }

    nonisolated private static func decode(from url: URL) async -> UIImage? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return await downscale(data)
    }

    /// 解码并缩到 maxPixel 以内，列表缩略图不需要全尺寸原图
    nonisolated private static func downscale(_ data: Data) async -> UIImage? {
        guard let image = UIImage(data: data) else { return nil }
        let largest = max(image.size.width, image.size.height)
        guard largest > maxPixel else { return image }
        let scale = maxPixel / largest
        let target = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: target, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
    }
}

/// 书库列表的封面缩略图：有内嵌封面显示封面，否则保持原来的图标占位
struct BookCoverView: View {
    let book: Book
    // 单例共享缓存，用 ObservedObject 避免多行各自持有独立副本
    @ObservedObject private var store = CoverStore.shared

    var body: some View {
        // 固定 50×50 封面框：背景色填充，封面 scaledToFit 完整显示不裁切、无内边距
        RoundedRectangle(cornerRadius: 8)
            .fill(Color.gray.opacity(0.1))
            .frame(width: 50, height: 50)
            .overlay {
                if let cover = store.image(for: book) {
                    Image(uiImage: cover)
                        .resizable()
                        .scaledToFit()
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                } else {
                    Image(systemName: book.chapters.count > 1 ? "books.vertical.fill" : "music.note")
                        .foregroundStyle(.indigo)
                }
            }
            .task(id: book.id) {
                await store.load(for: book)
            }
    }
}

/// 书库卡片视图（双列网格用）：大封面 + 标题 + 作者，封面中央一个从上次位置续播的播放按钮
/// 该书正在播放时：封面加靛蓝描边，卡片底色、标题和作者变靛蓝（作者色更浅），不再叠加音柱徽章
struct BookGridCard: View {
    let book: Book
    /// 该书是否为当前播放的书（无论暂停与否）
    let isNowPlaying: Bool
    let onOpen: () -> Void
    let onPlay: () -> Void
    @ObservedObject private var store = CoverStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // 固定比例的封面框：背景色填充，封面 scaledToFit 顶到贴合边、无内边距
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.gray.opacity(0.1))
                if let cover = store.image(for: book) {
                    Image(uiImage: cover)
                        .resizable()
                        .scaledToFit()
                } else {
                    Image(systemName: book.chapters.count > 1 ? "books.vertical.fill" : "music.note")
                        .font(.system(size: 34))
                        .foregroundStyle(.indigo)
                }
            }
            .frame(maxWidth: .infinity)
            .aspectRatio(0.8, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay {
                if isNowPlaying {
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(Color.indigo, lineWidth: 2.5)
                }
            }
            .overlay {
                // 播放按钮居中压在封面上：半透胶囊底保证任何封面都能看清图标
                Button(action: onPlay) {
                    Image(systemName: "play.fill")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.indigo)
                        .frame(width: 46, height: 46)
                        .background(Circle().fill(.ultraThinMaterial))
                        .overlay(Circle().strokeBorder(Color.white.opacity(0.45), lineWidth: 1))
                        .shadow(color: .black.opacity(0.25), radius: 4, y: 1)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("从上次位置播放《\(book.title)》")
                .accessibilityIdentifier("book-card-play-\(book.id)")
            }

            Text(book.title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(isNowPlaying ? Color.indigo : Color.primary)
                .lineLimit(2)

            // 副标题：有作者显作者，否则退而显总时长；正在播放时作者也染浅靛蓝
            Text(book.author ?? TimeFormat.duration(book.totalDuration))
                .font(.subheadline)
                .foregroundStyle(isNowPlaying ? Color.indigo.opacity(0.55) : Color.secondary)
                .lineLimit(1)
        }
        .padding(10)
        .contentShape(Rectangle())
        .onTapGesture(perform: onOpen)
        // 只给「打开详情」的命名操作，不占默认操作，否则封面中央的播放按钮会被父层合并抢走
        .accessibilityAction(named: "打开《\(book.title)》详情") { onOpen() }
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(isNowPlaying ? Color.indigo.opacity(0.1) : Color(.secondarySystemGroupedBackground))
        )
        .task(id: book.id) {
            await store.load(for: book)
        }
    }
}
