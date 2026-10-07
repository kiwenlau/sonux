import CoreImage
import SwiftUI
import UIKit

// MARK: - 卡片

/// 卡片上要用的两样封面素材
struct QuoteArtwork {
    /// 立在左上角的小封面（没内嵌封面时是书名占位图，卡片不会空出一块）
    let thumb: UIImage
    /// 糊开铺底的封面；nil 是这本书压根没封面，那就只留主色渐变
    let bleed: UIImage?
}

/// 摘录卡片：一句书里的话 + 出处，画成 3:4 的竖图
///
/// 底色晕的是这本书封面的颜色，缩略图又立在上面，所以一眼认得出是哪本书。
/// 全部颜色都写死（主色 + 白字），一处也不跟随深浅色模式 ——
/// 这张图是要发出去的，不能因为截图的人开着深色模式就变一个样。
struct QuoteCardView: View {
    let quote: Quote
    let palette: CoverPalette
    let artwork: QuoteArtwork

    /// 3:4 是各社交平台通吃的竖版比例；按 3 倍出图就是 1125×1500 px
    static let size = CGSize(width: 375, height: 500)
    /// 全卡统一边距，内容区因此是 315×440
    private static let padding: CGFloat = 30
    /// 缩略图按书库封面的竖版比例 0.8 立着摆
    private static let thumbWidth: CGFloat = 38
    /// 正文字号：实测全库字幕一句中位 16 字、最长 43 字，放到 315 pt 宽里最多 4 行，
    /// 这个字号撑得起主角位置，又不至于让长句缩到看不清
    private static let quoteSize: CGFloat = 27

    var body: some View {
        ZStack {
            backdrop

            VStack(alignment: .leading, spacing: 0) {
                source

                Spacer(minLength: 0)

                Text(quote.text)
                    // 衬线体：拉丁文落 New York，中文系统没有衬线字，回退苹方 ——
                    // 不硬指定宋体，缺字或换系统时不会突然变样
                    .font(.system(size: Self.quoteSize, weight: .medium, design: .serif))
                    .foregroundStyle(.white)
                    .lineSpacing(9)
                    .minimumScaleFactor(0.7)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: 0)

                footer
            }
            .padding(Self.padding)
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .clipShape(RoundedRectangle(cornerRadius: 28))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L("Quote Card"))
        .accessibilityValue(quote.text)
    }

    // MARK: 底

    /// 主色渐变 + 糊开的封面：只要封面的颜色晕染，不要形状（与文案页背景同一套观感）。
    /// 糊化早在出图前用 CoreImage 做完了，这里只摊一张位图 ——
    /// ImageRenderer 画不出 SwiftUI 的模糊层与系统材质，底图必须是普通位图
    private var backdrop: some View {
        ZStack {
            palette.gradient

            if let bleed = artwork.bleed {
                Image(uiImage: bleed)
                    .resizable()
                    .scaledToFill()
                    .opacity(0.5)
            }

            // 压一层纱，白字压在封面上任何一块都读得清
            Color.black.opacity(0.16)
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .clipped()
    }

    // MARK: 出处（顶部）

    /// 封面小图 + 书名 + 作者：卡片身份的来处
    private var source: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(uiImage: artwork.thumb)
                .resizable()
                // scaledToFit 完整显示不裁切，留白处直接透出卡片底色
                .scaledToFit()
                .frame(width: Self.thumbWidth, height: Self.thumbWidth / 0.8)
                .clipShape(RoundedRectangle(cornerRadius: 5))

            VStack(alignment: .leading, spacing: 3) {
                Text(quote.book.title)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .minimumScaleFactor(0.75)

                if let author = quote.author {
                    Text(author)
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(0.7))
                        .lineLimit(1)
                }
            }
            // 长书名把小图挤变形是不行的：文字那一列自己收缩
            .frame(maxWidth: .infinity, alignment: .leading)

            Spacer(minLength: 0)
        }
    }

    // MARK: 脚注（底部）

    /// 一条短线 + 「哪一章 第几秒 · Sonux」：时刻说明这句书里说到哪儿，
    /// 品牌名是这张图唯一的「广告位」
    private var footer: some View {
        VStack(alignment: .leading, spacing: 10) {
            Rectangle()
                .fill(.white.opacity(0.3))
                .frame(width: 26, height: 1)

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(position)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.72))
                    .lineLimit(1)

                Spacer(minLength: 4)

                Text("Sonux")
                    .font(.system(size: 13, weight: .semibold))
                    .kerning(1.2)
                    .foregroundStyle(.white.opacity(0.5))
            }
        }
    }

    /// 「章名 · 12:34」；单章书只剩时刻
    private var position: String {
        quote.showsChapter ? "\(quote.chapterTitle) · \(TimeFormat.time(quote.time))"
                           : TimeFormat.time(quote.time)
    }
}

// MARK: - 出图

/// 把卡片画成一张要分享出去的位图
@MainActor
enum QuoteCardRenderer {
    /// 导出倍率：3x 出 1125×1500 px，是各平台竖图的通用尺寸
    private static let scale: CGFloat = 3
    /// 糊化半径（按封面原始 ~400 px 算，糊到只剩色块就够，再大只是费时间）
    private static let bleedRadius: CGFloat = 24
    private static let context = CIContext()

    /// 出图：先把封面素材备齐再画。从全文搜索里摘一本没打开过的书时，
    /// 这本书的封面与主色可能还没提取过，load 会去补（有缓存，通常只是读一下盘）
    static func render(_ quote: Quote) async -> UIImage? {
        let covers = CoverStore.shared
        await covers.load(for: quote.book)
        let palette = covers.palette(for: quote.book) ?? .fallback
        let artwork = QuoteArtwork(
            thumb: covers.lockScreenCover(for: quote.book),
            bleed: (covers.largeImage(for: quote.book) ?? covers.image(for: quote.book))
                .flatMap(bleed(from:))
        )
        return image(of: quote, palette: palette, artwork: artwork)
    }

    private static func image(of quote: Quote, palette: CoverPalette, artwork: QuoteArtwork) -> UIImage? {
        let renderer = ImageRenderer(content: QuoteCardView(quote: quote, palette: palette, artwork: artwork))
        renderer.scale = scale
        renderer.proposedSize = ProposedViewSize(QuoteCardView.size)
        return renderer.uiImage
    }

    /// 把封面糊成一团颜色：只留色相晕染，不留形状
    static func bleed(from cover: UIImage) -> UIImage? {
        guard let base = CIImage(image: cover) else { return nil }
        // 先 clamp 到无限边缘再糊：不然图片四周会糊进一圈透明白边，看着像压了层雾
        let blurred = base.applyingFilter("CIAffineClamp")
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: Self.bleedRadius])
            .cropped(to: base.extent)
        guard let cg = Self.context.createCGImage(blurred, from: base.extent) else { return nil }
        return UIImage(cgImage: cg)
    }
}

// MARK: - 卡片层

/// 卡片层：暗底上摆出这张卡片，下面一个分享按钮（系统分享面板里就有「存储图像」）
///
/// 显示的就是将要分享出去的那张位图，所见即所得，而不是「屏上看着好看、发出去糊了」
struct QuoteSheet: View {
    let quote: Quote

    @Environment(\.dismiss) private var dismiss
    @State private var image: UIImage?
    /// 出图跑完了一趟仍没有图（极小概率）：别再转圈，至少把那句话摆出来
    @State private var rendered = false

    var body: some View {
        VStack(spacing: 22) {
            Spacer(minLength: 0)
            card
            if let image { shareButton(image) }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 24)
        .overlay(alignment: .topTrailing) {
            CircleGlyphButton(glyph: "xmark", action: { dismiss() })
                .padding(.top, 14)
                .padding(.trailing, 20)
        }
        .task(id: quote.id) {
            image = await QuoteCardRenderer.render(quote)
            rendered = true
        }
        // 标识只打在里面的卡片图与分享按钮上：整块容器再打一个会把子元素的
        // identifier 全盖掉（AX 树里问出来的都是容器那个名，调试时点不中）
    }

    @ViewBuilder
    private var card: some View {
        if let image {
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: QuoteCardView.size.width, maxHeight: QuoteCardView.size.height)
                .clipShape(RoundedRectangle(cornerRadius: 28))
                .shadow(color: .black.opacity(0.45), radius: 18, y: 8)
                .accessibilityIdentifier("quote-card")
        } else if rendered {
            // 出不了图也得让用户看得见摘的是哪句，别给一堵空墙
            Text(quote.text)
                .font(.system(size: 21, weight: .medium, design: .serif))
                .foregroundStyle(.white)
                .lineSpacing(8)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            ProgressView()
                .tint(.white)
                .frame(maxWidth: .infinity, minHeight: 220)
        }
    }

    /// 分享：整条都是按钮底，文字与图标同色，不跟系统默认的蓝色胶囊样式打架
    private func shareButton(_ image: UIImage) -> some View {
        ShareLink(item: Image(uiImage: image),
                  preview: SharePreview(quote.book.title, image: Image(uiImage: image))) {
            Label(L("Share"), systemImage: "square.and.arrow.up")
                .font(.subheadline.weight(.medium))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(Capsule().fill(.white.opacity(0.18)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
        .accessibilityIdentifier("quote-share")
    }
}

// MARK: - 入口

extension View {
    /// 长按某句出「摘录卡片」菜单。两处入口共用：播放页正在读的那句、全文搜索的命中句
    ///
    /// 整章文案页不在其中：那一页是 ScrollView + LazyVStack，contextMenu 在这个结构里
    /// 弹不出来（实测长按任何一句都没菜单，连无障碍的 AXShowMenu 也弹不出），
    /// 那一页改在标题栏放一枚看得见的摘录按钮
    ///
    /// quote 传 nil 表示这句摘不出来（比如还没开口、书没字幕），那就干脆不挂菜单，
    /// 而不是挂个点了没反应的菜单项
    func quoteMenu(_ quote: Quote?, _ onPick: @escaping (Quote) -> Void) -> some View {
        modifier(QuoteMenuModifier(quote: quote, onPick: onPick))
    }

    /// 卡片层：挂在宿主视图较高处一份就够，接住 quoteMenu 挑中的那句
    func quoteCardSheet(_ selection: Binding<Quote?>) -> some View {
        sheet(item: selection) { quote in
            QuoteSheet(quote: quote)
                .presentationDetents([.large])
                // 暗底让卡片成为唯一主角，也和播放页那一屏深色一脉相承
                .presentationBackground(Color.playerSheetBackground)
                .presentationDragIndicator(.hidden)
        }
    }
}

private struct QuoteMenuModifier: ViewModifier {
    let quote: Quote?
    let onPick: (Quote) -> Void

    @ViewBuilder
    func body(content: Content) -> some View {
        if let quote {
            content.contextMenu {
                Button { onPick(quote) } label: {
                    Label(L("Quote Card"), systemImage: "text.quote")
                }
            }
        } else {
            content
        }
    }
}
