import SwiftUI

struct PlayerView: View {
    @EnvironmentObject private var player: PlayerService
    @Environment(\.dismiss) private var dismiss
    @State private var showingSleepSheet = false
    @State private var scrubTime: TimeInterval?

    var body: some View {
        NavigationStack {
            VStack(spacing: 28) {
                Spacer()

                // 封面占位
                ZStack {
                    RoundedRectangle(cornerRadius: 20)
                        .fill(
                            LinearGradient(colors: [.indigo.opacity(0.5), .purple.opacity(0.4)],
                                           startPoint: .topLeading, endPoint: .bottomTrailing)
                        )
                        .frame(width: 240, height: 240)
                        .shadow(color: .indigo.opacity(0.3), radius: 18, y: 10)
                    Image(systemName: "headphones")
                        .font(.system(size: 72))
                        .foregroundStyle(.white.opacity(0.9))
                }

                VStack(spacing: 6) {
                    Text(player.currentChapter?.title ?? "未在播放")
                        .font(.title2.bold())
                        .multilineTextAlignment(.center)
                    Text(player.currentBook?.title ?? "")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
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
                    HStack {
                        Text(TimeFormat.time(scrubTime ?? player.currentTime))
                        Spacer()
                        Text("-" + TimeFormat.time(max(player.duration - (scrubTime ?? player.currentTime), 0)))
                    }
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
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
                            .background(Capsule().fill(player.speed == 1.0 ? Color.secondary.opacity(0.12) : Color.indigo.opacity(0.15)))
                            .foregroundStyle(player.speed == 1.0 ? Color.primary : Color.indigo)
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
                        .foregroundStyle(player.sleepOption == .off ? Color.secondary : Color.indigo)
                    }
                    .buttonStyle(.plain)

                    Spacer()

                    Button { dismiss() } label: {
                        Image(systemName: "chevron.down")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 8)

                Spacer(minLength: 8)
            }
            .padding(.horizontal, 24)
            .navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $showingSleepSheet) {
                SleepTimerSheet()
            }
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
