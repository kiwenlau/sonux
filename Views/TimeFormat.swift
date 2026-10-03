import Foundation

enum TimeFormat {
    /// 85 -> "1:25"，3725 -> "1:02:05"
    static func time(_ seconds: TimeInterval) -> String {
        let total = Int(max(0, seconds).rounded())
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        return String(format: "%d:%02d", m, s)
    }

    /// 3660 -> 英文 "1 hr 5 min"，中文 "1 小时 5 分"（按当前语言取词）
    static func duration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        let h = total / 3600
        let m = (total % 3600) / 60
        if h > 0 && m > 0 { return LF("%1$d hr %2$d min", h, m) }
        if h > 0 { return LF("%d hr", h) }
        if m > 0 { return LF("%d min", m) }
        return L("Under 1 min")
    }

    /// 1.0 -> "1"，1.2 -> "1.2"（语速以 0.1 为步进，最多一位小数）
    static func speed(_ value: Float) -> String {
        let rounded = (value * 10).rounded() / 10
        return rounded == rounded.rounded()
            ? String(format: "%.0f", rounded)
            : String(format: "%.1f", rounded)
    }
}
