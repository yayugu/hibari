import Foundation

struct TimelineClock: Sendable {
    private let offset: TimeInterval
    private let frozenAt: Date?

    static let live = TimelineClock(offset: 0, frozenAt: nil)

    #if PERF
    /// Starts at `date` and runs in real time: fixture timelines age like live ones.
    static func starting(at date: Date) -> TimelineClock {
        TimelineClock(offset: date.timeIntervalSinceNow, frozenAt: nil)
    }

    /// Always `date` (benchmarks, so labels never change mid-measurement).
    static func frozen(at date: Date) -> TimelineClock {
        TimelineClock(offset: 0, frozenAt: date)
    }
    #endif

    var isFrozen: Bool { frozenAt != nil }

    func now() -> Date {
        frozenAt ?? Date(timeIntervalSinceNow: offset)
    }
}
