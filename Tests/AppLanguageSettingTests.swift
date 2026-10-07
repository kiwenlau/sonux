import XCTest
@testable import Sonux

/// AppLanguageSetting 与 AppLanguage 是纯数据 + 一个「按本地化名字重排」的辅助方法；
/// 语言清单的 code 与 iOS 系统给第三方 App 开放的 34 种对齐，改一个就要动 xcstrings 与 project.yml。
/// 至于 overrideCode / followsSystem / effectiveCode / select(_:) 都读写 CFPreferences 与
/// UserDefaults，属于系统集成，交给 UI 验收。
final class AppLanguageSettingTests: XCTestCase {
    func testAll_has34Languages() {
        // 与 project.yml: CFBundleLocalizations 一一对应；改一边要同步改另一边
        XCTAssertEqual(AppLanguageSetting.all.count, 34)
    }

    func testAll_codesAreUnique() {
        let codes = AppLanguageSetting.all.map(\.code)
        XCTAssertEqual(Set(codes).count, codes.count, "同一 code 出现两次会让 Picker 选错")
    }

    func testAll_nativeNamesAreUnique() {
        let names = AppLanguageSetting.all.map(\.nativeName)
        XCTAssertEqual(Set(names).count, names.count)
    }

    /// 与 project.yml 里 CFBundleLocalizations 严格对齐（少一个 → 系统不给这个语言；
    /// 多一个 → App 声称支持却没 catalog，兜底显示英文）。
    func testAll_codesMatchBundleLocalizations() throws {
        let expected: Set<String> = [
            "en", "zh-Hans", "zh-Hant", "ja", "ko", "fr", "de", "es",
            "pt-BR", "pt-PT", "it", "ru", "ar", "nl", "sv", "da", "fi", "nb",
            "pl", "tr", "cs", "sk", "hu", "el", "he", "hi", "id", "ms", "ro",
            "uk", "th", "vi", "ca", "hr",
        ]
        XCTAssertEqual(Set(AppLanguageSetting.all.map(\.code)), expected)
    }

    func testAll_containsCommonLanguages() {
        let codes = Set(AppLanguageSetting.all.map(\.code))
        for required in ["en", "zh-Hans", "ja", "ko", "fr", "de", "es"] {
            XCTAssertTrue(codes.contains(required), "少了 \(required)")
        }
    }

    func testId_matchesCode() {
        for lang in AppLanguageSetting.all {
            XCTAssertEqual(lang.id, lang.code)
        }
    }

    func testSortedByLocalizedName_isSortedForCurrentLocale() {
        // 不锁死具体顺序（跟宿主语言走），只验：① 数量对得上；② 每个元素都在 all 里；
        // ③ 相邻两项按 localizedStandardCompare 是升序
        let sorted = AppLanguageSetting.sortedByLocalizedName
        XCTAssertEqual(sorted.count, AppLanguageSetting.all.count)
        XCTAssertEqual(Set(sorted.map(\.code)), Set(AppLanguageSetting.all.map(\.code)))
        for (a, b) in zip(sorted, sorted.dropFirst()) {
            XCTAssertEqual(a.nativeName.localizedStandardCompare(b.nativeName),
                           .orderedAscending,
                           "\(a.nativeName) 应排在 \(b.nativeName) 前")
        }
    }

    func testSystemResolvedCode_alwaysHasResult() {
        // 无论系统首选语言列表是什么，函数必须给一个 supported 里的 code（兜底 en）
        XCTAssertTrue(AppLanguageSetting.all.map(\.code).contains(AppLanguageSetting.systemResolvedCode))
    }
}
