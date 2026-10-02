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

    /// 3660 -> "1 小时 1 分"
    static func duration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        let h = total / 3600
        let m = (total % 3600) / 60
        if h > 0 && m > 0 { return "\(h) 小时 \(m) 分" }
        if h > 0 { return "\(h) 小时" }
        if m > 0 { return "\(m) 分钟" }
        return "不足 1 分钟"
    }

    /// 紧凑时长：只留最大的一级，3720 -> "1 小时"，300 -> "5 分"，40 -> "40 秒"
    static func compact(_ seconds: TimeInterval) -> String {
        let total = Int(max(0, seconds).rounded())
        let h = total / 3600
        let m = (total % 3600) / 60
        if h > 0 { return "\(h) 小时" }
        if m > 0 { return "\(m) 分" }
        return "\(total) 秒"
    }

    /// 1.0 -> "1"，1.2 -> "1.2"（语速以 0.1 为步进，最多一位小数）
    static func speed(_ value: Float) -> String {
        let rounded = (value * 10).rounded() / 10
        return rounded == rounded.rounded()
            ? String(format: "%.0f", rounded)
            : String(format: "%.1f", rounded)
    }

    /// 剩余时间短语
    static func remaining(_ seconds: TimeInterval) -> String {
        let total = Int(max(0, seconds).rounded())
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 { return "剩 \(h) 小时 \(m) 分" }
        if m > 0 { return "剩 \(m) 分 \(s) 秒" }
        return "剩 \(s) 秒"
    }
}
