import Foundation
import Combine

/// 每秒都在走的那两个读数：本章内已播秒、定时关闭剩余秒表。
///
/// 为什么要从 PlayerService 里拆出来：SwiftUI 观察 ObservableObject 不分键路径，
/// 只要这两个值挂在 PlayerService 的 @Published 上，播放器每秒发布一次就等于让书库、
/// 历史、作者页、详情页每一页的 body 每秒重算一遍——重排书单、重画 radius 60 的糊化封面，
/// 真机上几轮卡顿都是这一类根因。拆出来之后只有跟着秒跳的那几块界面观察它：
/// 迷你条的进度环、播放页的进度行与字幕、文案页的当前句、定时关闭面板的读数。
@MainActor
final class PlaybackClock: ObservableObject {
    /// 本章内已播秒
    @Published private(set) var currentTime: TimeInterval = 0
    /// 分钟定时的剩余秒表读数；章数定时不占这个数（换算见 PlayerService.sleepSecondsLeft）
    @Published private(set) var sleepRemaining: TimeInterval = 0

    /// 同值不发布：暂停时每秒也走一次进度计时，别把「没动」也广播出去
    func setCurrentTime(_ value: TimeInterval) {
        guard value != currentTime else { return }
        currentTime = value
    }

    func setSleepRemaining(_ value: TimeInterval) {
        guard value != sleepRemaining else { return }
        sleepRemaining = value
    }
}
