import Foundation

/// Keeps a list's rows where they are on screen while something plays on one of them (a
/// button's answer to a tap): no row comes, goes or changes height meanwhile, so the cell
/// playing it stays the same one, in the same place. What a row shows may still change in
/// place. The list takes changes in at once; only showing them waits, and they show
/// together when the last hold ends.
@MainActor
final class ListHold {
    @MainActor
    final class Token {
        fileprivate weak var hold: ListHold?

        /// Lets go of the list. Later calls do nothing.
        func end() {
            let hold = self.hold
            self.hold = nil
            hold?.end()
        }
    }

    /// Shows what waited: runs when the last hold ends, before the holds' `release`s.
    var onRelease: (() -> Void)?
    private var holders = 0
    private var releases: [() -> Void] = []

    var isHeld: Bool { holders > 0 }

    /// Holds the list until `end()` on the token. `release` runs when no hold is left,
    /// after the list shows what waited (to take off what played over its rows).
    func begin(release: @escaping () -> Void = {}) -> Token {
        holders += 1
        releases.append(release)
        let token = Token()
        token.hold = self
        return token
    }

    /// Holds the list for `duration` from now.
    func hold(for duration: TimeInterval, release: @escaping () -> Void = {}) {
        let token = begin(release: release)
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) { token.end() }
    }

    private func end() {
        holders -= 1
        guard holders == 0 else { return }
        let releases = self.releases
        self.releases = []
        onRelease?()
        releases.forEach { $0() }
    }
}
