import Foundation

/// 界面文案取词：键就是英文原文（源语言 en），其他语言的译文在 Support/Localizable.xcstrings。
/// 未提供译文的语言自动回退显示英文键本身。
/// 当前语言由启动时的 AppleLanguages 决定，App 内切换后要重启才生效。
func L(_ key: String) -> String {
    NSLocalizedString(key, bundle: .main, comment: "")
}

/// 带参数的取词：键里用 %@ / %d 占位，多个参数用 %1$@ 这类位置标记
func LF(_ key: String, _ args: CVarArg...) -> String {
    String(format: L(key), arguments: args)
}

/// App 内可切换的语言。code 是要写进 AppleLanguages 的标识，
/// nativeName 一律用该语言自己的文字书写（不随界面语言变化），和本机语言列表的观感一致
struct AppLanguage: Identifiable, Hashable {
    let code: String
    let nativeName: String
    var id: String { code }
}

/// 语言偏好的读写：AppleLanguages 写在 App 自己的 UserDefaults 里，
/// 与「系统设置 → Sonux → 语言」是同一个键，两边改动互相可见
enum AppLanguageSetting {
    /// 对标 iOS 给第三方 App 开放的语言清单（34 种）
    static let all: [AppLanguage] = [
        AppLanguage(code: "ar", nativeName: "العربية"),
        AppLanguage(code: "ca", nativeName: "Català"),
        AppLanguage(code: "hr", nativeName: "Hrvatski"),
        AppLanguage(code: "cs", nativeName: "Čeština"),
        AppLanguage(code: "da", nativeName: "Dansk"),
        AppLanguage(code: "nl", nativeName: "Nederlands"),
        AppLanguage(code: "en", nativeName: "English"),
        AppLanguage(code: "fi", nativeName: "Suomi"),
        AppLanguage(code: "fr", nativeName: "Français"),
        AppLanguage(code: "de", nativeName: "Deutsch"),
        AppLanguage(code: "el", nativeName: "Ελληνικά"),
        AppLanguage(code: "he", nativeName: "עברית"),
        AppLanguage(code: "hi", nativeName: "हिन्दी"),
        AppLanguage(code: "hu", nativeName: "Magyar"),
        AppLanguage(code: "id", nativeName: "Bahasa Indonesia"),
        AppLanguage(code: "it", nativeName: "Italiano"),
        AppLanguage(code: "ja", nativeName: "日本語"),
        AppLanguage(code: "ko", nativeName: "한국어"),
        AppLanguage(code: "ms", nativeName: "Bahasa Melayu"),
        AppLanguage(code: "nb", nativeName: "Norsk bokmål"),
        AppLanguage(code: "pl", nativeName: "Polski"),
        AppLanguage(code: "pt-BR", nativeName: "Português (Brasil)"),
        AppLanguage(code: "pt-PT", nativeName: "Português"),
        AppLanguage(code: "ro", nativeName: "Română"),
        AppLanguage(code: "ru", nativeName: "Русский"),
        AppLanguage(code: "sk", nativeName: "Slovenčina"),
        AppLanguage(code: "es", nativeName: "Español"),
        AppLanguage(code: "sv", nativeName: "Svenska"),
        AppLanguage(code: "th", nativeName: "ไทย"),
        AppLanguage(code: "tr", nativeName: "Türkçe"),
        AppLanguage(code: "uk", nativeName: "Українська"),
        AppLanguage(code: "vi", nativeName: "Tiếng Việt"),
        AppLanguage(code: "zh-Hans", nativeName: "简体中文"),
        AppLanguage(code: "zh-Hant", nativeName: "繁體中文"),
    ]

    /// 按界面语言排序时用的本地化名称序（中文环境出中文拼音序，英文环境出字母序）
    static var sortedByLocalizedName: [AppLanguage] {
        all.sorted { $0.nativeName.localizedStandardCompare($1.nativeName) == .orderedAscending }
    }

    /// 当前是否有 App 级语言覆盖（「系统设置 → Sonux → 语言」改过也算）。
    /// 不能用 UserDefaults.standard 读：系统启动时会把解析后的 AppleLanguages 注入
    /// argument domain，那样永远读得到值；CFPreferencesCopyValue 只读指定域，不做回退
    static var overrideCode: String? {
        guard let bundleId = Bundle.main.bundleIdentifier else { return nil }
        let value = CFPreferencesCopyValue("AppleLanguages" as CFString, bundleId as CFString, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        return (value as? [String])?.first
    }

    static var followsSystem: Bool { overrideCode == nil }

    /// 本次启动实际生效的语言（Bundle 解析结果，跟随系统时即系统首选语言）
    static var effectiveCode: String {
        Bundle.main.preferredLocalizations.first ?? "en"
    }

    /// 清掉覆盖后系统将解析出的语言：按系统语言列表逐个与支持清单做前缀匹配
    static var systemResolvedCode: String {
        let supported = all.map(\.code)
        for preferred in Locale.preferredLanguages {
            if let hit = supported.first(where: { preferred == $0 || preferred.hasPrefix("\($0)-") }) {
                return hit
            }
        }
        return "en"
    }

    /// 写入（或删除）语言偏好，下次启动生效
    static func select(_ code: String?) {
        if let code {
            UserDefaults.standard.set([code], forKey: "AppleLanguages")
        } else {
            UserDefaults.standard.removeObject(forKey: "AppleLanguages")
        }
        UserDefaults.standard.synchronize()
    }
}
