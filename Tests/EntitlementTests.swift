import XCTest
import SwiftUI
@testable import Sonux

/// 付费判定：7 天试用只开收听报告，播放控制层只有 Pro 才有，没 Pro 的人每天只给 30 分钟。
/// 商店那条链在测试宿主里是空的（没配 StoreKit 文件），所以这里只摆日期、秒数与「买没买断」
final class EntitlementPolicyTests: XCTestCase {
    private let day: TimeInterval = 24 * 60 * 60
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    func testTrialRunsSevenDays() {
        XCTAssertEqual(EntitlementPolicy.trialDuration, 7 * 24 * 60 * 60)
        for offset in 0..<7 {
            XCTAssertTrue(EntitlementPolicy.inTrial(trialStart: start,
                                                    now: start.addingTimeInterval(Double(offset) * day)),
                          "试用第 \(offset + 1) 天该开着报告")
        }
    }

    func testTrialEndsTheMomentItTurnsSevenDays() {
        // 边界不留给「差不多」：满 7 天那一刻起报告就锁
        XCTAssertFalse(EntitlementPolicy.inTrial(trialStart: start,
                                                 now: start.addingTimeInterval(7 * day)))
        XCTAssertFalse(EntitlementPolicy.inTrial(trialStart: start,
                                                 now: start.addingTimeInterval(400 * day)))
    }

    func testClockSkewBeforeTrialStartStillCountsAsTrialing() {
        // 系统时间被拨回试用起点之前：elapsed 是负数，照样算试用中，不该反倒锁住
        XCTAssertTrue(EntitlementPolicy.inTrial(trialStart: start,
                                                now: start.addingTimeInterval(-3 * day)))
    }

    func testTrialDaysLeftRoundsPartialDayUp() {
        // 还剩 1 天半要说「2 天」，说 1 天会让人以为明天不收钱就还有后天
        XCTAssertEqual(EntitlementPolicy.trialDaysLeft(trialStart: start,
                                                       now: start.addingTimeInterval(5.5 * day)), 2)
        XCTAssertEqual(EntitlementPolicy.trialDaysLeft(trialStart: start, now: start), 7)
        XCTAssertEqual(EntitlementPolicy.trialDaysLeft(trialStart: start,
                                                       now: start.addingTimeInterval(6.99 * day)), 1)
        XCTAssertNil(EntitlementPolicy.trialDaysLeft(trialStart: start,
                                                     now: start.addingTimeInterval(7 * day)))
    }

    func testDailyCapIsThirtyMinutes() {
        XCTAssertEqual(EntitlementPolicy.dailyFreeSeconds, 30 * 60)
        XCTAssertFalse(EntitlementPolicy.capReached(todaySeconds: 1799))
        XCTAssertTrue(EntitlementPolicy.capReached(todaySeconds: 1800))
        XCTAssertTrue(EntitlementPolicy.capReached(todaySeconds: 5000))
    }

    func testDayKeyGroupsByLocalCalendarDay() {
        let now = Date()
        XCTAssertEqual(EntitlementPolicy.dayKey(now), EntitlementPolicy.dayKey(now))
        XCTAssertNotEqual(EntitlementPolicy.dayKey(now),
                          EntitlementPolicy.dayKey(now.addingTimeInterval(24 * 60 * 60)))
    }
}

@MainActor
final class EntitlementGateTests: XCTestCase {
    private let day: TimeInterval = 24 * 60 * 60

    /// 造一个状态定死的实例：试用起点在 days 之前
    private func service(trialDaysAgo days: Double, purchased: Bool = false,
                         subscribed: Bool = false) -> EntitlementService {
        EntitlementService.forTests(trialStart: Date().addingTimeInterval(-days * day),
                                    purchased: purchased, subscribed: subscribed)
    }

    // MARK: - 两类闸门

    func testPlaybackControlsNeedProNotTrial() {
        // 语速、定时、音量、跳过静音与增强：试用期内也不放行
        let trialing = service(trialDaysAgo: 2)
        XCTAssertFalse(trialing.isPro)
        var ran = false
        trialing.gatePro { ran = true }
        XCTAssertFalse(ran)
        XCTAssertTrue(trialing.isPaywallPresented)
    }

    func testReportOpensDuringTrial() {
        let trialing = service(trialDaysAgo: 2)
        var ran = false
        trialing.gateReport { ran = true }
        XCTAssertTrue(ran)
        XCTAssertFalse(trialing.isPaywallPresented)
    }

    func testReportLocksAfterTrial() {
        let expired = service(trialDaysAgo: 8)
        var ran = false
        expired.gateReport { ran = true }
        XCTAssertFalse(ran, "试用过了，收听报告该上锁")
        XCTAssertTrue(expired.isPaywallPresented)
    }

    func testBothGatesRunForSubscribers() {
        // 订阅与买断同权：两类入口都放行
        let subscriber = service(trialDaysAgo: 400, subscribed: true)
        XCTAssertTrue(subscriber.isPro)
        var pro = false
        var report = false
        subscriber.gatePro { pro = true }
        subscriber.gateReport { report = true }
        XCTAssertTrue(pro)
        XCTAssertTrue(report)
    }

    // MARK: - 买断页上承诺了什么

    func testPaywallPromisesOnlyDeliverableFeatures() {
        // 这张表只摆「掏了钱就一定拿得到」的四项。字幕、整章文案页、逐句搜索与摘录卡片
        // 都不在内：App 里没有让用户拿到字幕的办法，把它们写成权益就是拿开发环境里
        // 跑得通的东西卖钱。跳过静音也不在——它的静音地图来自字幕（见 SilenceGaps）。
        XCTAssertEqual(PaywallView().rows.map(\.feature),
                       [L("Listening Time"), L("Speed, Volume & Sleep Timer"),
                        L("Voice Boost"), L("Listening Report")],
                       "买断页多了一行，得先回答：用户在自己导入的书上真拿得到这一行吗？")
    }

    func testTrialDaysLeftQuietAfterPro() {
        XCTAssertEqual(service(trialDaysAgo: 2).trialDaysLeft, 5)
        XCTAssertNil(service(trialDaysAgo: 2, purchased: true).trialDaysLeft)
        XCTAssertNil(service(trialDaysAgo: 2, subscribed: true).trialDaysLeft)
    }

    // MARK: - 每日 30 分钟

    func testListeningIsMeteredFromInstallEvenDuringTrial() {
        // 装上就计，试用期也计：30 分钟一到就报
        let entitlement = service(trialDaysAgo: 1)
        XCTAssertTrue(entitlement.isMetered)
        seedUsage(day: EntitlementPolicy.dayKey(Date()), seconds: 1700)
        XCTAssertFalse(entitlement.recordListening(60), "1760 秒还没到 30 分钟")
        XCTAssertTrue(entitlement.recordListening(60), "1820 秒跨过上限，正好这一次该报")
        XCTAssertTrue(entitlement.dailyCapReached)
        XCTAssertEqual(entitlement.timeLeftToday, 0)
    }

    func testCapIsReportedOnlyOnce() {
        let entitlement = service(trialDaysAgo: 1)
        seedUsage(day: EntitlementPolicy.dayKey(Date()), seconds: 2000)
        entitlement.recordListening(30)
        XCTAssertFalse(entitlement.recordListening(30), "今天已经报过，别每秒再弹一次买断页")
    }

    func testUsageResetsOnANewLocalDay() {
        let entitlement = service(trialDaysAgo: 1)
        let yesterday = EntitlementPolicy.dayKey(Date().addingTimeInterval(-24 * 60 * 60))
        seedUsage(day: yesterday, seconds: 9000)
        XCTAssertFalse(entitlement.recordListening(10), "昨天听超了不该欠到今天")
        XCTAssertEqual(UserDefaults.standard.double(forKey: EntitlementPolicy.usageSecondsKey), 10)
    }

    func testProIsNotMetered() {
        let entitlement = service(trialDaysAgo: 400, purchased: true)
        XCTAssertFalse(entitlement.isMetered)
        XCTAssertFalse(entitlement.recordListening(99_999))
        XCTAssertNil(entitlement.timeLeftToday, "Pro 没有「还剩多少」这回事")
    }

    // MARK: - 开播闸门与跨午夜恢复

    func testDailyCapIsReadLiveSoMidnightReopensPlayback() {
        // 额度用完时闸门是关的；记账那天的键一换（过了午夜）就当场重新放行——
        // 不靠重启，也不能等「再听一笔」去把标志翻回来，那一笔本来就播不出来了
        let entitlement = service(trialDaysAgo: 1)
        seedUsage(day: EntitlementPolicy.dayKey(Date()), seconds: 1_800)
        XCTAssertTrue(entitlement.dailyCapReached)
        seedUsage(day: EntitlementPolicy.dayKey(Date().addingTimeInterval(-day)), seconds: 9_000)
        XCTAssertFalse(entitlement.dailyCapReached, "昨天听超了不欠到今天")
    }

    func testDailyCapNeverClosesForPro() {
        let pro = service(trialDaysAgo: 1, purchased: true)
        seedUsage(day: EntitlementPolicy.dayKey(Date()), seconds: 9_000)
        XCTAssertFalse(pro.dailyCapReached, "买断的人没有每天 30 分钟这回事")
    }

    func testCapAnnouncementReArmsOnANewDay() {
        // 「到点报一次」是当天一次，不是装到过期就再不报：新的一天到点还得停下领人去买断页
        let entitlement = service(trialDaysAgo: 1)
        seedUsage(day: EntitlementPolicy.dayKey(Date()), seconds: 2_000)
        XCTAssertTrue(entitlement.recordListening(30), "跨过上限那一刻该报")
        XCTAssertFalse(entitlement.recordListening(30), "同一天报一次就够")
        seedUsage(day: EntitlementPolicy.dayKey(Date().addingTimeInterval(-day)), seconds: 2_000)
        XCTAssertFalse(entitlement.recordListening(30), "新的一天从 0 计")
        XCTAssertFalse(entitlement.recordListening(1_769), "1799 秒还没到")
        XCTAssertTrue(entitlement.recordListening(1), "新的一天到点照样要报")
    }

    private func seedUsage(day: String, seconds: TimeInterval) {
        UserDefaults.standard.set(day, forKey: EntitlementPolicy.usageDayKey)
        UserDefaults.standard.set(seconds, forKey: EntitlementPolicy.usageSecondsKey)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: EntitlementPolicy.usageDayKey)
        UserDefaults.standard.removeObject(forKey: EntitlementPolicy.usageSecondsKey)
        super.tearDown()
    }
}
