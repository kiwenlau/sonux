import Foundation
import Combine

/// 跳过静音的档位：句间空档短到这个秒数以下就不管，够长才跳过去。
/// 秒数是「音频里的秒」，与倍速无关——倍速只改变跨过它花多少墙钟时间。
///
/// 档位名字说的是「删掉多少静音」：阈值越低，跳得越勤、删得越多。
/// 全库 332.6 h 实测（python3 tools/silence-gain.py，判据与本文件一字对齐）：
/// 3.0 s → 省 0.8%、每小时跳 5 次；1.8 s → 省 1.8%、27 次；1.0 s → 省 4.5%、161 次。
enum SilenceSkipMode: Int, CaseIterable, Identifiable {
    case off = 0
    /// 只跳大段留白（章头、翻页），几乎听不出被打断
    case light = 1
    /// 一般长句间空白也跳：省时间与听感的折中
    case standard = 2
    /// 一拍停顿就走：省得最多，但每小时要跳一百多次，能听出「一卡一卡」
    case heavy = 3

    var id: Int { rawValue }

    /// 可跳空档的最短长度；关闭时返回 nil，播放器据此完全不碰进度
    var minGap: TimeInterval? {
        switch self {
        case .off: return nil
        case .light: return 3.0
        case .standard: return 1.8
        case .heavy: return 1.0
        }
    }

    /// 设置页上的短标签（也是本地化键）
    var labelKey: String {
        switch self {
        case .off: return "Off"
        case .light: return "Light"
        case .standard: return "Standard"
        case .heavy: return "Heavy"
        }
    }

    init(rawUserDefaultsValue value: Any?) {
        // 没存过就是关：自动挪播放位置属于「没打招呼就动了我的书」，得用户自己开
        self = (value as? Int).flatMap(Self.init(rawValue:)) ?? .off
    }
}

/// 播放偏好：跳过静音与语音增强。都是全局开关，落在 UserDefaults，下次启动沿用
@MainActor
final class PlaybackSettings: ObservableObject {
    static let shared = PlaybackSettings()

    private static let silenceKey = "playback.silenceSkipMode"
    private static let voiceBoostKey = "playback.voiceBoost"

    /// 默认关闭：会自动往前挪播放位置的功能，不该在用户没要求时就动他的书
    @Published private(set) var silenceMode: SilenceSkipMode = .off {
        didSet { UserDefaults.standard.set(silenceMode.rawValue, forKey: Self.silenceKey) }
    }
    /// 语音增强：只切处理链的开关，音频链路不动，所以听着随时切换也不会卡
    @Published private(set) var voiceBoost = false {
        didSet {
            UserDefaults.standard.set(voiceBoost, forKey: Self.voiceBoostKey)
            VoiceTap.shared.setEnabled(voiceBoost)
            voiceBoostChanges.send(voiceBoost)
        }
    }
    /// 增强的变化流：播放器订阅它，才知道要趁本章还没播完把处理链接上去
    let voiceBoostChanges = PassthroughSubject<Bool, Never>()

    private init() {
        silenceMode = SilenceSkipMode(rawUserDefaultsValue:
            UserDefaults.standard.object(forKey: Self.silenceKey))
        voiceBoost = UserDefaults.standard.bool(forKey: Self.voiceBoostKey)
        // 上次退出前开着增强：处理链要立刻跟上，否则这次启动的播放是「看着开着其实没生效」。
        // 关着就什么都不建——启动时不碰任何音频对象，才不会碰坏用户正在放的东西
        if voiceBoost { VoiceTap.shared.setEnabled(true) }
    }

    /// 由播放器改档位（界面只读，写入都走这里）
    func setSilenceMode(_ mode: SilenceSkipMode) {
        silenceMode = mode
    }

    func setVoiceBoost(_ on: Bool) {
        voiceBoost = on
    }
}
