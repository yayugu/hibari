/// Notes not fetched yet between two parts of a list: a refresh brought more new notes
/// than it asked for. The edges are the ids of the entries fetched next to it (maybe not
/// shown: hidden or duplicates), exclusive.
struct TimelineGap: Sendable, Equatable {
    /// Stays the same while the gap shrinks.
    let id: Int
    /// The oldest entry fetched above it: `untilId` when filling it from above.
    var newerID: String
    /// The newest entry fetched below it: `sinceId` when filling it from below.
    var olderID: String
    var failed = false
}

struct TimelineEntries: Sendable {
    private(set) var items: [TimelineItem] = []
    private(set) var layouts: [NoteLayout] = []
    /// Newest first.
    private(set) var gaps: [TimelineGap] = []
    private var indexByID: [String: Int] = [:]
    private var shownNoteIDs: Set<String> = []
    private var nextGapID = 1

    var count: Int { items.count }
    var isEmpty: Bool { items.isEmpty }

    func contains(_ noteID: String) -> Bool {
        indexByID[noteID] != nil
    }

    /// Whether the list shows the note `item` shows (see `TimelineItem.shownNoteID`).
    func showsNote(of item: TimelineItem) -> Bool {
        item.shownNoteID.map(shownNoteIDs.contains) ?? false
    }

    /// The notes shown (renoted ones for renotes), for `TimelineItem.shownNoteID`.
    var shownNotes: Set<String> { shownNoteIDs }

    func gap(_ id: Int) -> TimelineGap? {
        gaps.first { $0.id == id }
    }

    /// Where `gap` is: after the item at the index, -1 above them all.
    func position(of gap: TimelineGap) -> Int {
        var low = 0
        var high = items.count
        while low < high {
            let mid = (low + high) / 2
            if items[mid].id > gap.olderID {
                low = mid + 1
            } else {
                high = mid
            }
        }
        return low - 1
    }

    var gapPlacements: [TimelineCollectionLayout.GapPlacement] {
        gaps.map { TimelineCollectionLayout.GapPlacement(id: $0.id, afterItem: position(of: $0)) }
    }

    func index(of noteID: String) -> Int? {
        indexByID[noteID]
    }

    /// Changes a note's display state. Its layout is out of date until laid out again.
    mutating func updateState(at index: Int, _ update: (inout NoteDisplayState) -> Void) {
        update(&items[index].state)
    }

    /// Applies the user's change (a reaction, a renote) to every note that shows the note
    /// it is about (itself, a renote of it, a quote or a reply). Returns whether any
    /// changed; their layouts are out of date until laid out again.
    @discardableResult
    mutating func apply(_ change: some NoteChange) -> Bool {
        var changed = false
        for index in items.indices {
            guard let item = items[index].applying(change) else { continue }
            items[index] = item
            changed = true
        }
        return changed
    }

    private func fresh(_ newItems: [TimelineItem], _ newLayouts: [NoteLayout]) -> [(TimelineItem, NoteLayout)] {
        precondition(newItems.count == newLayouts.count)
        var ids = Set<String>()
        var notes = Set<String>()
        return zip(newItems, newLayouts).filter { item, _ in
            guard indexByID[item.id] == nil, !showsNote(of: item), ids.insert(item.id).inserted else { return false }
            return item.shownNoteID.map { notes.insert($0).inserted } ?? true
        }
    }

    /// Appends the notes that are not in the timeline yet. Returns the new indices.
    @discardableResult
    mutating func append(_ newItems: [TimelineItem], layouts newLayouts: [NoteLayout]) -> Range<Int> {
        let start = items.count
        for (item, layout) in fresh(newItems, newLayouts) {
            indexByID[item.id] = items.count
            if let note = item.shownNoteID { shownNoteIDs.insert(note) }
            items.append(item)
            layouts.append(layout)
        }
        return start..<items.count
    }

    /// Puts the notes that are not in the timeline yet in front (newer notes). Returns how
    /// many were added; indices of the existing notes move up by that much. `gapBelow`:
    /// the refresh did not reach the notes shown so far; notes between these ids are
    /// missing below the new ones.
    @discardableResult
    mutating func prepend(_ newItems: [TimelineItem], layouts newLayouts: [NoteLayout],
                          gapBelow: (newerID: String, olderID: String)? = nil) -> Int {
        let fresh = fresh(newItems, newLayouts)
        if let gapBelow {
            addGap(newerID: gapBelow.newerID, olderID: gapBelow.olderID)
        }
        guard !fresh.isEmpty else { return 0 }
        items = fresh.map(\.0) + items
        layouts = fresh.map(\.1) + layouts
        rebuildIndex()
        return fresh.count
    }

    /// Puts notes fetched for `gapID` in it: `fromNewer`, the ones right below its upper
    /// edge (newest first), else the ones right above its lower edge. `edge`: the entry
    /// fetched farthest into the gap, its new edge. `closes`: the fetch reached the other
    /// side; the gap goes. Returns the new indices.
    @discardableResult
    mutating func fill(_ gapID: Int, with newItems: [TimelineItem], layouts newLayouts: [NoteLayout],
                       fromNewer: Bool, edge: String?, closes: Bool) -> Range<Int> {
        guard let gapIndex = gaps.firstIndex(where: { $0.id == gapID }) else { return 0..<0 }
        let gap = gaps[gapIndex]
        let fresh = fresh(newItems, newLayouts).filter { $0.0.id > gap.olderID && $0.0.id < gap.newerID }
        let start = position(of: gap) + 1
        items.insert(contentsOf: fresh.map(\.0), at: start)
        layouts.insert(contentsOf: fresh.map(\.1), at: start)
        rebuildIndex()
        if let edge, !closes, edge > gap.olderID, edge < gap.newerID {
            if fromNewer {
                gaps[gapIndex].newerID = edge
            } else {
                gaps[gapIndex].olderID = edge
            }
            gaps[gapIndex].failed = false
        } else {
            gaps.remove(at: gapIndex)
        }
        mergeGaps()
        return start..<(start + fresh.count)
    }

    mutating func setFailed(_ failed: Bool, gap gapID: Int) {
        guard let index = gaps.firstIndex(where: { $0.id == gapID }) else { return }
        gaps[index].failed = failed
    }

    /// A gap with nothing below it any more (those notes were deleted): it is where the
    /// list goes on, not a gap. Taken out and returned.
    mutating func removeTrailingGap() -> TimelineGap? {
        guard let last = gaps.last, position(of: last) == items.count - 1 else { return nil }
        return gaps.removeLast()
    }

    mutating func restore(_ newItems: [TimelineItem], layouts newLayouts: [NoteLayout],
                          gaps saved: [(newerID: String, olderID: String)]) {
        let nextGapID = self.nextGapID
        self = TimelineEntries()
        self.nextGapID = nextGapID
        append(newItems, layouts: newLayouts)
        for gap in saved {
            addGap(newerID: gap.newerID, olderID: gap.olderID)
        }
    }

    private mutating func addGap(newerID: String, olderID: String) {
        guard newerID > olderID else { return }
        gaps.append(TimelineGap(id: nextGapID, newerID: newerID, olderID: olderID))
        nextGapID += 1
        mergeGaps()
    }

    private mutating func mergeGaps() {
        gaps.sort { $0.newerID > $1.newerID }
        var merged: [TimelineGap] = []
        for gap in gaps {
            if var previous = merged.last, position(of: previous) == position(of: gap) {
                previous.olderID = min(previous.olderID, gap.olderID)
                previous.failed = false
                merged[merged.count - 1] = previous
            } else {
                merged.append(gap)
            }
        }
        gaps = merged
    }

    private mutating func rebuildIndex() {
        indexByID = Dictionary(uniqueKeysWithValues: items.enumerated().map { ($1.id, $0) })
        shownNoteIDs = Set(items.compactMap(\.shownNoteID))
    }

    /// Puts newer versions of entries in their place (a group of notifications that grew),
    /// keeping their display state. Their layouts are out of date until laid out again.
    mutating func replace(_ newer: [TimelineItem]) {
        for item in newer {
            guard let index = indexByID[item.id] else { continue }
            var item = item
            item.state = items[index].state
            items[index] = item
        }
    }

    /// Takes out a deleted note and what the server deletes with it (see
    /// `TimelineItem.isGone(afterDeleting:)`). Returns where they were, in order; the
    /// notes after them move up.
    mutating func remove(deleted noteID: String) -> [Int] {
        removeAll { $0.isGone(afterDeleting: noteID) }
    }

    /// Takes out what muting or blocking the user leaves out (see
    /// `TimelineItem.involves(user:)`). Returns where they were, in order.
    mutating func remove(involving userID: String) -> [Int] {
        removeAll { $0.involves(user: userID) }
    }

    private mutating func removeAll(where isGone: (TimelineItem) -> Bool) -> [Int] {
        let gone = items.indices.filter { isGone(items[$0]) }
        guard !gone.isEmpty else { return [] }
        for index in gone.reversed() {
            items.remove(at: index)
            layouts.remove(at: index)
        }
        rebuildIndex()
        mergeGaps()
        return gone
    }

    mutating func replaceAll(with newItems: [TimelineItem], layouts newLayouts: [NoteLayout]) {
        restore(newItems, layouts: newLayouts, gaps: [])
    }

    /// The notes whose layout is out of date: its key is not the one `expectedKey` gives
    /// now, or it guessed the size of an emoji that has loaded since.
    ///
    /// Split in two: changes that happen by themselves (an emoji size arriving, dates
    /// gaining their year) must not move a note the user is looking at, so notes in
    /// `onScreen` wait (`deferred`) until they leave the screen. Changes of content,
    /// display state or context are laid out right away (`now`).
    func staleIndices(
        onScreen: Set<Int>,
        expectedKey: (TimelineItem) -> LayoutKey,
        emojiSizesAreCurrent: (NoteLayout) -> Bool
    ) -> (now: [Int], deferred: [Int]) {
        var now: [Int] = []
        var deferred: [Int] = []
        for index in items.indices {
            let layout = layouts[index]
            let expected = expectedKey(items[index])
            let isUrgent: Bool
            if layout.key != expected {
                isUrgent = expected.requiresImmediateRelayout(from: layout.key)
            } else if !emojiSizesAreCurrent(layout) {
                isUrgent = false
            } else {
                continue
            }
            if isUrgent || !onScreen.contains(index) {
                now.append(index)
            } else {
                deferred.append(index)
            }
        }
        return (now, deferred)
    }

    /// Swaps in each fresh layout whose key is the one its note expects now
    /// (`expectedKey`). Results that went stale while they were computed (the context
    /// changed), notes no longer in the timeline, and changes that must wait because the
    /// note is in `onScreen` (see `staleIndices`) are skipped. Returns the indices that
    /// changed.
    mutating func integrate(
        _ fresh: [NoteLayout],
        onScreen: Set<Int>,
        expectedKey: (TimelineItem) -> LayoutKey
    ) -> [Int] {
        var changed: [Int] = []
        for layout in fresh {
            guard let index = indexByID[layout.key.noteID],
                  layout.serial != layouts[index].serial,
                  layout.key == expectedKey(items[index]),
                  !onScreen.contains(index) || layout.key.requiresImmediateRelayout(from: layouts[index].key)
            else { continue }
            layouts[index] = layout
            changed.append(index)
        }
        return changed.sorted()
    }
}
