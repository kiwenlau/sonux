import SwiftUI

struct PlayerView: View {
    @EnvironmentObject private var player: PlayerService
    @EnvironmentObject private var routers: TabRouters
    // 单例共享封面缓存，播放页大图与主色都由它提供
    @ObservedObject private var covers = CoverStore.shared
    // 字幕（正在朗读的那一句）按书读盘，也只留当前这本
    @ObservedObject private var transcripts = TranscriptStore.shared

    /// 点作者名关播放页后压进当前 tab 的导航栈（历史 tab 打开的就回落到历史栈）
    private var router: AppRouter { routers.active }
    @State private var showingSleepSheet = false
    @State private var showingSpeedSheet = false
    @State private var showingChaptersSheet = false
    /// 整章文案页（点字幕拉开，盖在播放页上）
    @State private var showingTranscript = false
    /// 摘出来要出卡片的那句：长按字幕、文案页右上角的摘录按钮都写到这里（卡片层只有一份）
    @State private var quoted: Quote?
    @State private var scrubTime: TimeInterval?

    /// 竖版封面在没有真实封面时的占位比例
    private static let placeholderRatio: CGFloat = 0.8

    /// 进度条两侧快退/快进的步长（秒），与锁屏的跳过区间一致
    private static let skipSeconds: TimeInterval = 15
    /// 快进快退按钮的点击框边长与到轨道的间距；时间行按同样宽度内缩，与轨道两端对齐
    private static let skipButtonSide: CGFloat = 34
    private static let skipToTrackGap: CGFloat = 8

    // 间距一律取自 8 的倍数刻度，全页节奏统一；
    // 松紧也表达分组关系：同一功能组内部间距小，组与组之间间距大；
    // 封面与播放组之间取 32：封面阴影向下扩散约 24pt，必须留出净距才不会压到章节名
    static let gapHeaderToText: CGFloat = 16
    static let gapCoverToChapter: CGFloat = 32
    static let gapChapterToCaption: CGFloat = 8
    static let gapChapterToProgress: CGFloat = 16
    static let gapCaptionToProgress: CGFloat = 12
    static let gapProgressToControls: CGFloat = 24

    /// 字幕区固定按两行留高：单行也占同样位置，进度条与控制排才不会随文案长短抽动
    /// 字号比章节名的 .subheadline（15pt）小一档，留高按 .footnote（13pt）的两行算
    static let captionHeight: CGFloat = 36

    /// 封面宽度硬上限：大屏上多余空间交给上下空隙，不把封面无限放大
    private static let coverMaxWidth: CGFloat = 340

    private var book: Book? { player.currentBook }

    /// 没提取到封面时的兜底背景（紫色系，与摘录卡片共用同一份色板）
    private var palette: CoverPalette {
        guard let book, let palette = covers.palette(for: book) else { return CoverPalette.fallback }
        return palette
    }

    /// 播放页用大图，未加载完退回列表缩略图，避免先糊后清的跳变
    private var artworkImage: UIImage? {
        guard let book else { return nil }
        return covers.largeImage(for: book) ?? covers.image(for: book)
    }

    /// 封面框跟随封面自身比例，保证 scaledToFit 顶边贴合、不留内边距
    private var artworkRatio: CGFloat {
        guard let cover = artworkImage else { return Self.placeholderRatio }
        let size = cover.size
        guard size.height > 0 else { return Self.placeholderRatio }
        let ratio = size.width / size.height
        return min(max(ratio, 0.5), 1.6)
    }

    /// 收起全屏播放页（下滑手势/左上角按钮共用）
    private func closePlayer() {
        showingTranscript = false
        withAnimation(.spring(response: 0.38, dampingFraction: 0.86)) {
            player.showPlayer = false
        }
    }

    /// 点字幕拉开整章文案页（学 QQ 音乐：歌词页就从歌词那一行拉出来）
    private func openTranscript() {
        withAnimation(.spring(response: 0.42, dampingFraction: 0.9)) {
            showingTranscript = true
        }
    }

    /// 收起文案页：只盖回播放页，动画与打开时对称
    private func collapseTranscript() {
        withAnimation(.spring(response: 0.42, dampingFraction: 0.9)) {
            showingTranscript = false
        }
    }

    /// 从播放页跳作者页：先收起全屏播放页，露出下面的书库栈再入栈（与书库行为一致）
    private func openAuthor(_ author: String) {
        NSLog("[sonux] ui: 播放页点击作者「%@」", author)
        closePlayer()
        router.openAuthor(author)
    }

    var body: some View {
        ZStack {
            playerPage

            // 文案页盖在播放页之上：两层各管各的下滑关闭，拖文案不会把播放页一起带走
            if showingTranscript, let book, let chapter = player.currentChapter,
               transcripts.hasTranscript(for: chapter.id) {
                TranscriptView(book: book, chapter: chapter, palette: palette, cover: artworkImage,
                               onCollapse: collapseTranscript, onQuote: { quoted = $0 })
                    .transition(.move(edge: .bottom))
                    .zIndex(1)
            }
        }
        // 长按字幕、点文案页摘录按钮挑中的那句，都在这里出卡片
        .quoteCardSheet($quoted)
    }

    /// 全屏播放页本体：三段式构图 + 下滑关闭 + 三个弹层
    private var playerPage: some View {
        ZStack {
            // 主色渐变铺满整页，包括状态栏后面，避免顶部出现突兀的边界
            palette.gradient
                .ignoresSafeArea()

            // 三段式构图：顶部身份信息、封面主体、底部播放组。
            // 每块高度都由 Layout 实测，封面只拿实测后的剩余空间，
            // 多余空间按 2:3 分到封面上下两侧，任何机型都不会重叠或溢出
            PlayerLayout(coverIndex: 2, ratio: artworkRatio, coverMaxWidth: Self.coverMaxWidth) {
                header

                // 书名、作者贴顶
                metadata
                    .padding(.top, Self.gapHeaderToText)

                artwork

                playbackGroup
            }
            .padding(.horizontal, 24)
        }
        // 换书时背景主色平滑过渡，而不是整页颜色突变
        .animation(.easeInOut(duration: 0.5), value: book?.id ?? "")
        // 下滑关闭（进度条等控件自己消费手势，不受影响）
        .gesture(
            DragGesture()
                .onEnded { value in
                    if value.translation.height > 100 || value.predictedEndTranslation.height > 250 {
                        closePlayer()
                    }
                }
        )
        .preferredColorScheme(.dark)
        .task(id: book?.id) {
            guard let book else { return }
            await transcripts.load(book: book)
            await covers.loadLarge(for: book)
        }
        .sheet(isPresented: $showingSleepSheet) {
            SleepTimerSheet()
        }
        .sheet(isPresented: $showingSpeedSheet) {
            SpeedSliderSheet()
        }
        .sheet(isPresented: $showingChaptersSheet) {
            if let book {
                ChaptersSheet(book: book)
            }
        }
    }

    // MARK: - 顶部栏

    /// 左侧返回，右侧分享（把此刻正在读的那句画成摘录卡片）
    private var header: some View {
        HStack {
            backButton
            Spacer()
            shareButton
        }
        // 详情页返回按钮圆底左边缘在屏幕算起 19.3pt 处，外层内容已带 24pt 横内边距，这里回退对齐
        .padding(.leading, -4.7)
        .padding(.trailing, 12)
    }

    /// iOS 26 用系统玻璃圆底（与导航栏返回按钮同材质），更早系统用超细材质圆底近似
    @ViewBuilder
    private var backButton: some View {
        circleButton(glyph: "chevron.left", action: closePlayer)
            .accessibilityLabel(L("Back"))
    }

    /// 右上角分享入口：与返回按钮同尺寸同材质的玻璃圆底，把正在读的那句画成摘录卡片。
    /// 图标照微信读书那样用「方框 + 右上箭头」（arrow.up.forward.square），
    /// 不用系统分享那个「方框 + 向上箭头」—— 后者在本 App 里是卡片层那颗按钮的图标
    @ViewBuilder
    private var shareButton: some View {
        if let quote = shareQuote {
            circleButton(glyph: "arrow.up.forward.square") { quoted = quote }
                .accessibilityIdentifier("shareQuote")
                .accessibilityLabel(L("Share"))
        }
    }

    /// 圆底图标按钮：视觉与热区规格见 CircleGlyphButton
    @ViewBuilder
    private func circleButton(glyph name: String, action: @escaping () -> Void) -> some View {
        CircleGlyphButton(glyph: name, action: action)
    }

    // MARK: - 封面

    /// 尺寸由 PlayerLayout 按剩余空间与宽度上限算好后下发，这里只负责呈现
    private var artwork: some View {
        ZStack {
            if let cover = artworkImage {
                Image(uiImage: cover)
                    .resizable()
                    .scaledToFit()
            } else {
                // 没提取到封面：占位底色取背景中段主色的同色系，融入渐变
                LinearGradient(colors: [palette.middle.opacity(0.75), palette.lower.opacity(0.9)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                Image(systemName: "headphones")
                    .font(.system(size: 64))
                    .foregroundStyle(.white.opacity(0.9))
            }
        }
        .layoutPriority(1)
        // 按书籍封面自身比例锁定尺寸，填满 PlayerLayout 下发的提案
        .aspectRatio(artworkRatio, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        // 阴影扩散控在 ±24pt 内，不侵入下方章节名的 32pt 安全间距
        .shadow(color: .black.opacity(0.32), radius: 12, y: 10)
    }

    // MARK: - 书名 / 作者（Apple Music 式左对齐）

    private var metadata: some View {
        VStack(alignment: .leading, spacing: 6) {
            // 书名放最上面，最醒目
            Text(book?.title ?? L("Not Playing"))
                .font(.title2.weight(.bold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.7)

            if let author = book?.author, !author.isEmpty {
                // 作者名紧跟书名，可点：收起播放页并跳该作者的作品页
                Button { openAuthor(author) } label: {
                    Text(author)
                        .font(.title3)
                        .foregroundStyle(.white.opacity(0.7))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(LF("View All Books by \"%@\"", author))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
    }

    // MARK: - 章节名（紧贴封面下方）

    /// 章节名是封面的图注，与封面只用小间距，与进度条同属一个播放组；
    /// 这一行右端是章节入口（原先在右上角，为分享让位挪到这里，与「N 章」弹层是一对）
    private var chapterText: some View {
        HStack(spacing: 0) {
            Text(player.currentChapter?.title ?? L("Not Playing"))
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.6))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(maxWidth: .infinity, alignment: .leading)

            chaptersButton
        }
        .padding(.horizontal, 12)
    }

    /// 章节入口：点开弹出章节列表快捷切章。只用一枚与章节名同色的小图标，
    /// 不再套玻璃圆底 —— 这一行是文字注脚，不是操作栏
    ///
    /// 字号与深浅跟下面字幕行右端那枚文稿图标完全一致（15pt / .regular / 白 0.6）：
    /// 两枚图标上下成一列，实测 list.bullet 在 15pt 是 19×13、text.page 是 17×18，
    /// 宽度只差 2pt；之前一个 17pt 一个 14pt 时宽度差到 6pt，看着就是两套东西
    ///
    /// 热区单独扩到 44×32（图标本身只有 ~19pt，擦着边点不中且没有任何反馈），
    /// 多出来的尺寸用负边距抵掉：图标的视觉位置与这一行的高度都不变
    private var chaptersButton: some View {
        Button { showingChaptersSheet = true } label: {
            Image(systemName: "list.bullet")
                .font(.system(size: 15, weight: .regular))
                .foregroundStyle(.white.opacity(0.6))
                .frame(width: 44, height: 32)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.trailing, -13)
        .padding(.vertical, -7)
        .accessibilityIdentifier("chaptersButton")
        .accessibilityLabel(LF("%d Chapters", book?.chapters.count ?? 0))
    }

    // MARK: - 字幕（正在朗读的那一句）

    /// 当前该显示的字幕：拖动进度条时跟着预览位置走，与两侧时间数字保持一致
    private var captionText: String? {
        transcripts.text(forChapter: player.currentChapter?.id,
                         at: scrubTime ?? player.currentTime)
    }

    /// 当前这一章有没有字幕（没转写出来的书整块不占位，不留一行空白）
    private var hasCaption: Bool {
        transcripts.hasTranscript(for: player.currentChapter?.id)
    }

    /// 摘某一时刻正在读的那句，时刻取这句的起点（与文案页点句同口径）。
    /// 句间停顿仍算在上一句里（与字幕显示同一判据）。
    /// fallBackToFirst: 给「还没读到第一句」兜底 —— 右上角那枚分享按钮总得有东西可分享；
    /// 长按字幕不兜底，那时字幕本身是空的，摘出来会和屏幕上看到的不一致
    private func quote(at time: TimeInterval, fallBackToFirst: Bool = false) -> Quote? {
        guard let book, let chapter = player.currentChapter else { return nil }
        let lines = transcripts.lines(forChapter: chapter.id)
        let line = transcripts.line(forChapter: chapter.id, at: time)
            ?? (fallBackToFirst ? lines.first : nil)
        guard let line else { return nil }
        return Quote(book: book, chapter: chapter, line: line)
    }

    /// 长按字幕要摘的那句；还没读到第一句时摘不出来，那就不挂长按菜单
    private var captionQuote: Quote? {
        quote(at: scrubTime ?? player.currentTime)
    }

    /// 右上角分享要摘的那句；这一章压根没字幕（没转写过的书）时返回 nil，按钮整枚不出现
    private var shareQuote: Quote? {
        hasCaption ? quote(at: scrubTime ?? player.currentTime, fallBackToFirst: true) : nil
    }

    @ViewBuilder
    private var caption: some View {
        if hasCaption {
            // 整块字幕都是入口：点它拉开全章文案页（QQ 音乐的同款交互）。
            // 右端那枚文本图标属于同一个按钮，不是第二个控件 —— 一行里叠两个按钮只会
            // 互抢热区；图标负责「看得见有东西可点」，整行负责「哪儿都点得中」
            Button(action: openTranscript) {
                HStack(alignment: .top, spacing: 8) {
                    ZStack(alignment: .topLeading) {
                        if let text = captionText {
                            Text(text)
                                .font(.footnote)
                                .multilineTextAlignment(.leading)
                                .foregroundStyle(.white.opacity(0.85))
                                .lineLimit(2)
                                .minimumScaleFactor(0.85)
                                // 只在换句时重建视图，配合 transition 做淡入淡出
                                .id(text)
                                .transition(.opacity)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .topLeading)

                    Image(systemName: "text.page")
                        // 15pt / 白 0.6 与上面章节行那枚图标配成同一列，规格见 chaptersButton
                        .font(.system(size: 15, weight: .regular))
                        .foregroundStyle(.white.opacity(0.6))
                        // 与首行文字的光学中线对齐
                        .offset(y: 1)
                }
                .frame(minHeight: Self.captionHeight, alignment: .topLeading)
                .clipped()
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .animation(.easeInOut(duration: 0.28), value: captionText ?? "")
            // 长按这句 → 摘录卡片（点开还是文案页，两件事不抢同一个手势）
            .quoteMenu(captionQuote) { quoted = $0 }
            // 上间距加在 if 分支内部：无字幕时整块不出现，不能在外面留下 8pt 空档
            .padding(.top, Self.gapChapterToCaption)
            .padding(.horizontal, 12)
            .accessibilityIdentifier("caption")
            .accessibilityLabel(L("Chapter Text"))
        }
    }

    // MARK: - 底部播放组

    /// 章节名、字幕、进度条、控制排是一个功能整体，用统一的组内间距成组贴底，
    /// 与封面的间距大于组内间距，突出「图注+操作」这一组
    private var playbackGroup: some View {
        VStack(spacing: 0) {
            chapterText

            caption

            progress
                .padding(.top, hasCaption ? Self.gapCaptionToProgress : Self.gapChapterToProgress)

            controls
                .padding(.top, Self.gapProgressToControls)
        }
    }

    // MARK: - 进度

    /// 快退 15 秒、轨道、快进 15 秒排成一排（参考微信读书），时间行仍在其下方
    private var progress: some View {
        VStack(spacing: 6) {
            HStack(spacing: Self.skipToTrackGap) {
                skipButton(glyph: "gobackward.15", label: L("Skip Backward 15 Seconds")) {
                    player.skip(by: -Self.skipSeconds)
                }

                Slider(
                    value: Binding(
                        get: { scrubTime ?? player.currentTime },
                        set: { scrubTime = $0 }
                    ),
                    in: 0...max(player.duration, 1),
                    onEditingChanged: { editing in
                        if !editing, let t = scrubTime {
                            player.seek(to: t)
                            scrubTime = nil
                        }
                    }
                )
                .tint(.white)

                skipButton(glyph: "goforward.15", label: L("Skip Forward 15 Seconds")) {
                    player.skip(by: Self.skipSeconds)
                }
            }

            HStack {
                Text(TimeFormat.time(scrubTime ?? player.currentTime))
                Spacer()
                Text("-" + TimeFormat.time(max(player.duration - (scrubTime ?? player.currentTime), 0)))
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.white.opacity(0.7))
            // 两端让位给快进快退按钮，时间数字正好落在轨道起止点下方
            .padding(.horizontal, Self.skipButtonSide + Self.skipToTrackGap)
        }
    }

    /// 快进/快退按钮：只用图标不加文字，符合播放页整体的极简排布
    private func skipButton(glyph: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: glyph)
                .font(.system(size: 21, weight: .regular))
                .foregroundStyle(.white)
                .frame(width: Self.skipButtonSide, height: Self.skipButtonSide)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    // MARK: - 主控制

    /// 控制排两端放语速与定时，占据原快退 15s / 快进 30s 的位置
    private var controls: some View {
        HStack {
            Spacer()
            // 点开语速面板，拖动滑杆连续调节
            Button {
                showingSpeedSheet = true
            } label: {
                Text("\(TimeFormat.speed(player.speed))x")
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(.white.opacity(player.speed == 1.0 ? 0.15 : 0.28)))
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            Spacer()
            Button { player.previousChapter() } label: {
                Image(systemName: "backward.fill")
                    .font(.system(size: 24))
            }
            Spacer()
            Button { player.togglePlayPause() } label: {
                Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 68))
            }
            Spacer()
            Button { player.nextChapter() } label: {
                Image(systemName: "forward.fill")
                    .font(.system(size: 24))
            }
            Spacer()
            Button { showingSleepSheet = true } label: {
                VStack(spacing: 2) {
                    // 与同排快退/快进图标同字号，避免比左侧语速胶囊明显偏小
                    Image(systemName: player.sleepMode == .off ? "clock" : "clock.fill")
                        .font(.system(size: 24))
                    if player.sleepMode != .off {
                        // 两种定时都报还剩多少时间：章数定时换算成听完这些章还要多久，一路往下走
                        Text(TimeFormat.time(player.sleepSecondsLeft))
                            .font(.caption2.monospacedDigit())
                    }
                }
                .foregroundStyle(.white.opacity(player.sleepMode == .off ? 0.7 : 1.0))
            }
            .buttonStyle(.plain)
            Spacer()
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
        .padding(.horizontal, 8)
    }
}

/// 播放页专用竖向布局：除封面外每块高度全部实测（不预估魔法数字，
/// 字体缩放/多语言/不同机型都自适应），剩余空间先给封面（受宽度上限与
/// 可用高度双重限制），吸收不掉的多余空间按 topWeight:bottomWeight 分到
/// 封面上下两侧，保证任何屏幕尺寸都不重叠、不溢出、不留大块死空白
struct PlayerLayout: Layout {
    /// 封面在子视图中的下标
    let coverIndex: Int
    /// 封面宽高比（跟随封面图自身比例）
    let ratio: CGFloat
    /// 封面宽度硬上限
    let coverMaxWidth: CGFloat
    /// 固定间距：顶部块与封面之间、封面与底部组之间（含封面阴影的安全净距）
    var topGap: CGFloat = 16
    var bottomGap: CGFloat = 32
    /// 剩余空间分配比例：封面上侧 vs 封面下侧（下侧略大让播放组自然靠底）
    var topWeight: CGFloat = 2
    var bottomWeight: CGFloat = 3

    struct LayoutData {
        var size: CGSize
        var isCover: Bool
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        CGSize(width: proposal.width ?? 0, height: proposal.height ?? 0)
    }

    private func measure(_ subviews: Subviews, width: CGFloat) -> [LayoutData] {
        subviews.enumerated().map { index, subview in
            // 宽度按可用宽实测，高度不限制（传 nil 取理想高度）
            let size = subview.sizeThatFits(ProposedViewSize(width: width, height: nil))
            return LayoutData(size: size, isCover: index == coverIndex)
        }
    }

    /// 算出封面实际尺寸与上下两侧弹性空隙；供 sizeThatFits 与 placeSubviews 共用，保证两处一致
    private func solve(_ proposal: ProposedViewSize, _ data: [LayoutData])
        -> (cover: CGSize, extraTop: CGFloat, extraBottom: CGFloat) {
        let availWidth = proposal.width ?? 390
        let availHeight = proposal.height ?? 800
        let fixed = data.enumerated()
            .filter { $0.offset != coverIndex }
            .reduce(CGFloat(0)) { $0 + $1.element.size.height }
        let slack = max(0, availHeight - fixed - topGap - bottomGap)

        // 封面先按宽度上限取宽，高度超预算时再回缩
        let coverWidth = min(coverMaxWidth, availWidth, slack * ratio)
        let coverHeight = coverWidth / ratio
        let leftover = max(0, slack - coverHeight)
        let totalWeight = topWeight + bottomWeight
        return (
            CGSize(width: coverWidth, height: coverHeight),
            leftover * topWeight / totalWeight,
            leftover * bottomWeight / totalWeight
        )
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let data = measure(subviews, width: bounds.width)
        let solved = solve(proposal, data)

        var y = bounds.minY
        for (index, item) in data.enumerated() {
            if index == coverIndex {
                y += topGap + solved.extraTop
                // 封面水平居中
                subviews[index].place(
                    at: CGPoint(x: bounds.midX - solved.cover.width / 2, y: y),
                    anchor: .topLeading,
                    proposal: ProposedViewSize(solved.cover)
                )
                y += solved.cover.height + bottomGap + solved.extraBottom
            } else {
                subviews[index].place(
                    at: CGPoint(x: bounds.minX, y: y),
                    anchor: .topLeading,
                    proposal: ProposedViewSize(width: bounds.width, height: item.size.height)
                )
                y += item.size.height
            }
        }
    }
}

/// 支持拖动 + 点击跳转的步进滑杆：点击轨道任意位置吸附到最近刻度，拖动实时调节
struct StepSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double

    /// 滑块直径，同时作为轨道两端留给滑块中心的内缩距离（与刻度尺对齐）
    static let knobSize: CGFloat = 24
    static let knobInset: CGFloat = knobSize / 2

    /// 累计位移阈值，用于区分轻点与拖动
    @State private var isDragging = false

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let height = geo.size.height
            let travel = max(width - Self.knobSize, 0)
            let centerX = Self.knobInset + fraction * travel

            ZStack(alignment: .topLeading) {
                Capsule()
                    .fill(Color.secondary.opacity(0.2))
                    .frame(width: width, height: 4)
                    .offset(y: (height - 4) / 2)
                Capsule()
                    .fill(Color.indigo)
                    .frame(width: max(centerX, 0), height: 4)
                    .offset(y: (height - 4) / 2)
                Circle()
                    .fill(.white)
                    .shadow(color: .black.opacity(0.2), radius: 2, y: 1)
                    .frame(width: Self.knobSize, height: Self.knobSize)
                    .offset(x: centerX - Self.knobSize / 2, y: (height - Self.knobSize) / 2)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        if !isDragging &&
                            abs(gesture.translation.width) + abs(gesture.translation.height) > 6 {
                            isDragging = true
                        }
                        if isDragging {
                            // 拖动实时生效，不做动画保证跟手
                            value = snapped(atX: gesture.location.x, travel: travel)
                        }
                    }
                    .onEnded { gesture in
                        if !isDragging {
                            // 轻点轨道：滑块弹跳到点击位置
                            withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                                value = snapped(atX: gesture.location.x, travel: travel)
                            }
                        }
                        isDragging = false
                    }
            )
        }
        .frame(height: 36)
    }

    private var fraction: CGFloat {
        let span = range.upperBound - range.lowerBound
        // 值可能落在范围外（定时关闭那根轴的量程跟着模式换），滑块不许顶出轨道
        return CGFloat(min(max((value - range.lowerBound) / span, 0), 1))
    }

    private func snapped(atX x: CGFloat, travel: CGFloat) -> Double {
        let raw = Double(max(0, min(1, (x - Self.knobInset) / max(travel, 1))))
            * (range.upperBound - range.lowerBound) + range.lowerBound
        let stepped = (raw / step).rounded() * step
        return min(max(stepped, range.lowerBound), range.upperBound)
    }
}

/// 章节列表弹层：复用详情页的 ChapterList，点章节即切换播放，不另做一套列表
struct ChaptersSheet: View {
    let book: Book

    var body: some View {
        NavigationStack {
            List {
                ChapterList(book: book)
            }
            .listStyle(.plain)
            .navigationTitle(LF("%d Chapters", book.chapters.count))
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium, .large])
    }
}

/// 整章文案页：学 QQ 音乐的歌词页 —— 封面糊开只晕颜色、正在读的那句最实、
/// 上下每远一句淡一档，点任意一句跳过去。数据 TranscriptStore 已在手里，纯展示
struct TranscriptView: View {
    let book: Book
    let chapter: Chapter
    /// 背景主色与封面由播放页算好传进来，两页同一套色，拉开文案页不跳色
    let palette: CoverPalette
    let cover: UIImage?
    let onCollapse: () -> Void
    /// 摘录按钮按下后交给播放页出卡片（卡片层只有一份，挂在那里）
    let onQuote: (Quote) -> Void

    @EnvironmentObject private var player: PlayerService
    @ObservedObject private var transcripts = TranscriptStore.shared
    /// 自动跟随的暂停截止点：自己刚滑过就安静几秒，否则读到的位置会被播放进度一次次拽回去
    @State private var followHoldUntil = Date.distantPast

    /// 手动滑动之后暂停跟随的秒数：够读几句，又不至于一直不跟
    private static let followPause: TimeInterval = 8
    /// 焦点渐变：每远一句淡多少、淡到哪儿为止。文稿页首先得能读，
    /// 不能像歌词那样把远处的句子抹到看不见，所以留 0.5 的地板
    private static let fadeStep = 0.12
    private static let fadeFloor = 0.5

    private var lines: [TranscriptLine] { transcripts.lines(forChapter: chapter.id) }

    /// 此刻正在朗读的那一句（-1 表示还没开口）
    private var activeIndex: Int { transcripts.lineIndex(forChapter: chapter.id, at: player.currentTime) }

    var body: some View {
        ZStack {
            backdrop

            VStack(spacing: 0) {
                header
                textList
            }
        }
        // 整页都是这一层的命中区：糊化的底是装饰层（关了命中测试），不铺形状的话
        // 文字之间的空隙会把点击和下滑整个漏给下面的播放页 —— 表现是「往下滑一下，
        // 文案页和播放页一起没了」，底部控件也能被隔着点走
        .contentShape(Rectangle())
        // 下滑收起（列表区自己吃掉拖动，这一层只在标题与留白处生效）
        .gesture(
            DragGesture()
                .onEnded { value in
                    if value.translation.height > 100 || value.predictedEndTranslation.height > 250 {
                        onCollapse()
                    }
                }
        )
    }

    // MARK: - 底

    /// 主色渐变 + 糊开的封面：只要封面的颜色晕染，不要形状（糊化半径 60 再压一层深色纱，
    /// 白字才稳）。整块是装饰层，必须关掉命中测试，否则 scaledToFill 撑大的巨物会吞掉点击
    private var backdrop: some View {
        ZStack {
            palette.gradient

            if let cover {
                Color.clear
                    .overlay(
                        Image(uiImage: cover)
                            .resizable()
                            .scaledToFill()
                            .blur(radius: 60)
                            .opacity(0.45)
                    )
                    .clipped()
                    .overlay(Color.black.opacity(0.22))
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

    // MARK: - 顶部

    /// 收起入口 + 摘录入口 + 书名 + 作者·章节名：层级照 QQ 音乐歌词页那两行（歌名大、歌手小），
    /// 也与播放页「书名 > 作者 > 章节名」的记账顺序一致
    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                CircleGlyphButton(glyph: "chevron.down", action: onCollapse)
                    .accessibilityLabel(L("Back"))
                    .accessibilityIdentifier("collapseTranscript")
                Spacer()
                // 摘录这一页正在读的那句。图标与右上角那枚分享完全一致（同一个符号、
                // 同一个圆底、同一字重），只是这一页是 ScrollView + LazyVStack，
                // 长按菜单在那个结构里弹不出来，所以入口做成看得见的按钮放在右上角
                CircleGlyphButton(glyph: "arrow.up.forward.square") {
                    if let quote = currentQuote { onQuote(quote) }
                }
                .accessibilityLabel(L("Share"))
                .accessibilityIdentifier("quoteCurrentLine")
            }
            .padding(.bottom, 14)

            // 书名比正文当前句（.title3）还大一档，不然会被歌词式的大字压过去
            Text(book.title)
                .font(.title2.weight(.semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.7)

            Text(byline)
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.6))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 24)
        .padding(.bottom, 18)
    }

    /// 按钮摘的是哪句：正在读的那句；还没读到第一句就摘第一句（这一页只在有字幕时存在）
    private var currentQuote: Quote? {
        let index = activeIndex >= 0 ? activeIndex : 0
        guard lines.indices.contains(index) else { return nil }
        return Quote(book: book, chapter: chapter, line: lines[index])
    }

    /// 第二行：作者 · 本章名（这本书没标作者就只剩章名，不留个孤零零的分隔点）
    private var byline: String {
        let author = book.author.flatMap { $0.isEmpty ? nil : $0 }
        return [author, chapter.title].compactMap { $0 }.joined(separator: " · ")
    }

    // MARK: - 文案

    private var textList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                // LazyVStack 只渲染露出来的那十几行：一章最多近五百句，
                // 全量建视图的话每秒一次的进度刷新都要重排一遍，滚动会发涩
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                        Button { jump(to: line, index: index, proxy: proxy) } label: {
                            Text(line.text)
                                // 当前句真换字号（17→20）而不是 scaleEffect 放大：
                                // 缩放后的字会发虚，行距也不会跟着长
                                .font(index == activeIndex ? .title3 : .body)
                                .fontWeight(index == activeIndex ? .bold : .regular)
                                .multilineTextAlignment(.leading)
                                .foregroundStyle(.white.opacity(emphasis(index)))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 11)
                                .contentShape(Rectangle())
                        }
                        // 必须是真 Button：只用 onTapGesture 的话无障碍树里这行虽然顶着
                        // AXButton 的名，AXPress 却什么都不做（点不中也没任何反馈）
                        .buttonStyle(.plain)
                        .id(index)
                        .accessibilityIdentifier("transcriptLine\(index)")
                    }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 40)
                .animation(.easeInOut(duration: 0.35), value: activeIndex)
            }
            .simultaneousGesture(DragGesture(minimumDistance: 0)
                .onChanged { _ in followHoldUntil = Date().addingTimeInterval(Self.followPause) })
            .onAppear { land(on: activeIndex, proxy: proxy) }
            // 读到一半自动续播到下一章：整篇换了，落点也要跟着换到新一章的当前句
            .onChange(of: chapter.id) { _ in land(on: activeIndex, proxy: proxy) }
            .onChange(of: activeIndex) { index in
                guard player.isPlaying, Date() >= followHoldUntil else { return }
                withAnimation(.easeInOut(duration: 0.3)) {
                    proxy.scrollTo(index, anchor: .center)
                }
            }
        }
    }

    /// 离当前句越远越淡
    private func emphasis(_ index: Int) -> Double {
        guard activeIndex >= 0 else { return 1 }
        let distance = abs(index - activeIndex)
        return max(Self.fadeFloor, 1 - Self.fadeStep * Double(distance))
    }

    /// 打开文案页先落到正在读的那句，而不是从章头开始翻。
    /// 页面正从底部滑进来，头几帧 ScrollView 还没量好尺寸，单次 scrollTo 会被忽略
    /// （实测第一次打开停在章头，重开才落对），所以隔一点时间补两次；
    /// 期间用户已经自己滑走就不再拽他
    private func land(on index: Int, proxy: ScrollViewProxy) {
        guard index >= 0 else { return }
        for delay in [0.0, 0.15, 0.5] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                guard Date() >= self.followHoldUntil else { return }
                proxy.scrollTo(index, anchor: .center)
            }
        }
    }

    /// 点句：跳过去，并把这句滚到正中 —— 页面不关，句子亮起来居中就是反馈，
    /// 不用回到播放页确认。暂停中也要滚：那时没有每秒的进度刷新可依赖
    private func jump(to line: TranscriptLine, index: Int, proxy: ScrollViewProxy) {
        NSLog("[sonux] ui: 文案页点句，跳到 %.1f s", line.start)
        player.seek(to: line.start)
        withAnimation(.easeInOut(duration: 0.3)) {
            proxy.scrollTo(index, anchor: .center)
        }
    }
}

/// 圆底图标按钮：视觉尺寸与材质与详情页导航栏返回按钮一致，播放页与文案页共用。
/// 热区单独扩到 hitDiameter —— 只有 45pt 的圆擦着边就点不中，而点不中是无声的：
/// 播放页还盖在上面，用户以为「后面那几本书点不开了」。扩出来的空间用负边距抵消，
/// 排版与画面位置完全不变（负值 = -(热区-视觉)/2）
struct CircleGlyphButton: View {
    let glyph: String
    let action: () -> Void

    /// 取自详情页导航栏返回按钮的实测尺寸
    static let diameter: CGFloat = 45
    /// Apple 建议的最小触控边距是 44pt，视觉 45pt 的圆擦边点不中且没有任何反馈，
    /// 扩到 68 才容得下手抖
    static let hitDiameter: CGFloat = 68

    /// 圆底图标按钮：视觉尺寸与材质与详情页导航栏返回按钮一致，播放页与文案页共用。
    /// 图标一律用 .regular 字重 —— 全 App 的描线图标都走 SF Symbols 默认字重，
    /// 半粗（.semibold）在深色背景上会明显发粗，和同页其他图标摆一起就不成一套了
    var body: some View {
        let icon = Image(systemName: glyph)
            .font(.system(size: 21, weight: .regular))
            .foregroundStyle(.white)
            .frame(width: Self.diameter, height: Self.diameter)
        let slop = (Self.hitDiameter - Self.diameter) / 2

        Button(action: action) {
            icon
                .modifier(GlassCircleBackground())
                .frame(width: Self.hitDiameter, height: Self.hitDiameter)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, -slop)
        .padding(.vertical, -slop)
    }
}

/// iOS 26 用系统玻璃圆底（与导航栏返回按钮同材质），更早系统用超细材质圆底近似
private struct GlassCircleBackground: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.glassEffect(.regular.interactive(), in: Circle())
        } else {
            content
                .background(Circle().fill(.ultraThinMaterial))
                .overlay(Circle().strokeBorder(.white.opacity(0.2), lineWidth: 1))
        }
    }
}

/// 播放页那系弹层（语速、定时关闭、摘录卡片）共用的深紫实心底。
/// 别用系统材质：它的模糊半径太小，透色必先透形，底下那排白色控件会糊成一团团光晕
extension Color {
    static let playerSheetBackground = Color(red: 0.06, green: 0.05, blue: 0.10)
}

/// 语速面板：参考微信读书，拖动滑杆在 0.5x–3x 之间以 0.1 为步进连续调节
struct SpeedSliderSheet: View {
    @EnvironmentObject private var player: PlayerService

    /// 刻度尺上标数字的档位
    private let majorValues: [Double] = [0.5, 1.0, 2.0, 3.0]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                Text(L("Playback Speed"))
                    .font(.headline)
                Spacer()
                Text("\(TimeFormat.speed(player.speed))x")
                    .font(.title3.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(.indigo)
            }

            StepSlider(
                value: Binding(
                    get: { Double(player.speed) },
                    set: { player.setSpeed(Float($0)) }
                ),
                range: PlayerService.speedRange,
                step: PlayerService.speedStep
            )

            ruler

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 24)
        .padding(.top, 24)
        .presentationBackground(Color.playerSheetBackground)
        .presentationDetents([.height(200)])
        .presentationDragIndicator(.visible)
    }

    /// 0.1 一格的小刻度，整档高亮并标出倍数
    private var ruler: some View {
        GeometryReader { geo in
            let width = geo.size.width
            ZStack(alignment: .topLeading) {
                ForEach(tickValues, id: \.self) { value in
                    let isMajor = majorValues.contains(value)
                    Rectangle()
                        .fill(Color.secondary.opacity(isMajor ? 0.6 : 0.25))
                        .frame(width: 1, height: isMajor ? 9 : 5)
                        .offset(x: xPosition(for: value, in: width))
                }
                ForEach(majorValues, id: \.self) { value in
                    Text("\(TimeFormat.speed(Float(value)))x")
                        .font(.caption2)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(width: 44)
                        .offset(
                            x: min(max(xPosition(for: value, in: width) - 22, 0), max(width - 44, 0)),
                            y: 11
                        )
                }
            }
        }
        .frame(height: 32)
    }

    private var tickValues: [Double] {
        stride(from: PlayerService.speedRange.lowerBound,
               through: PlayerService.speedRange.upperBound,
               by: PlayerService.speedStep)
            .map { ($0 * 10).rounded() / 10 }
    }

    /// 滑块中心在两端各内缩半个滑块宽度，轨道中点对应 value 中点，因此换算需与 StepSlider 保持一致
    private func xPosition(for value: Double, in width: CGFloat) -> CGFloat {
        let span = PlayerService.speedRange.upperBound - PlayerService.speedRange.lowerBound
        let travel = max(width - StepSlider.knobSize, 0)
        return StepSlider.knobInset + CGFloat((value - PlayerService.speedRange.lowerBound) / span) * travel
    }
}

/// 定时关闭面板：参考微信读书，拖动滑杆在 0–90 分钟之间以 1 分钟为步进设置，滑到最左端为关闭。
/// 挂上「听完 N 章」之后整根轴换成章数刻度（关、1…5，一格一章，滑块就停在刻度上）——
/// 拖的时候看刻度就知道自己在挑章数还是挑时间，还要多少分钟由上面那行标题说
struct SleepTimerSheet: View {
    @EnvironmentObject private var player: PlayerService

    /// 分钟刻度上标数字的档位
    private let minuteMajors: [Double] = [0, 30, 60, 90]

    /// 章数定时还剩几章；当前不是章数定时则为 nil
    private var chapters: Int? {
        if case .chapters(let count) = player.sleepMode { return count }
        return nil
    }

    private var isChapterMode: Bool { chapters != nil }

    /// 轴的量程跟着模式走：章数模式固定 0–5 章，一格一章
    private var axisRange: ClosedRange<Double> {
        isChapterMode ? 0...Double(SleepTimerMode.chapterRange.upperBound) : SleepTimerMode.range
    }

    /// 滑块停在哪儿：章数模式停在自己的章数上（听完整章才动一格），分钟模式停在秒表读数上
    private var axisValue: Double {
        chapters.map(Double.init) ?? player.sleepSecondsLeft / 60
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(sheetTitle)
                .font(.headline)
                .foregroundStyle(player.sleepMode == .off ? Color.primary : Color.indigo)

            StepSlider(value: axisBinding,
                       range: axisRange,
                       step: 1)

            ruler

            HStack(spacing: 12) {
                modeButton(chapterTitle, active: chapters != nil) {
                    player.setSleepTimer(chapters == nil ? .chapters(player.defaultSleepChapters) : .off)
                }
                modeButton(L("No Timer"), active: false) {
                    player.setSleepTimer(.off)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 24)
        .padding(.top, 24)
        .presentationBackground(Color.playerSheetBackground)
        .presentationDetents([.height(220)])
        .presentationDragIndicator(.visible)
    }

    /// 标题只报时间：两种定时最后都是「还要多少分钟才关」，章数定时换算成分钟报，
    /// 按什么规则关交给下面那枚卡片说。挂着章数定时听，这个数字一路往下走
    private var sheetTitle: String {
        let minutes = Int((player.sleepSecondsLeft / 60).rounded())
        if minutes > 0 { return LF("Off After %d Minutes", minutes) }
        // 报不出分钟数：要么没挂定时，要么挂的章数已经没多少可等（剩下的时间不足半分钟），
        // 后者退回说章数，跟卡片保持一致，免得报个「0 分钟」或错报成没定时
        return chapters == nil ? L("Sleep Timer") : chapterTitle
    }

    /// 章数卡片的文案：1 章仍是「本章结束后关闭」，多章说「听完 N 章后关闭」。
    /// 没挂章数定时时写的是点下去会设成的章数（上次调几章就还写几章）
    private var chapterTitle: String {
        let count = chapters ?? player.defaultSleepChapters
        return count > 1 ? LF("Off After %d Chapters", count) : L("Off After This Chapter")
    }

    /// 拖动即时生效，滑到最左端（0）都是关闭。章数模式下轴上的数就是章数，一格一章
    private var axisBinding: Binding<Double> {
        Binding(
            get: { axisValue },
            set: { value in
                if isChapterMode {
                    player.setSleepTimer(value > 0 ? .chapters(Int(value.rounded())) : .off)
                } else {
                    player.setSleepTimer(value > 0 ? .minutes(Int(value)) : .off)
                }
            }
        )
    }

    /// 刻度尺：分钟模式 5 分钟一道小刻度、整档标 0/30/60/90；章数模式一格一章、每道刻度都标上章号。
    /// 两种模式最左那道都标「关」
    private var ruler: some View {
        GeometryReader { geo in
            let width = geo.size.width
            ZStack(alignment: .topLeading) {
                ForEach(tickValues, id: \.self) { value in
                    let isMajor = majorValues.contains(value)
                    Rectangle()
                        .fill(Color.secondary.opacity(isMajor ? 0.6 : 0.25))
                        .frame(width: 1, height: isMajor ? 9 : 5)
                        .offset(x: xPosition(for: value, in: width))
                }
                ForEach(majorValues, id: \.self) { value in
                    Text(value == 0 ? L("Off") : "\(Int(value))")
                        .font(.caption2)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(width: 44)
                        .offset(
                            x: min(max(xPosition(for: value, in: width) - 22, 0), max(width - 44, 0)),
                            y: 11
                        )
                }
            }
        }
        .frame(height: 32)
    }

    /// 标数字的档位：分钟模式 0/30/60/90，章数模式 0–5 一章一档
    private var majorValues: [Double] {
        guard isChapterMode else { return minuteMajors }
        return Array(stride(from: axisRange.lowerBound, through: axisRange.upperBound, by: 1))
    }

    /// 小刻度：分钟模式 5 分钟一道；章数刻度本来就一格一章，不再插小刻度
    private var tickValues: [Double] {
        guard !isChapterMode else { return majorValues }
        return stride(from: SleepTimerMode.range.lowerBound,
                      through: SleepTimerMode.range.upperBound,
                      by: 5)
            .map { $0.rounded() }
    }

    private func xPosition(for value: Double, in width: CGFloat) -> CGFloat {
        let span = axisRange.upperBound - axisRange.lowerBound
        let travel = max(width - StepSlider.knobSize, 0)
        return StepSlider.knobInset + CGFloat((value - axisRange.lowerBound) / span) * travel
    }

    private func modeButton(_ title: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(active ? Color.indigo : Color.primary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color.secondary.opacity(active ? 0.22 : 0.12))
                )
        }
        .buttonStyle(.plain)
    }
}
