import XCTest
@testable import Sonux

/// SilenceSkipMode 是一个 4 case 枚举 + UserDefaults 反解兜底：
/// 覆盖 rawValue 分布、minGap 阈值、labelKey（本地化键）和「脏值一律回退到 off」的容错。
final class SilenceSkipModeTests: XCTestCase {
    func testCaseIterable_coversFourRawValues() {
        XCTAssertEqual(SilenceSkipMode.allCases.map(\.rawValue), [0, 1, 2, 3])
    }

    func testId_matchesRawValue() {
        for mode in SilenceSkipMode.allCases {
            XCTAssertEqual(mode.id, mode.rawValue)
        }
    }

    func testMinGap_byCase() {
        XCTAssertNil(SilenceSkipMode.off.minGap)
        XCTAssertEqual(SilenceSkipMode.light.minGap, 3.0)
        XCTAssertEqual(SilenceSkipMode.standard.minGap, 1.8)
        XCTAssertEqual(SilenceSkipMode.heavy.minGap, 1.0)
    }

    func testLabelKeys_areStableLocalizationKeys() {
        // 这四个键是 Localizable.xcstrings 里的原样键；改字符串会砸到本地化匹配
        XCTAssertEqual(SilenceSkipMode.off.labelKey, "Off")
        XCTAssertEqual(SilenceSkipMode.light.labelKey, "Light")
        XCTAssertEqual(SilenceSkipMode.standard.labelKey, "Standard")
        XCTAssertEqual(SilenceSkipMode.heavy.labelKey, "Heavy")
    }

    // MARK: - UserDefaults 反解

    func testInitFromUserDefaults_nilBecomesOff() {
        XCTAssertEqual(SilenceSkipMode(rawUserDefaultsValue: nil), .off)
    }

    func testInitFromUserDefaults_validIntsMapToCases() {
        XCTAssertEqual(SilenceSkipMode(rawUserDefaultsValue: 0), .off)
        XCTAssertEqual(SilenceSkipMode(rawUserDefaultsValue: 1), .light)
        XCTAssertEqual(SilenceSkipMode(rawUserDefaultsValue: 2), .standard)
        XCTAssertEqual(SilenceSkipMode(rawUserDefaultsValue: 3), .heavy)
    }

    func testInitFromUserDefaults_outOfRangeBecomesOff() {
        // 未来 case 被删掉、旧数据留着的场景：越界 rawValue 一律回退到 off，不能崩
        XCTAssertEqual(SilenceSkipMode(rawUserDefaultsValue: -1), .off)
        XCTAssertEqual(SilenceSkipMode(rawUserDefaultsValue: 4), .off)
        XCTAssertEqual(SilenceSkipMode(rawUserDefaultsValue: 999), .off)
    }

    func testInitFromUserDefaults_wrongTypeBecomesOff() {
        // 有人把 plist 改坏成字符串/布尔：`value as? Int` 应失败，兜底为 .off
        XCTAssertEqual(SilenceSkipMode(rawUserDefaultsValue: "1"), .off)
        XCTAssertEqual(SilenceSkipMode(rawUserDefaultsValue: true), .off)
        XCTAssertEqual(SilenceSkipMode(rawUserDefaultsValue: 1.5), .off)
    }
}
