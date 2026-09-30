import UIKit

final class TimelineCollectionLayout: UICollectionViewLayout {
    static let footerKind = "TimelineFooter"
    /// Its index path's item is the gap's id, which stays the same while items come and go.
    static let gapKind = "TimelineGap"
    static let gapHeight: CGFloat = 56

    struct GapPlacement: Equatable {
        let id: Int
        /// The item above it; -1 above them all.
        let afterItem: Int
    }

    private var heights: [CGFloat] = []
    private var offsets: [CGFloat] = []
    private var attributes: [UICollectionViewLayoutAttributes] = []
    private var gaps: [GapPlacement] = []
    private var gapAttributes: [Int: UICollectionViewLayoutAttributes] = [:]
    private var contentHeight: CGFloat = 0
    private var width: CGFloat = 0
    private let footer = UICollectionViewLayoutAttributes(
        forSupplementaryViewOfKind: TimelineCollectionLayout.footerKind, with: IndexPath(item: 0, section: 0))

    /// 0 hides the footer.
    var footerHeight: CGFloat = 0 {
        didSet {
            guard footerHeight != oldValue else { return }
            updateFooter()
            invalidateLayout()
        }
    }

    var minimumContentHeight: CGFloat = 0 {
        didSet {
            guard minimumContentHeight != oldValue else { return }
            invalidateLayout()
        }
    }

    /// `gaps` in order.
    func setHeights(_ newHeights: [CGFloat], gaps newGaps: [GapPlacement] = []) {
        heights = newHeights
        gaps = newGaps
        offsets.removeAll(keepingCapacity: true)
        attributes.removeAll(keepingCapacity: true)
        gapAttributes.removeAll(keepingCapacity: true)
        contentHeight = 0
        appendAttributes(from: 0)
        invalidateLayout()
    }

    func appendHeights(_ more: [CGFloat]) {
        let start = heights.count
        guard !gaps.contains(where: { $0.afterItem >= start - 1 }) else {
            setHeights(heights + more, gaps: gaps)
            return
        }
        heights += more
        appendAttributes(from: start)
        invalidateLayout()
    }

    var gapIDs: [Int] { gaps.map(\.id) }

    func frame(ofGap id: Int) -> CGRect? {
        gapAttributes[id]?.frame
    }

    /// The first item whose bottom is below `y` (it may start below `y` too, after a gap);
    /// nil past the last item.
    func firstItem(endingBelow y: CGFloat) -> Int? {
        let index = firstItem(endingAfter: y)
        return index < offsets.count ? index : nil
    }

    /// Top of the item in content coordinates.
    func offset(ofItem index: Int) -> CGFloat? {
        index < offsets.count ? offsets[index] : nil
    }

    func height(ofItem index: Int) -> CGFloat? {
        index < heights.count ? heights[index] : nil
    }

    /// Items intersecting the vertical range.
    func itemRange(in rect: CGRect) -> Range<Int> {
        guard !offsets.isEmpty else { return 0..<0 }
        let first = firstItem(endingAfter: rect.minY)
        var last = first
        while last < offsets.count && offsets[last] < rect.maxY { last += 1 }
        return first..<last
    }

    private func appendAttributes(from start: Int) {
        var y = contentHeight
        var nextGap = gaps.firstIndex { $0.afterItem >= start - 1 } ?? gaps.endIndex
        func placeGaps(after index: Int) {
            while nextGap < gaps.endIndex, gaps[nextGap].afterItem <= index {
                let gap = UICollectionViewLayoutAttributes(forSupplementaryViewOfKind: Self.gapKind,
                                                           with: IndexPath(item: gaps[nextGap].id, section: 0))
                gap.frame = CGRect(x: 0, y: y, width: width, height: Self.gapHeight)
                gapAttributes[gaps[nextGap].id] = gap
                y += Self.gapHeight
                nextGap += 1
            }
        }
        placeGaps(after: start - 1)
        for index in start..<heights.count {
            let item = UICollectionViewLayoutAttributes(forCellWith: IndexPath(item: index, section: 0))
            item.frame = CGRect(x: 0, y: y, width: width, height: heights[index])
            offsets.append(y)
            attributes.append(item)
            y += heights[index]
            placeGaps(after: index)
        }
        placeGaps(after: .max)
        contentHeight = y
        updateFooter()
    }

    private func updateFooter() {
        footer.frame = CGRect(x: 0, y: contentHeight, width: width, height: footerHeight)
    }

    private func firstItem(endingAfter y: CGFloat) -> Int {
        var low = 0
        var high = offsets.count
        while low < high {
            let mid = (low + high) / 2
            if offsets[mid] + heights[mid] <= y {
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
            for item in attributes {
                item.frame.size.width = width
            }
            for gap in gapAttributes.values {
                gap.frame.size.width = width
            }
            updateFooter()
        }
    }

    override var collectionViewContentSize: CGSize {
        CGSize(width: width, height: max(minimumContentHeight, contentHeight + footerHeight))
    }

    override func layoutAttributesForElements(in rect: CGRect) -> [UICollectionViewLayoutAttributes]? {
        var visible = Array(attributes[itemRange(in: rect)])
        for gap in gaps {
            if let attributes = gapAttributes[gap.id], attributes.frame.intersects(rect) {
                visible.append(attributes)
            }
        }
        if footerHeight > 0 && footer.frame.intersects(rect) {
            visible.append(footer)
        }
        return visible
    }

    override func layoutAttributesForItem(at indexPath: IndexPath) -> UICollectionViewLayoutAttributes? {
        indexPath.item < attributes.count ? attributes[indexPath.item] : nil
    }

    override func layoutAttributesForSupplementaryView(
        ofKind elementKind: String,
        at indexPath: IndexPath
    ) -> UICollectionViewLayoutAttributes? {
        switch elementKind {
        case Self.footerKind:
            return footer
        case Self.gapKind:
            if let gap = gapAttributes[indexPath.item] { return gap }
            let closed = UICollectionViewLayoutAttributes(forSupplementaryViewOfKind: elementKind, with: indexPath)
            closed.isHidden = true
            return closed
        default:
            return nil
        }
    }

    override func shouldInvalidateLayout(forBoundsChange newBounds: CGRect) -> Bool {
        newBounds.width != width
    }
}
