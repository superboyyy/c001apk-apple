import Foundation

enum Formatting {
    private static let sameYear: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "MM月dd日"
        return formatter
    }()

    private static let otherYear: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy年MM月dd日"
        return formatter
    }()

    private static let full: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter
    }()

    /// 移植自 Flutter 端的 `DateUtil.fromToday`。
    static func relative(_ timestamp: Int?) -> String {
        guard let timestamp, timestamp > 0 else { return "" }
        let ago = Int(Date().timeIntervalSince1970) - timestamp
        switch ago {
        case ..<1: return "刚刚"
        case ..<60: return "\(ago)秒前"
        case ...3600: return "\(ago / 60)分钟前"
        case ...86_400: return "\(ago / 3600)小时前"
        case ...2_592_000: return "\(max(ago / 86_400, 1))天前"
        default:
            let date = Date(timeIntervalSince1970: TimeInterval(timestamp))
            let calendar = Calendar.current
            return calendar.component(.year, from: date) == calendar.component(.year, from: Date())
                ? sameYear.string(from: date) : otherYear.string(from: date)
        }
    }

    static func absolute(_ timestamp: Int?) -> String {
        guard let timestamp, timestamp > 0 else { return "" }
        return full.string(from: Date(timeIntervalSince1970: TimeInterval(timestamp)))
    }

    static func relative(_ date: Date) -> String { relative(Int(date.timeIntervalSince1970)) }

    /// 12345 → 1.2万
    static func count(_ value: Int) -> String {
        if value >= 100_000_000 { return String(format: "%.1f亿", Double(value) / 100_000_000) }
        if value >= 10_000 { return String(format: "%.1f万", Double(value) / 10_000) }
        return String(value)
    }
}
