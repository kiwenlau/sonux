import SwiftUI

struct PlayerView: View {
    @EnvironmentObject private var player: PlayerService
    @State private var showingSleepSheet = false
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
                    Button {
                        player.cycleSpeed()
                    } label: {
                        Text("\(formatSpeed(player.speed))x")
                            .font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(Capsule().fill(.white.opacity(player.speed == 1.0 ? 0.15 : 0.28)))
                            .foregroundStyle(.white)
                    }
                    .buttonStyle(.plain)

                    Spacer()

                    Button { showingSleepSheet = true } label: {
                        VStack(spacing: 2) {
                            Image(systemName: player.sleepOption == .off ? "moon" : "moon.fill")
                                .font(.body)
                            if player.sleepOption != .off {
                                Text(TimeFormat.time(player.sleepRemaining))
                                    .font(.caption2.monospacedDigit())
                            }
                        }
                        .foregroundStyle(.white.opacity(player.sleepOption == .off ? 0.7 : 1.0))
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
    }

    private func formatSpeed(_ speed: Float) -> String {
        speed == speed.rounded()
            ? String(format: "%.0f", speed)
            : String(format: "%g", speed)
    }
}

struct SleepTimerSheet: View {
    @EnvironmentObject private var player: PlayerService
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List(SleepTimerOption.allCases) { option in
                Button {
                    player.setSleepTimer(option)
                    dismiss()
                } label: {
                    HStack {
                        Text(option.title)
                            .foregroundStyle(.primary)
                        Spacer()
                        if player.sleepOption == option {
                            Image(systemName: "checkmark")
                                .foregroundStyle(.indigo)
                        }
                    }
                }
            }
            .navigationTitle("睡眠定时器")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
    }
}
