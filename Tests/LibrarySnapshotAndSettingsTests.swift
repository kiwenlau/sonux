import XCTest
@testable import Sonux

/// LibraryService 的两个「一次算完」快照方法：listeningSummary(now:) 与
/// listeningReport(now:calendar:)。它们本身只做组装，但把 ListeningStats 的
/// 一堆读接口一次串起来跑，能顺路覆盖到那些单独测时不常走到的分支
/// （比如 recentDays 与 streakDays 在同一次调用里各跑一遍）。
/// 直接借道 SonuxRuntime.shared.library 上的当前 listening（可能全零，也可能有真数据）。
@MainActor
final class LibrarySnapshotMethodTests: XCTestCase {
    private var library: LibraryService { SonuxRuntime.shared.library }

    // MARK: - listeningSummary

    func testListeningSummary_hasConsistentSevenDayWindow() {
        let now = Date()
        let summary = library.listeningSummary(now: now)
        // recentDays 契约：count 与传入相等，且最后一项是今天
        XCTAssertEqual(summary.recentDays.count, 7)
        XCTAssertEqual(summary.recentDays.last?.date, Calendar.current.startOfDay(for: now))
        // last7Seconds 应该等于 recentDays 全部 seconds 之和
        let sum = summary.recentDays.reduce(0.0) { $0 + $1.seconds }
        XCTAssertEqual(summary.last7Seconds, sum, accuracy: 1e-6)
    }

    func testListeningSummary_totalIsNonNegative() {
        let s = library.listeningSummary()
        XCTAssertGreaterThanOrEqual(s.totalSeconds, 0)
        XCTAssertGreaterThanOrEqual(s.todaySeconds, 0)
        XCTAssertGreaterThanOrEqual(s.monthSeconds, 0)
        XCTAssertGreaterThanOrEqual(s.streakDays, 0)
    }

    func testListeningSummary_monthFinishedIsNotNegative() {
        XCTAssertGreaterThanOrEqual(library.listeningSummary().monthFinished, 0)
    }

    // MARK: - listeningReport

    func testListeningReport_yearMatchesCurrentCalendar() {
        let now = Date()
        let cal = Calendar.current
        let r = library.listeningReport(now: now, calendar: cal)
        XCTAssertEqual(r.year, cal.component(.year, from: now))
        // currentMonth 是 0-based 下标（0 = 1 月）
        XCTAssertEqual(r.currentMonth, cal.component(.month, from: now) - 1)
    }

    func testListeningReport_monthlyAlwaysHasTwelveBuckets() {
        XCTAssertEqual(library.listeningReport().monthly.count, 12)
    }

    func testListeningReport_daysAndFinishedAreNonNegative() {
        let r = library.listeningReport()
        XCTAssertGreaterThanOrEqual(r.daysListened, 0)
        XCTAssertGreaterThanOrEqual(r.booksFinished, 0)
        XCTAssertGreaterThanOrEqual(r.totalSeconds, 0)
    }

    func testListeningReport_monthlySumEqualsTotalForThatYear() {
        // monthlySeconds 与 seconds(in: yearKey) 是两种口径下的同一年：
        // 前者逐月分桶求和，后者一年前缀扫；两个数字应该一致（浮点累加允许小误差）
        let now = Date()
        let cal = Calendar.current
        let year = cal.component(.year, from: now)
        let monthlySum = library.listening.monthlySeconds(inYear: year).reduce(0, +)
        let yearSum = library.listening.seconds(in: ListeningStats.yearKey(now, calendar: cal))
        XCTAssertEqual(monthlySum, yearSum, accuracy: 1e-6)
    }
}

/// PlaybackSettings.shared 是启动即建的 @MainActor 单例；两个 setter 都写 UserDefaults
/// 并触发副作用（VoiceTap.setEnabled + PassthroughSubject 广播）。测试关心的是「读写对齐、
/// 幂等、脏值兜底」三条契约；副作用留给 UI 集成用例。
@MainActor
final class PlaybackSettingsTests: XCTestCase {
    override func tearDown() {
        // 复原默认，别把默认关闭的状态改坏给后续测试
        PlaybackSettings.shared.setSilenceMode(.off)
        PlaybackSettings.shared.setVoiceBoost(false)
        super.tearDown()
    }

    func testSilenceMode_roundtrip() {
        for mode in SilenceSkipMode.allCases {
            PlaybackSettings.shared.setSilenceMode(mode)
            XCTAssertEqual(PlaybackSettings.shared.silenceMode, mode)
        }
    }

    func testVoiceBoost_roundtrip() {
        PlaybackSettings.shared.setVoiceBoost(true)
        XCTAssertTrue(PlaybackSettings.shared.voiceBoost)
        PlaybackSettings.shared.setVoiceBoost(false)
        XCTAssertFalse(PlaybackSettings.shared.voiceBoost)
    }

    func testSilenceMode_setSameTwiceIsIdempotent() {
        PlaybackSettings.shared.setSilenceMode(.standard)
        PlaybackSettings.shared.setSilenceMode(.standard)
        XCTAssertEqual(PlaybackSettings.shared.silenceMode, .standard)
    }

    func testUserDefaultsKeys_areStable() {
        // 存了偏好就走这两个键；改名会让老用户的偏好丢
        PlaybackSettings.shared.setSilenceMode(.heavy)
        XCTAssertNotNil(UserDefaults.standard.object(forKey: "playback.silenceSkipMode"))
        XCTAssertEqual(UserDefaults.standard.object(forKey: "playback.silenceSkipMode") as? Int,
                       SilenceSkipMode.heavy.rawValue)
        PlaybackSettings.shared.setVoiceBoost(true)
        XCTAssertEqual(UserDefaults.standard.bool(forKey: "playback.voiceBoost"), true)
    }
}
