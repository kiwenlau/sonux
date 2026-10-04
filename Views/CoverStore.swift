import SwiftUI
import AVFoundation
import CryptoKit
import UIKit

/// 播放页背景色板：由封面主色推导，整屏同一色相，自上而下缓慢沉下去
struct CoverPalette {
    let top: Color
    let middle: Color
    let lower: Color
    let bottom: Color

    /// 铺满全屏的沉浸渐变（含状态栏后面），色相全程一致，只明暗过渡
    var gradient: LinearGradient {
        LinearGradient(
            stops: [
                .init(color: top, location: 0),
                .init(color: middle, location: 0.30),
                .init(color: lower, location: 0.66),
                .init(color: bottom, location: 1),
            ],
            startPoint: .top, endPoint: .bottom
        )
    }

    /// 从封面提取主色：先缩到 32×32 取样，按色相分 36 箱累加权重（饱和度越高权重越大，
    /// 接近纯黑纯白的像素权重压到很低，避免白底封面把背景洗成一片灰），取权重最高的箱求均值；
    /// 再把饱和度压到 Apple Music 那种“莫兰迪”区间、亮度限定在中偏暗，保证白字可读
    nonisolated static func make(from image: UIImage) -> CoverPalette? {
        guard let sampled = SampledPixels(image: image) else { return nil }
        guard let (hue, saturation, brightness) = sampled.dominantHSB() else { return nil }

        let sat = min(max(saturation, 0.18), 0.45)
        let bri = min(max(brightness, 0.30), 0.55)
        return CoverPalette(
            top: Color(hue: hue, saturation: sat * 0.9, brightness: min(bri * 1.15, 0.62)),
            middle: Color(hue: hue, saturation: sat, brightness: bri),
            lower: Color(hue: hue, saturation: sat * 1.05, brightness: bri * 0.70),
            bottom: Color(hue: hue, saturation: sat * 1.15, brightness: bri * 0.38)
        )
    }
}

/// 音频封面服务：从音频元数据中提取内嵌封面，内存 + 磁盘双级缓存
/// 提取在后台异步完成，避免 AVAsset 同步读取卡住列表；失败/无封面会记负面标记，不重复尝试
@MainActor
final class CoverStore: ObservableObject {
    static let shared = CoverStore()

    @Published private var images: [String: UIImage] = [:]
    /// 播放页大图：列表缩略图只有 400px，放大显示会糊，单独缓存一份更大的
    @Published private var largeImages: [String: UIImage] = [:]
    /// 封面主色板，播放页背景用
    @Published private var palettes: [String: CoverPalette] = [:]
    /// 无内嵌封面时生成的书名占位图，避免每次上锁屏都重画
    private var placeholders: [String: UIImage] = [:]
    /// 已尝试过提取但无封面（或提取失败）的书 id，避免每次上屏重试
    private var attempted: Set<String> = []
    private var attemptedLarge: Set<String> = []

    private nonisolated static let memoryLimit = 60
    private nonisolated static let maxPixel: CGFloat = 400
    private nonisolated static let largeMaxPixel: CGFloat = 900

    private lazy var cacheDir: URL = {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Covers", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    func image(for book: Book) -> UIImage? {
        images[book.id]
    }

    func largeImage(for book: Book) -> UIImage? {
        largeImages[book.id]
    }

    func palette(for book: Book) -> CoverPalette? {
        palettes[book.id]
    }

    /// 大图封面提取是否已有结论（取到了，或确认无封面/失败），用于避免反复调度提取
    func largeCoverResolved(for book: Book) -> Bool {
        largeImages[book.id] != nil || attemptedLarge.contains(book.id)
    }

    /// 是否已取到音频内嵌封面（大图优先）
    func hasEmbeddedCover(for book: Book) -> Bool {
        largeImages[book.id] != nil || images[book.id] != nil
    }

    /// 锁屏/控制中心封面：有内嵌封面用大图，没有则画一张书名占位封面，保证锁屏不留白
    func lockScreenCover(for book: Book) -> UIImage {
        if let cover = largeImages[book.id] ?? images[book.id] { return cover }
        if let placeholder = placeholders[book.id] { return placeholder }
        let placeholder = Self.placeholderCover(title: book.title, author: book.author)
        placeholders[book.id] = placeholder
        return placeholder
    }

    func load(for book: Book) async {
        guard images[book.id] == nil, !attempted.contains(book.id) else { return }
        guard let data = await rawData(for: book),
              let image = await Self.downscale(data, maxPixel: Self.maxPixel) else {
            attempted.insert(book.id)
            return
        }
        remember(book.id, image: image)
        fillPalette(book.id, from: image)
    }

    /// 播放页大图（顺带保证主色板存在，直接从列表进播放页时也不用等缩略图）
    func loadLarge(for book: Book) async {
        await load(for: book)
        guard largeImages[book.id] == nil, !attemptedLarge.contains(book.id) else { return }
        guard let data = await rawData(for: book),
              let image = await Self.downscale(data, maxPixel: Self.largeMaxPixel) else {
            attemptedLarge.insert(book.id)
            return
        }
        if largeImages.count >= Self.memoryLimit {
            for key in largeImages.keys.prefix(largeImages.count / 2) { largeImages[key] = nil }
        }
        largeImages[book.id] = image
        fillPalette(book.id, from: image)
    }

    /// 书被删除时清理内存标记与磁盘缓存
    func remove(bookId: String) {
        images[bookId] = nil
        largeImages[bookId] = nil
        palettes[bookId] = nil
        placeholders[bookId] = nil
        attempted.remove(bookId)
        attemptedLarge.remove(bookId)
        try? FileManager.default.removeItem(at: diskURL(for: bookId))
    }

    private func fillPalette(_ bookId: String, from image: UIImage) {
        guard palettes[bookId] == nil else { return }
        palettes[bookId] = Self.palette(from: image)
    }

    /// 原始封面数据：磁盘缓存优先，缺失时从第一章音频元数据提取后落盘
    private func rawData(for book: Book) async -> Data? {
        let cacheURL = diskURL(for: book.id)
        if let cached = await Self.readDisk(cacheURL) { return cached }
        guard let first = book.chapters.min(by: { $0.index < $1.index }) else { return nil }
        guard let data = await Self.extractArtwork(from: first.fileURL), !data.isEmpty else { return nil }
        await Self.writeDisk(data, to: cacheURL)   // 缓存原始封面，各级尺寸都直接读盘
        return data
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

    nonisolated private static func readDisk(_ url: URL) async -> Data? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try? Data(contentsOf: url)
    }

    nonisolated private static func writeDisk(_ data: Data, to url: URL) async {
        try? data.write(to: url)
    }

    /// 解码并缩到 maxPixel 以内，列表缩略图不需要全尺寸原图
    nonisolated private static func downscale(_ data: Data, maxPixel: CGFloat) async -> UIImage? {
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

    /// 主色板：取封面像素算 HSB，纯计算开销小，直接在调用线程做
    nonisolated private static func palette(from image: UIImage) -> CoverPalette? {
        CoverPalette.make(from: image)
    }

    /// 无内嵌封面时的占位封面：按书库封面比例 0.8 画一张靛蓝底书名卡
    nonisolated private static func placeholderCover(title: String, author: String?) -> UIImage {
        let size = CGSize(width: 640, height: 800)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            let bounds = CGRect(origin: .zero, size: size)
            let gradient = CGGradient(
                colorsSpace: CGColorSpaceCreateDeviceRGB(),
                colors: [
                    UIColor(red: 0.30, green: 0.30, blue: 0.62, alpha: 1).cgColor,
                    UIColor(red: 0.16, green: 0.16, blue: 0.36, alpha: 1).cgColor,
                ] as CFArray,
                locations: [0, 1]
            )
            if let gradient {
                ctx.cgContext.drawLinearGradient(
                    gradient,
                    start: bounds.origin,
                    end: CGPoint(x: bounds.maxX, y: bounds.maxY),
                    options: []
                )
            }

            let textWidth = bounds.width - 96
            let titleAttributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 44, weight: .bold),
                .foregroundColor: UIColor.white,
                .paragraphStyle: {
                    let style = NSMutableParagraphStyle()
                    style.alignment = .center
                    style.lineBreakMode = .byTruncatingTail
                    return style
                }(),
            ]
            let titleText = title as NSString
            let titleRect = titleText.boundingRect(
                with: CGSize(width: textWidth, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin],
                attributes: titleAttributes,
                context: nil
            )
            let titleY = (bounds.height - titleRect.height) / 2
            titleText.draw(
                in: CGRect(x: 48, y: titleY, width: textWidth, height: titleRect.height),
                withAttributes: titleAttributes
            )

            guard let author, !author.isEmpty else { return }
            let authorStyle = NSMutableParagraphStyle()
            authorStyle.alignment = .center
            (author as NSString).draw(
                in: CGRect(x: 48, y: titleY + titleRect.height + 36, width: textWidth, height: 60),
                withAttributes: [
                    .font: UIFont.systemFont(ofSize: 28, weight: .medium),
                    .foregroundColor: UIColor.white.withAlphaComponent(0.7),
                    .paragraphStyle: authorStyle,
                ]
            )
        }
    }
}

/// 把封面缩成 32×32 像素缓冲，供提取主色用（非 MainActor，可在后台跑）
private struct SampledPixels {
    static let side = 32
    let rgb: [Double]

    init?(image: UIImage) {
        guard let cg = image.cgImage else { return nil }
        let count = Self.side * Self.side
        var buffer = [UInt8](repeating: 0, count: count * 4)
        guard let context = CGContext(
            data: &buffer,
            width: Self.side, height: Self.side,
            bitsPerComponent: 8, bytesPerRow: Self.side * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.interpolationQuality = .medium
        context.draw(cg, in: CGRect(x: 0, y: 0, width: Self.side, height: Self.side))
        rgb = buffer.prefix(count * 4).map { Double($0) / 255 }
    }

    /// 按色相分箱累加权重，返回权重最高箱的平均色（HSB，hue 为 0...1）
    func dominantHSB() -> (Double, Double, Double)? {
        let binCount = 36
        var weights = [Double](repeating: 0, count: binCount)
        var sumR = [Double](repeating: 0, count: binCount)
        var sumG = [Double](repeating: 0, count: binCount)
        var sumB = [Double](repeating: 0, count: binCount)

        for i in 0..<Self.side * Self.side {
            let r = rgb[i * 4], g = rgb[i * 4 + 1], b = rgb[i * 4 + 2]
            let maxC = max(r, g, b), minC = min(r, g, b)
            let brightness = maxC
            let delta = maxC - minC
            let saturation = maxC == 0 ? 0 : delta / maxC
            var hue = 0.0
            if delta > 0 {
                let segment: Double
                if maxC == r { segment = (g - b) / delta } else if maxC == g { segment = 2 + (b - r) / delta } else { segment = 4 + (r - g) / delta }
                hue = (segment / 6).truncatingRemainder(dividingBy: 1)
                if hue < 0 { hue += 1 }
            }
            // 白底、黑底、灰底像素不带主色信息，只留极小权重兜底（应对纯灰封面）
            let neutralPenalty = (brightness < 0.12 || brightness > 0.94) ? 0.05 : 1
            let weight = (0.03 + saturation * saturation) * neutralPenalty
            let bin = min(binCount - 1, Int(hue * Double(binCount)))
            weights[bin] += weight
            sumR[bin] += r * weight
            sumG[bin] += g * weight
            sumB[bin] += b * weight
        }

        guard let best = weights.indices.max(by: { weights[$0] < weights[$1] }), weights[best] > 0 else { return nil }
        let w = weights[best]
        return Self.hsb(red: sumR[best] / w, green: sumG[best] / w, blue: sumB[best] / w)
    }

    private static func hsb(red: Double, green: Double, blue: Double) -> (Double, Double, Double) {
        let maxC = max(red, green, blue), minC = min(red, green, blue)
        let delta = maxC - minC
        var hue = 0.0
        if delta > 0 {
            let segment: Double
            if maxC == red { segment = (green - blue) / delta } else if maxC == green { segment = 2 + (blue - red) / delta } else { segment = 4 + (red - green) / delta }
            hue = (segment / 6).truncatingRemainder(dividingBy: 1)
            if hue < 0 { hue += 1 }
        }
        let saturation = maxC == 0 ? 0 : delta / maxC
        return (hue, saturation, maxC)
    }
}

/// 书库列表的封面缩略图：有内嵌封面显示封面，否则保持原来的图标占位
struct BookCoverView: View {
    let book: Book
    /// 封面框边长：底部迷你播放器用更小的一号
    var size: CGFloat = 50
    /// 背景填充色：传 nil 表示不铺底色，空余处直接露出所在容器的背景
    /// 默认铺白（卡片同款底色）：封面比例与封面框不一致时，留白处不能是灰块
    var background: Color? = Color(.secondarySystemGroupedBackground)
    // 单例共享缓存，用 ObservedObject 避免多行各自持有独立副本
    @ObservedObject private var store = CoverStore.shared

    var body: some View {
        // 固定尺寸封面框：可选背景色填充，封面 scaledToFit 完整显示不裁切、无内边距
        RoundedRectangle(cornerRadius: 8)
            .fill(background ?? Color.clear)
            .frame(width: size, height: size)
            .overlay {
                if let cover = store.image(for: book) {
                    Image(uiImage: cover)
                        .resizable()
                        .scaledToFit()
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                } else {
                    Image(systemName: book.chapters.count > 1 ? "books.vertical.fill" : "music.note")
                        .font(.system(size: size * 0.34))
                        .foregroundStyle(.indigo)
                }
            }
            .task(id: book.id) {
                await store.load(for: book)
            }
    }
}

/// 整卡按下反馈：卡片做成真 Button 才有按下高亮（.plain 样式按下毫无变化，
/// 用户会以为「点了没反应」）。只做明暗不做缩放，免得与同层的播放键对不齐
struct PressableCardStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.55 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
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
        // 整卡「打开详情」与封面中央的播放键是平级兄弟：外层 Button 套内层 Button 时，
        // 按下会被外层抢走（实测点播放键反而进了详情页），所以播放键不能放进整卡按钮的 label 里
        ZStack(alignment: .top) {
            Button(action: onOpen) {
                cardBody
                    .padding(10)
            }
            .buttonStyle(PressableCardStyle())

            // 与封面同宽同比例的透明垫块，把播放键钉在封面正中；垫块自己不参与点击
            Color.clear
                .frame(maxWidth: .infinity)
                .aspectRatio(0.8, contentMode: .fit)
                .allowsHitTesting(false)
                .overlay { playButton }
                .padding(10)
        }
        .background(cardBackground)
        .task(id: book.id) {
            await store.load(for: book)
        }
    }

    private var cardBody: some View {
        VStack(alignment: .leading, spacing: 8) {
            // 固定比例的封面框：铺白底（与卡片同色），封面 scaledToFit 顶到贴合边、无内边距
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color(.secondarySystemGroupedBackground))
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
    }

    /// 播放按钮居中压在封面上：半透胶囊底保证任何封面都能看清图标
    private var playButton: some View {
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
        .accessibilityLabel(LF("Play \"%@\" from Where You Left Off", book.title))
        .accessibilityIdentifier("book-card-play-\(book.id)")
    }

    /// 卡片底色是纯白（浅色模式下 secondarySystemGroupedBackground 即 #FFFFFF），
    /// 浮在分组灰页面上；正在播放时在白底上再叠一层浅靛蓝，不透出页底灰
    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 14)
            .fill(Color(.secondarySystemGroupedBackground))
            .overlay {
                if isNowPlaying {
                    RoundedRectangle(cornerRadius: 14).fill(Color.indigo.opacity(0.1))
                }
            }
    }
}
