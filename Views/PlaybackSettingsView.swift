import SwiftUI

/// 播放设置页：跳过静音与语音增强。两项都是全局偏好，改完立刻作用在正在播的那本上
///
/// 档位用「一行一档 + 对勾」而不是分段控件：模拟器实测分段控件在无障碍树里
/// 根本不出现（VoiceOver 摸不到，自动化也点不到），而这套样式与语言设置页一致。
struct PlaybackSettingsView: View {
    @ObservedObject private var settings = PlaybackSettings.shared

    var body: some View {
        List {
            Section {
                ForEach(SilenceSkipMode.allCases) { mode in
                    Button { settings.setSilenceMode(mode) } label: {
                        HStack {
                            Text(L(mode.labelKey))
                            Spacer()
                            if settings.silenceMode == mode {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(.indigo)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .accessibilityIdentifier("playback-silence-\(mode.rawValue)")
                }
            } header: {
                Text(L("Trim Silence"))
            }

            Toggle(L("Voice Boost"), isOn: Binding(get: { settings.voiceBoost },
                                                   set: { settings.setVoiceBoost($0) }))
                .accessibilityIdentifier("playback-voiceboost-toggle")
        }
        .navigationTitle(L("Playback"))
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("playback-settings-page")
    }
}
