import SwiftUI

struct PlayerView: View {
    @EnvironmentObject private var player: PlayerService
    @EnvironmentObject private var routers: TabRouters
    // 单例共享封面缓存，播放页大图与主色都由它提供
    @ObservedObject private var covers = CoverStore.shared

    /// 点作者名关播放页后压进当前 tab 的导航栈（历史 tab 打开的就回落到历史栈）
    private var router: AppRouter { routers.active }
    @State private var showingSleepSheet = false
    @State private var showingSpeedSheet = false
    @State private var scrubTime: TimeInterval?

    /// 没提取到封面时的兜底背景：沿用原来的紫色系，明暗结构与主色色板一致
    private static let fallbackPalette = CoverPalette(
        top: Color(red: 0.24, green: 0.16, blue: 0.44),
        middle: Color(red: 0.30, green: 0.20, blue: 0.55),
        lower: Color(red: 0.20, green: 0.12, blue: 0.38),
        bottom: Color(red: 0.10, green: 0.05, blue: 0.24)
    )

    /// 竖版封面在没有真实封面时的占位比例
    private static let placeholderRatio: CGFloat = 0.8

    /// 左上返回按钮圆底直径，取自详情页导航栏返回按钮的实测尺寸
    private static let backButtonDiameter: CGFloat = 45

    private var book: Book? { player.currentBook }

    private var palette: CoverPalette {
        guard let book, let palette = covers.palette(for: book) else { return Self.fallbackPalette }
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
        withAnimation(.spring(response: 0.38, dampingFraction: 0.86)) {
            player.showPlayer = false
        }
    }

    /// 从播放页跳作者页：先收起全屏播放页，露出下面的书库栈再入栈（与书库行为一致）
    private func openAuthor(_ author: String) {
        NSLog("[sonux] ui: 播放页点击作者「%@」", author)
        closePlayer()
        router.openAuthor(author)
    }

    var body: some View {
        GeometryReader { geo in
            // 先给文字与控件留出 380pt，剩下的都给封面；小屏时封面缩小而不是挤坏控件
            let boxHeight = min(380, max(160, geo.size.height - 380))

            ZStack {
                // 主色渐变铺满整页，包括状态栏后面，避免顶部出现突兀的边界
                palette.gradient
                    .ignoresSafeArea()

                VStack(spacing: 0) {
                    header

                    Spacer(minLength: 8)

                    artwork(boxHeight: boxHeight)

                    Spacer(minLength: 12)

                    metadata

                    progress
                        .padding(.top, 22)

                    controls
                        .padding(.top, 22)

                    secondaryControls
                        .padding(.top, 18)

                    Spacer(minLength: 8)
                }
                .padding(.horizontal, 24)
            }
            // 换书时背景主色平滑过渡，而不是整页颜色突变
            .animation(.easeInOut(duration: 0.5), value: book?.id ?? "")
        }
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
            await covers.loadLarge(for: book)
        }
        .sheet(isPresented: $showingSleepSheet) {
            SleepTimerSheet()
        }
        .sheet(isPresented: $showingSpeedSheet) {
            SpeedSliderSheet()
        }
    }

    // MARK: - 顶部栏

    /// 与书籍详情页导航栏返回按钮保持一致：同样的圆形底 + 左向尖号，同一尺寸与位置
    private var header: some View {
        HStack {
            backButton
            Spacer()
        }
        // 详情页返回按钮圆底左边缘在屏幕算起 19.3pt 处，外层内容已带 24pt 横内边距，这里回退对齐
        .padding(.leading, -4.7)
        .padding(.trailing, 12)
    }

    /// iOS 26 用系统玻璃圆底（与导航栏返回按钮同材质），更早系统用超细材质圆底近似
    @ViewBuilder
    private var backButton: some View {
        let glyph = Image(systemName: "chevron.left")
            .font(.system(size: 21, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: Self.backButtonDiameter, height: Self.backButtonDiameter)
            .contentShape(Circle())

        if #available(iOS 26.0, *) {
            Button(action: closePlayer) {
                glyph.glassEffect(.regular.interactive(), in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L("Back"))
        } else {
            Button(action: closePlayer) {
                glyph
                    .background(Circle().fill(.ultraThinMaterial))
                    .overlay(Circle().strokeBorder(.white.opacity(0.2), lineWidth: 1))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L("Back"))
        }
    }

    // MARK: - 封面

    @ViewBuilder
    private func artwork(boxHeight: CGFloat) -> some View {
        let ratio = artworkRatio
        let width = min(330, boxHeight * ratio)
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
        .frame(width: width, height: width / ratio)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .shadow(color: .black.opacity(0.35), radius: 22, y: 14)
        .padding(.horizontal, 8)
    }

    // MARK: - 章节名 / 作者 / 书名（Apple Music 式左对齐）

    private var metadata: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(player.currentChapter?.title ?? L("Not Playing"))
                    .font(.title2.weight(.bold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)

                if let author = book?.author, !author.isEmpty {
                    // 作者名可点：收起播放页并跳该作者的作品页
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
        }
        .padding(.horizontal, 12)
    }

    // MARK: - 进度

    private var progress: some View {
        VStack(spacing: 6) {
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
            HStack {
                Text(TimeFormat.time(scrubTime ?? player.currentTime))
                Spacer()
                Text("-" + TimeFormat.time(max(player.duration - (scrubTime ?? player.currentTime), 0)))
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.white.opacity(0.7))
        }
    }

    // MARK: - 主控制

    private var controls: some View {
        HStack {
            Spacer()
            Button { player.skip(by: -15) } label: {
                Image(systemName: "gobackward.15")
                    .font(.system(size: 30))
            }
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
            Button { player.skip(by: 30) } label: {
                Image(systemName: "goforward.30")
                    .font(.system(size: 30))
            }
            Spacer()
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
        .padding(.horizontal, 8)
    }

    // MARK: - 次级控制

    private var secondaryControls: some View {
        HStack {
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

            Button { showingSleepSheet = true } label: {
                VStack(spacing: 2) {
                    Image(systemName: player.sleepMode == .off ? "clock" : "clock.fill")
                        .font(.body)
                    if player.sleepMode != .off {
                        // 本章结束后关闭没有倒计时，直接标「本章」，避免把静止的数字误当成定时剩余
                        Text(player.sleepMode == .endOfChapter ? L("This Chapter") : TimeFormat.time(player.sleepRemaining))
                            .font(.caption2.monospacedDigit())
                    }
                }
                .foregroundStyle(.white.opacity(player.sleepMode == .off ? 0.7 : 1.0))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 8)
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
        return CGFloat((value - range.lowerBound) / span)
    }

    private func snapped(atX x: CGFloat, travel: CGFloat) -> Double {
        let raw = Double(max(0, min(1, (x - Self.knobInset) / max(travel, 1))))
            * (range.upperBound - range.lowerBound) + range.lowerBound
        let stepped = (raw / step).rounded() * step
        return min(max(stepped, range.lowerBound), range.upperBound)
    }
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

/// 定时关闭面板：参考微信读书，拖动滑杆在 0–90 分钟之间以 1 分钟为步进设置，滑到最左端为关闭
struct SleepTimerSheet: View {
    @EnvironmentObject private var player: PlayerService

    /// 刻度尺上标数字的档位
    private let majorValues: [Double] = [0, 30, 60, 90]

    private var minutes: Double {
        if case .minutes(let value) = player.sleepMode { return Double(value) }
        return 0
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(sheetTitle)
                .font(.headline)
                .foregroundStyle(player.sleepMode == .off ? Color.primary : Color.indigo)

            StepSlider(value: minutesBinding,
                       range: SleepTimerMode.range,
                       step: SleepTimerMode.step)

            ruler

            HStack(spacing: 12) {
                modeButton(L("Off After This Chapter"), active: player.sleepMode == .endOfChapter) {
                    player.setSleepTimer(player.sleepMode == .endOfChapter ? .off : .endOfChapter)
                }
                modeButton(L("No Timer"), active: false) {
                    player.setSleepTimer(.off)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 24)
        .padding(.top, 24)
        .presentationDetents([.height(220)])
        .presentationDragIndicator(.visible)
    }

    /// 标题直接说出当前生效的是哪一种定时，不让“本章结束后关闭”看起来像分钟定时
    private var sheetTitle: String {
        switch player.sleepMode {
        case .endOfChapter:
            return L("Off After This Chapter")
        case .minutes(let value) where value > 0:
            return LF("Off After %d Minutes", value)
        case .off, .minutes:
            return L("Sleep Timer")
        }
    }

    /// 滑动即时生效：0 分钟即关闭定时
    private var minutesBinding: Binding<Double> {
        Binding(
            get: { minutes },
            set: { player.setSleepTimer($0 > 0 ? .minutes(Int($0)) : .off) }
        )
    }

    /// 5 分钟一格的小刻度，整档高亮并标出分钟数（0 标作“关”）
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

    private var tickValues: [Double] {
        stride(from: SleepTimerMode.range.lowerBound,
               through: SleepTimerMode.range.upperBound,
               by: 5)
            .map { $0.rounded() }
    }

    private func xPosition(for value: Double, in width: CGFloat) -> CGFloat {
        let span = SleepTimerMode.range.upperBound - SleepTimerMode.range.lowerBound
        let travel = max(width - StepSlider.knobSize, 0)
        return StepSlider.knobInset + CGFloat((value - SleepTimerMode.range.lowerBound) / span) * travel
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
