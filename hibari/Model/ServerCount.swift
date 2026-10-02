import Foundation

/// Server-provided counts are nonnegative. Saturate instead of wrapping on overflow.
enum ServerCount {
    static func adding(_ lhs: Int, _ rhs: Int) -> Int {
        let (sum, overflow) = max(0, lhs).addingReportingOverflow(max(0, rhs))
        return overflow ? Int.max : sum
    }
}

extension Poll {
    var voteTotal: Int { choices.reduce(0) { ServerCount.adding($0, $1.votes) } }

    /// Use floating-point totals for proportions: saturating an integer total would
    /// distort the ratios when several choices have very large counts.
    var voteRatios: [Double] {
        let counts = choices.map { Double(max(0, $0.votes)) }
        let total = counts.reduce(0, +)
        return counts.map { total > 0 ? min(1, max(0, $0 / total)) : 0 }
    }
}
