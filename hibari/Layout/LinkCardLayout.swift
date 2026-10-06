import CoreGraphics
import Foundation

/// The card under a note for the page it links to, as X draws it (`LinkCard.Size`). The
/// detail screen's `LinkCardView` draws the same.
enum LinkCardGeometry {
    /// The large card's image: as wide as the note, cropped to this.
    static let aspect: CGFloat = 1.91
    /// The title's band: from the image's bottom left corner, and around the title.
    static let titleInset: CGFloat = 8
    static let titlePadding: CGFloat = 6
    /// The domain under the large card, from its left edge.
    static let domainIndent: CGFloat = 12
    /// Between the image and the domain.
    static let domainSpacing: CGFloat = 4
    /// The small card's image: as wide as this, as tall as the card (at least this).
    static let side: CGFloat = 80
    /// Beside the small card's text, and above and below it at least.
    static let padding: CGFloat = 12
    static let verticalPadding: CGFloat = 10
    /// The icon on the small card's placeholder.
    static let placeholderIcon: CGFloat = 28
}

extension NoteLayoutBuilder {
    /// Lays out the card at `origin` (cell coordinates); returns its height. Tapping it
    /// opens `link`, the URL in the note.
    mutating func linkCard(_ card: LinkCard, link: String, origin: CGPoint, width: CGFloat) -> CGFloat {
        accessibilityAfterTime.append("リンク: \(card.preview.title)、\(card.preview.domain)")
        let image = card.image(revealingSensitiveMedia: context.revealsSensitiveMedia)
        if let image, card.size == .large {
            return largeLinkCard(card.preview, image: image, link: link, origin: origin, width: width)
        }
        return smallLinkCard(card.preview, image: image, link: link, origin: origin, width: width)
    }

    /// The image across the note with the title on a band at its bottom left, and the
    /// domain under it.
    private mutating func largeLinkCard(_ preview: LinkPreview, image: LinkCard.Thumbnail, link: String,
                                        origin: CGPoint, width: CGFloat) -> CGFloat {
        let frame = CGRect(x: origin.x, y: origin.y, width: width, height: (width / LinkCardGeometry.aspect).rounded())
            .pixelAligned(scale: scale)
        images.append(ImageSlot(
            frame: frame,
            request: ImageRequest(url: image.url, size: frame.size, scale: scale),
            blurhash: nil,
            cornerRadius: m.mediaCornerRadius,
            corners: .all,
            overlay: preview.hasPlayer ? .play : nil))
        decorations.append(Decoration(frame: frame, cornerRadius: m.mediaCornerRadius, border: .border))

        let inset = LinkCardGeometry.titleInset
        let padding = LinkCardGeometry.titlePadding
        let captionMetrics = typography.lineMetrics(for: typography.caption)
        let title = TextLayout.singleLine(plain(preview.title.oneLine, font: typography.caption, role: .overlayText),
                                          maxWidth: width - (inset + padding) * 2, metrics: captionMetrics)
        let band = CGRect(x: 0, y: 0, width: title.size.width + padding * 2, height: title.size.height + 2)
        addBlock(CGRect(x: frame.minX + inset, y: frame.maxY - inset - band.height, width: band.width, height: band.height), [
            .roundedRect(band, radius: 4, fill: .linkTitleBackground, stroke: nil),
            .text(title, origin: CGPoint(x: padding, y: 1)),
        ])

        let domain = TextLayout.singleLine(plain(preview.domain, font: typography.small, role: .secondaryText),
                                           maxWidth: width - LinkCardGeometry.domainIndent, metrics: smallMetrics)
        let domainTop = frame.maxY + LinkCardGeometry.domainSpacing
        addBlock(CGRect(x: origin.x + LinkCardGeometry.domainIndent, y: domainTop, width: domain.size.width,
                        height: domain.size.height),
                 [.text(domain, origin: .zero)])
        let bottom = domainTop + domain.size.height
        targets.append(TapTarget(frame: CGRect(x: origin.x, y: origin.y, width: width, height: bottom - origin.y),
                                 action: .link(link)))
        return bottom - origin.y
    }

    /// The image (or a placeholder) at the left of a frame, and the title over the domain
    /// beside it.
    private mutating func smallLinkCard(_ preview: LinkPreview, image: LinkCard.Thumbnail?, link: String,
                                        origin: CGPoint, width: CGFloat) -> CGFloat {
        let side = LinkCardGeometry.side
        let textWidth = max(40, width - side - LinkCardGeometry.padding * 2)
        let title = TextLayout(plain(preview.title.oneLine, font: typography.body, role: .primaryText),
                               width: textWidth, metrics: bodyMetrics, maxLines: 2)
        let domain = TextLayout.singleLine(plain(preview.domain, font: typography.body, role: .secondaryText),
                                           maxWidth: textWidth, metrics: bodyMetrics)
        let textHeight = title.size.height + domain.size.height
        let card = CGRect(x: origin.x, y: origin.y, width: width,
                          height: max(side, textHeight + LinkCardGeometry.verticalPadding * 2))
            .pixelAligned(scale: scale)
        let imageFrame = CGRect(x: card.minX, y: card.minY, width: side, height: card.height).pixelAligned(scale: scale)
        images.append(ImageSlot(
            frame: imageFrame,
            request: image.map { ImageRequest(url: $0.url, size: imageFrame.size, scale: scale) },
            blurhash: nil,
            cornerRadius: m.mediaCornerRadius,
            corners: [.topLeft, .bottomLeft],
            overlay: nil))
        if image == nil {
            let icon = LinkCardGeometry.placeholderIcon
            addBlock(CGRect(x: imageFrame.midX - icon / 2, y: imageFrame.midY - icon / 2, width: icon, height: icon),
                     [.icon(.link, rect: CGRect(x: 0, y: 0, width: icon, height: icon), color: .secondaryText)])
        }
        addBlock(CGRect(x: imageFrame.maxX + LinkCardGeometry.padding, y: card.minY + (card.height - textHeight) / 2,
                        width: textWidth, height: textHeight),
                 [.text(title, origin: .zero), .text(domain, origin: CGPoint(x: 0, y: title.size.height))])
        decorations.append(Decoration(frame: card, cornerRadius: m.mediaCornerRadius, border: .border))
        targets.append(TapTarget(frame: card, action: .link(link)))
        return card.height
    }
}

extension String {
    /// Line breaks as spaces, for a one-line label.
    var oneLine: String {
        components(separatedBy: .newlines).filter { !$0.isEmpty }.joined(separator: " ")
    }
}
