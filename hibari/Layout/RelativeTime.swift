import Foundation

enum ElapsedStyle: Hashable, Sendable {
    /// "30秒", "5分", "13時間", "2日". Days go on past a week ("8日") in a slot laid out in
    /// this style, until the note is laid out again.
    case relative
    /// "9月20日", for a week and older.
    case date
    /// "2025年9月20日", for dates before this year.
    case dateWithYear
}

enum RelativeTime {
    private static let calendar = Calendar(identifier: .gregorian)

    static func format(_ date: Date, now: Date) -> String {
        format(date, now: now, style: style(for: date, now: now))
    }

    static func format(_ date: Date, now: Date, style: ElapsedStyle) -> String {
        switch style {
        case .relative:
            let seconds = max(0, now.timeIntervalSince(date))
            if seconds < 60 { return "\(Int(seconds))秒" }
            if seconds < 3600 { return "\(Int(seconds / 60))分" }
            if seconds < 86400 { return "\(Int(seconds / 3600))時間" }
            return "\(Int(seconds / 86400))日"
        case .date, .dateWithYear:
            let c = calendar.dateComponents([.year, .month, .day], from: date)
            guard let year = c.year, let month = c.month, let day = c.day else { return "" }
            return style == .dateWithYear ? "\(year)年\(month)月\(day)日" : "\(month)月\(day)日"
        }
    }

    /// The style `format(_:now:)` uses at `now`.
    static func style(for date: Date, now: Date) -> ElapsedStyle {
        if now.timeIntervalSince(date) < 7 * 86400 { return .relative }
        let showsYear = calendar.component(.year, from: date) != calendar.component(.year, from: now)
        return showsYear ? .dateWithYear : .date
    }

    /// When `format(date, now:)` returns a different label next. Dates are treated as
    /// fixed.
    static func nextChange(_ date: Date, now: Date) -> Date {
        nextChange(date, now: now, style: style(for: date, now: now))
    }

    static func nextChange(_ date: Date, now: Date, style: ElapsedStyle) -> Date {
        guard style == .relative else { return .distantFuture }
        let seconds = max(0, now.timeIntervalSince(date))
        let unit: TimeInterval = seconds < 60 ? 1 : seconds < 3600 ? 60 : seconds < 86400 ? 3600 : 86400
        return date.addingTimeInterval(((seconds / unit).rounded(.down) + 1) * unit)
    }

    /// "3日", "5時間", "10分" for a remaining duration.
    static func duration(_ seconds: TimeInterval) -> String {
        if seconds >= 86400 { return "\(Int(seconds / 86400))日" }
        if seconds >= 3600 { return "\(Int(seconds / 3600))時間" }
        return "\(max(1, Int(seconds / 60)))分"
    }

    /// How long until `duration(remaining)` changes (or the remaining time runs out).
    static func durationNextChange(_ remaining: TimeInterval) -> TimeInterval {
        guard remaining > 0 else { return .infinity }
        guard remaining >= 120 else { return remaining }
        let unit: TimeInterval = remaining >= 86400 ? 86400 : remaining >= 3600 ? 3600 : 60
        return remaining.truncatingRemainder(dividingBy: unit)
    }
}
