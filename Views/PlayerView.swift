import SwiftUI

struct PlayerView: View {
    @EnvironmentObject private var player: PlayerService
    @State private var showingSleepSheet = false
    @State private var showingSpeedSheet = false
    @State private var scrubTime: TimeInterval?

    /// QQ 音乐式沉浸背景：顶部深色收边、中段主色，与封面同色系渐变消除边界感
    private let backgroundGradient = LinearGradient(
        stops: [
            .init(color: Color(red: 0.05, green: 0.03, blue: 0.14), location: 0),
            .init(color: Color(red: 0.30, green: 0.20, blue: 0.55), location: 0.42),
            .init(color: Color(red: 0.48, green: 0.30, blue: 0.72), location: 0.62),
            .init(color: Color(red: 0.10, green: 0.05, blue: 0.24), location: 1),
        ],
        startPoint: .top, endPoint: .bottom
    )

    /// 收起全屏播放页（下滑手势/左上角按钮共用）
    private func closePlayer() {
        withAnimation(.spring(response: 0.38, dampingFraction: 0.86)) {
            player.showPlayer = false
        }
    }

    var body: some View {
        ZStack {
            // 渐变铺满整页，包括状态栏后面，避免顶部出现突兀的边界
            backgroundGradient
                .ignoresSafeArea()

            VStack(spacing: 28) {
                // 顶部栏：左上角收起
                HStack {
                    Button { closePlayer() } label: {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 40, height: 40)
                            .contentShape(Rectangle())
                    }
                    Spacer()
                }
                .padding(.horizontal, 12)

                // 封面占位（与背景同色系，融入渐变）
                ZStack {
                    RoundedRectangle(cornerRadius: 24)
                        .fill(
                            LinearGradient(colors: [.indigo.opacity(0.65), .purple.opacity(0.55)],
                                           startPoint: .topLeading, endPoint: .bottomTrailing)
                        )
                        .frame(maxWidth: 340)
                        .aspectRatio(1, contentMode: .fit)
                        .shadow(color: .black.opacity(0.35), radius: 22, y: 14)
                    Image(systemName: "headphones")
                        .font(.system(size: 84))
                        .foregroundStyle(.white.opacity(0.9))
                }
                .padding(.horizontal, 8)

                Text(player.currentChapter?.title ?? "未在播放")
                    .font(.title2.bold())
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)

                Spacer()

                // 进度条
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

                // 主控制
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

                // 次级控制
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
                                Text(TimeFormat.time(player.sleepRemaining))
                                    .font(.caption2.monospacedDigit())
                            }
                        }
                        .foregroundStyle(.white.opacity(player.sleepMode == .off ? 0.7 : 1.0))
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 8)

                Spacer(minLength: 8)
            }
            .padding(.horizontal, 24)
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
        .sheet(isPresented: $showingSleepSheet) {
            SleepTimerSheet()
        }
        .sheet(isPresented: $showingSpeedSheet) {
            SpeedSliderSheet()
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
                Text("语速设置")
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
            Text(minutes > 0 ? "播放 \(Int(minutes)) 分钟后关闭" : "定时关闭")
                .font(.headline)
                .foregroundStyle(minutes > 0 ? Color.indigo : Color.primary)

            StepSlider(value: minutesBinding,
                       range: SleepTimerMode.range,
                       step: SleepTimerMode.step)

            ruler

            HStack(spacing: 12) {
                modeButton("本章结束后关闭", active: player.sleepMode == .endOfChapter) {
                    player.setSleepTimer(player.sleepMode == .endOfChapter ? .off : .endOfChapter)
                }
                modeButton("不设置", active: false) {
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
                    Text(value == 0 ? "关" : "\(Int(value))")
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
