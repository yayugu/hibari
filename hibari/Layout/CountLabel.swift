import Foundation

enum CountLabel {
    static func format(_ value: Int) -> String {
        guard value >= 10_000 else { return String(value) }
        let man = Double(value) / 10_000
        return man < 100 ? String(format: "%.1f万", man) : "\(value / 10_000)万"
    }
}
