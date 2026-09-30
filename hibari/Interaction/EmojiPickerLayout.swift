import UIKit

final class EmojiPickerLayout: UICollectionViewLayout {
    struct Metrics: Equatable {
        static let sideInset: CGFloat = 8
        static let headerHeight: CGFloat = 32
        static let sectionSpacing: CGFloat = 12
        static let imageInset: CGFloat = 7
        static let wideImageInset: CGFloat = 3
        /// Wider emojis (width / height) are shrunk to this shape, as in the timeline.
        static let maxAspect: CGFloat = 8

        let columns: Int
        let cellWidth: CGFloat

        init(width: CGFloat) {
            columns = max(6, Int(width / 48))
            cellWidth = max(1, (width - 2 * Self.sideInset) / CGFloat(columns))
        }

        var imageHeight: CGFloat { max(24, cellWidth - 2 * Self.imageInset) }

        /// Columns for an emoji of `aspect` (width / height; 0 if square or not known).
        func span(forAspect aspect: Float) -> Int {
            let width = imageHeight * min(CGFloat(aspect), Self.maxAspect) + 2 * Self.wideImageInset
            return min(columns, max(1, Int((width / cellWidth).rounded(.up))))
        }

        /// A section's item frames, from the top of its first row: in order, left to right,
        /// an emoji that does not fit in what is left of a row starting the next one.
        func itemFrames(aspects: [Float]) -> [CGRect] {
            var frames: [CGRect] = []
            frames.reserveCapacity(aspects.count)
            var column = 0
            var y: CGFloat = 0
            for aspect in aspects {
                let span = aspect > 0 ? span(forAspect: aspect) : 1
                if column + span > columns {
                    column = 0
                    y += cellWidth
                }
                frames.append(CGRect(x: Self.sideInset + CGFloat(column) * cellWidth, y: y,
                                     width: CGFloat(span) * cellWidth, height: cellWidth))
                column += span
            }
            return frames
        }
    }

    private struct SectionFrames {
        var top: CGFloat = 0
        var items: [CGRect]

        var itemsTop: CGFloat { top + Metrics.headerHeight }
        var height: CGFloat { Metrics.headerHeight + (items.last?.maxY ?? 0) + Metrics.sectionSpacing }
    }

    private(set) var metrics = Metrics(width: 0)
    private var width: CGFloat = 0
    private var aspects: [[Float]] = []
    private var sections: [SectionFrames] = []
    private var contentHeight: CGFloat = 0
    private var needsRebuild = true

    /// Every item's aspect ratio (width / height; 0 if square or not known), by section,
    /// for the collection view to reload with.
    func setAspects(_ aspects: [[Float]]) {
        self.aspects = aspects
        needsRebuild = true
        invalidateLayout()
    }

    func aspect(at indexPath: IndexPath) -> Float? {
        guard aspects.indices.contains(indexPath.section),
              aspects[indexPath.section].indices.contains(indexPath.item)
        else { return nil }
        return aspects[indexPath.section][indexPath.item]
    }

    /// The shapes of some emojis became known. The sections whose rows they change are
    /// laid out again, and the first item on screen stays where it is (unless the view is
    /// at the top, where the content just grows downward).
    func updateAspects(_ changes: [IndexPath: Float]) {
        var changed = IndexSet()
        for (indexPath, aspect) in changes {
            guard let old = self.aspect(at: indexPath) else { continue }
            aspects[indexPath.section][indexPath.item] = aspect
            if metrics.span(forAspect: old) != metrics.span(forAspect: aspect) {
                changed.insert(indexPath.section)
            }
        }
        guard let first = changed.first, !needsRebuild, let collectionView else { return }
        let anchor = topItem(in: collectionView)
        for section in changed {
            sections[section].items = metrics.itemFrames(aspects: aspects[section])
        }
        stackSections(from: first)
        let context = UICollectionViewLayoutInvalidationContext()
        if let anchor, let frame = frame(ofItemAt: anchor.indexPath) {
            context.contentOffsetAdjustment.y = clampedOffsetAdjustment(frame.minY - anchor.minY, in: collectionView)
        }
        invalidateLayout(with: context)
    }

    private func rebuild() {
        sections = aspects.map { SectionFrames(items: metrics.itemFrames(aspects: $0)) }
        stackSections(from: 0)
        needsRebuild = false
    }

    private func stackSections(from start: Int) {
        var y = start > 0 ? sections[start - 1].top + sections[start - 1].height : 0
        for index in start..<sections.count {
            sections[index].top = y
            y += sections[index].height
        }
        contentHeight = y
    }

    private func frame(ofItemAt indexPath: IndexPath) -> CGRect? {
        guard sections.indices.contains(indexPath.section) else { return nil }
        let section = sections[indexPath.section]
        guard section.items.indices.contains(indexPath.item) else { return nil }
        return section.items[indexPath.item].offsetBy(dx: 0, dy: section.itemsTop)
    }

    private func topItem(in collectionView: UICollectionView) -> (indexPath: IndexPath, minY: CGFloat)? {
        let top = collectionView.contentOffset.y + collectionView.adjustedContentInset.top
        guard top > 0.5, var index = firstSection(endingAfter: top) else { return nil }
        while index < sections.count {
            let section = sections[index]
            let item = firstItem(in: section.items, endingAfter: top - section.itemsTop)
            if item < section.items.count {
                return (IndexPath(item: item, section: index), section.items[item].minY + section.itemsTop)
            }
            index += 1
        }
        return nil
    }

    private func clampedOffsetAdjustment(_ adjustment: CGFloat, in collectionView: UICollectionView) -> CGFloat {
        let insets = collectionView.adjustedContentInset
        let current = collectionView.contentOffset.y
        let minimum = -insets.top
        let maximum = max(minimum, contentHeight + insets.bottom - collectionView.bounds.height)
        return min(max(current + adjustment, minimum), maximum) - current
    }

    private func firstSection(endingAfter y: CGFloat) -> Int? {
        var low = 0
        var high = sections.count
        while low < high {
            let mid = (low + high) / 2
            if sections[mid].top + sections[mid].height <= y {
                low = mid + 1
            } else {
                high = mid
            }
        }
        return low < sections.count ? low : nil
    }

    private func firstItem(in frames: [CGRect], endingAfter y: CGFloat) -> Int {
        var low = 0
        var high = frames.count
        while low < high {
            let mid = (low + high) / 2
            if frames[mid].maxY <= y {
                low = mid + 1
            } else {
                high = mid
            }
        }
        return low
    }

    override func prepare() {
        super.prepare()
        let newWidth = collectionView?.bounds.width ?? 0
        if newWidth != width {
            width = newWidth
            metrics = Metrics(width: newWidth)
            needsRebuild = true
        }
        if needsRebuild { rebuild() }
    }

    override var collectionViewContentSize: CGSize {
        CGSize(width: width, height: contentHeight)
    }

    override func shouldInvalidateLayout(forBoundsChange newBounds: CGRect) -> Bool {
        newBounds.width != width
    }

    override func layoutAttributesForElements(in rect: CGRect) -> [UICollectionViewLayoutAttributes]? {
        guard var index = firstSection(endingAfter: rect.minY) else { return [] }
        var visible: [UICollectionViewLayoutAttributes] = []
        while index < sections.count, sections[index].top < rect.maxY {
            let section = sections[index]
            if section.itemsTop > rect.minY {
                visible.append(headerAttributes(section: index))
            }
            var item = firstItem(in: section.items, endingAfter: rect.minY - section.itemsTop)
            while item < section.items.count, section.items[item].minY + section.itemsTop < rect.maxY {
                let attributes = UICollectionViewLayoutAttributes(forCellWith: IndexPath(item: item, section: index))
                attributes.frame = section.items[item].offsetBy(dx: 0, dy: section.itemsTop)
                visible.append(attributes)
                item += 1
            }
            index += 1
        }
        return visible
    }

    override func layoutAttributesForItem(at indexPath: IndexPath) -> UICollectionViewLayoutAttributes? {
        guard let frame = frame(ofItemAt: indexPath) else { return nil }
        let attributes = UICollectionViewLayoutAttributes(forCellWith: indexPath)
        attributes.frame = frame
        return attributes
    }

    override func layoutAttributesForSupplementaryView(
        ofKind elementKind: String,
        at indexPath: IndexPath
    ) -> UICollectionViewLayoutAttributes? {
        guard elementKind == UICollectionView.elementKindSectionHeader, sections.indices.contains(indexPath.section)
        else { return nil }
        return headerAttributes(section: indexPath.section)
    }

    private func headerAttributes(section: Int) -> UICollectionViewLayoutAttributes {
        let attributes = UICollectionViewLayoutAttributes(
            forSupplementaryViewOfKind: UICollectionView.elementKindSectionHeader, with: IndexPath(item: 0, section: section))
        attributes.frame = CGRect(x: 0, y: sections[section].top, width: width, height: Metrics.headerHeight)
        return attributes
    }
}
