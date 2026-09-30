import CoreText
import UIKit

enum ProfileMetrics {
    static let barRowHeight: CGFloat = 52
    static let barButtonSize: CGFloat = 34
    static let avatarSize: CGFloat = 80
    static let avatarRing: CGFloat = 4
    static let avatarOverlap: CGFloat = 20
    static let avatarMinScale: CGFloat = 0.6
    static let tabsHeight: CGFloat = 44
    static let padding: CGFloat = 16
    static let buttonHeight: CGFloat = 36

    static func bannerHeight(width: CGFloat, collapsedHeight: CGFloat) -> CGFloat {
        max(collapsedHeight + 44, (width / 2.5).rounded())
    }
}

final class ProfileHeaderView: UIView {
    struct Content {
        var user: User
        var profile: UserDetailed?
        var isLoading = false
        var error: String?
    }

    let followButton = FollowButton(height: ProfileMetrics.buttonHeight)

    /// Where the name is, in the view's coordinates (for the top bar's title).
    private(set) var nameFrame: CGRect = .zero

    private let services: NoteServices
    private var content: Content?
    private let nameLabel = UILabel()
    private let acctLabel = UILabel()
    private let followsYouLabel = BadgeLabel()
    private let messageLabel = UILabel()
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let bioView = LinkTextView()
    private var fieldRows: [(name: UILabel, value: LinkTextView)] = []
    private var detailLabels: [UILabel] = []
    private let countsLabel = UILabel()
    private var emojiReloadPending = false
    private var provisionalEmojis: Set<String> = []
    /// Built again (the text changed height): the screen lays the header out again.
    var onContentChange: (() -> Void)?

    init(services: NoteServices) {
        self.services = services
        super.init(frame: .zero)
        backgroundColor = .hibari(.background)

        nameLabel.numberOfLines = 3
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.accessibilityIdentifier = "profile.name"
        acctLabel.textColor = .hibari(.secondaryText)
        acctLabel.lineBreakMode = .byTruncatingMiddle
        acctLabel.accessibilityIdentifier = "profile.acct"
        followsYouLabel.text = "フォローされています"
        followsYouLabel.accessibilityIdentifier = "profile.followsYou"
        messageLabel.textColor = .hibari(.secondaryText)
        messageLabel.numberOfLines = 0
        messageLabel.accessibilityIdentifier = "profile.message"
        spinner.color = .hibari(.secondaryText)
        bioView.accessibilityIdentifier = "profile.bio"
        countsLabel.accessibilityIdentifier = "profile.counts"
        for view in [nameLabel, acctLabel, followsYouLabel, messageLabel, spinner, bioView, countsLabel] as [UIView] {
            addSubview(view)
        }

        followButton.accessibilityIdentifier = "profile.follow"
        addSubview(followButton)

        registerForTraitChanges([UITraitUserInterfaceStyle.self, UITraitPreferredContentSizeCategory.self,
                                 UITraitDisplayScale.self]) { (self: Self, _) in
            self.reload()
        }
        NotificationCenter.default.addObserver(self, selector: #selector(mediaSizesDidChange),
                                               name: ImagePipeline.mediaSizesDidChange, object: services.imagePipeline)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        var view = super.hitTest(point, with: event)
        while let current = view, current !== self {
            if current is UIControl { return current }
            view = current.superview
        }
        return nil
    }

    func configure(_ content: Content) {
        self.content = content
        reload()
    }

    /// The raw link (`TextAttribute.link`) at `point`, in the bio or a field.
    func link(at point: CGPoint) -> String? {
        for view in [bioView] + fieldRows.map(\.value) where !view.isHidden && view.frame.contains(point) {
            return view.link(at: convert(point, to: view))
        }
        return nil
    }

    private var palette: Palette { Palette.palette(for: ThemeStyle(traitCollection.userInterfaceStyle)) }
    private var scale: CGFloat { traitCollection.displayScale > 0 ? traitCollection.displayScale : 3 }
    private func size(_ base: CGFloat) -> CGFloat {
        (UIFontMetrics(forTextStyle: .body).scaledValue(for: base, compatibleWith: traitCollection)).rounded()
    }

    private func reload() {
        guard let content else { return }
        let user = content.profile?.user ?? content.user
        let profile = content.profile
        let text = UIKitRichText(resolver: services.engine.emojiResolver, imagePipeline: services.imagePipeline,
                                 palette: palette, scale: scale, linkURL: { [services] in services.url(forLink: $0) })
        var missing: [ImageRequest] = []
        var provisional: Set<String> = []
        func collect(_ result: UIKitRichText.Result) -> NSAttributedString {
            missing += result.missingEmojis
            provisional.formUnion(result.provisionalEmojis)
            return result.text
        }
        let emojis = EmojiContext.name(of: user)

        let name = NSMutableAttributedString(attributedString: collect(text.build(
            user.displayName, emojis: emojis, font: Typography.system(size(22), bold: true), color: .primaryText,
            simple: true)))
        name.removeAttribute(.paragraphStyle, range: NSRange(location: 0, length: name.length))
        let badgeFont = UIFont.systemFont(ofSize: size(18))
        if profile?.isLocked == true {
            name.append(NSAttributedString(string: " "))
            name.append(Self.symbol("lock.fill", font: badgeFont, color: .hibari(.primaryText)))
        }
        if user.isBot {
            name.append(NSAttributedString(string: " "))
            name.append(Self.botBadge(fontSize: size(12), height: size(18), traits: traitCollection))
        }
        nameLabel.attributedText = name
        nameLabel.accessibilityLabel = [user.displayName, profile?.isLocked == true ? "鍵アカウント" : nil,
                                        user.isBot ? "bot" : nil].compactMap { $0 }.joined(separator: "、")

        acctLabel.font = .systemFont(ofSize: size(15))
        acctLabel.text = user.acct
        followsYouLabel.font = .systemFont(ofSize: size(12))
        followsYouLabel.isHidden = profile?.relation.isFollowed != true

        messageLabel.font = .systemFont(ofSize: size(15))
        messageLabel.text = content.error
        messageLabel.isHidden = content.error == nil
        if content.isLoading && profile == nil { spinner.startAnimating() } else { spinner.stopAnimating() }

        let bodyFont = Typography.system(size(15))
        let lineHeight = (size(15) * 1.4).rounded()
        if let description = profile?.description {
            bioView.attributedText = collect(text.build(description, emojis: emojis, font: bodyFont, color: .primaryText,
                                                        lineHeight: lineHeight))
            bioView.isHidden = false
        } else {
            bioView.attributedText = nil
            bioView.isHidden = true
        }

        let fields = profile?.fields ?? []
        while fieldRows.count < fields.count {
            let name = UILabel()
            name.textColor = .hibari(.secondaryText)
            name.numberOfLines = 2
            let value = LinkTextView()
            addSubview(name)
            addSubview(value)
            fieldRows.append((name, value))
        }
        for (index, row) in fieldRows.enumerated() {
            let shown = index < fields.count
            row.name.isHidden = !shown
            row.value.isHidden = !shown
            guard shown else { continue }
            let field = fields[index]
            row.name.font = .systemFont(ofSize: size(14), weight: .semibold)
            row.name.text = field.name
            let value = NSMutableAttributedString(attributedString: collect(text.build(
                field.value, emojis: emojis, font: bodyFont, color: .primaryText, lineHeight: lineHeight)))
            if profile?.verifiedLinks.contains(field.value) == true {
                value.append(NSAttributedString(string: " "))
                value.append(Self.symbol("checkmark.seal.fill", font: UIFont.systemFont(ofSize: size(14)),
                                         color: .hibari(.renote)))
            }
            row.value.attributedText = value
            row.value.accessibilityLabel = "\(field.name): \(field.value)"
        }

        configureDetails(profile, user: user)
        countsLabel.attributedText = profile.flatMap {
            FollowCounts.text(following: $0.followingCount, followers: $0.followersCount, size: size(15))
        }
        countsLabel.isHidden = countsLabel.attributedText == nil

        provisionalEmojis = provisional
        loadMissingEmojis(missing)
        onContentChange?()
    }

    private func configureDetails(_ profile: UserDetailed?, user: User) {
        var items: [(symbol: String, text: String)] = []
        if let location = profile?.location { items.append(("mappin", location)) }
        if let birthday = profile?.formattedBirthday { items.append(("gift", "誕生日 \(birthday)")) }
        if user.host == nil, let createdAt = profile?.createdAt {
            items.append(("calendar", "\(Self.joinFormatter.string(from: createdAt))から利用しています"))
        }
        while detailLabels.count < items.count {
            let label = UILabel()
            label.lineBreakMode = .byTruncatingTail
            addSubview(label)
            detailLabels.append(label)
        }
        let font = UIFont.systemFont(ofSize: size(15))
        for (index, label) in detailLabels.enumerated() {
            label.isHidden = index >= items.count
            guard index < items.count else { continue }
            let text = NSMutableAttributedString(attributedString: Self.symbol(items[index].symbol, font: font,
                                                                               color: .hibari(.secondaryText)))
            text.append(NSAttributedString(string: " \(items[index].text)", attributes: [
                .font: font, .foregroundColor: UIColor.hibari(.secondaryText),
            ]))
            label.attributedText = text
            label.accessibilityIdentifier = "profile.detail.\(index)"
        }
    }

    private static let joinFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ja_JP")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy年M月"
        return formatter
    }()

    private static func symbol(_ name: String, font: UIFont, color: UIColor) -> NSAttributedString {
        let configuration = UIImage.SymbolConfiguration(font: font, scale: .small)
        guard let image = UIImage(systemName: name, withConfiguration: configuration)?
            .withTintColor(color, renderingMode: .alwaysOriginal) else { return NSAttributedString() }
        return NSAttributedString(attachment: NSTextAttachment(image: image))
    }

    private static func botBadge(fontSize: CGFloat, height: CGFloat, traits: UITraitCollection) -> NSAttributedString {
        let font = UIFont.systemFont(ofSize: fontSize, weight: .semibold)
        let color = UIColor.hibari(.secondaryText).resolvedColor(with: traits)
        let text = NSAttributedString(string: "bot", attributes: [.font: font, .foregroundColor: color])
        let textSize = text.size()
        let size = CGSize(width: ceil(textSize.width) + 10, height: height)
        let format = UIGraphicsImageRendererFormat(for: traits)
        let image = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            let path = UIBezierPath(roundedRect: CGRect(origin: .zero, size: size).insetBy(dx: 0.5, dy: 0.5),
                                    cornerRadius: 4)
            color.setStroke()
            path.lineWidth = 1
            path.stroke()
            text.draw(at: CGPoint(x: 5, y: (size.height - textSize.height) / 2))
        }
        let attachment = NSTextAttachment(image: image)
        attachment.bounds = CGRect(x: 0, y: (font.capHeight - size.height) / 2, width: size.width, height: size.height)
        return NSAttributedString(attachment: attachment)
    }

    private func loadMissingEmojis(_ requests: [ImageRequest]) {
        guard !requests.isEmpty, !emojiReloadPending else { return }
        emojiReloadPending = true
        let group = DispatchGroup()
        for request in requests {
            group.enter()
            services.imagePipeline.load(request) { _ in group.leave() }
        }
        group.notify(queue: .main) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.emojiReloadPending = false
                if requests.contains(where: { self.services.imagePipeline.cachedImage(for: $0) != nil }) {
                    self.reload()
                }
            }
        }
    }

    @objc private func mediaSizesDidChange() {
        guard provisionalEmojis.contains(where: { services.imagePipeline.mediaSize(for: $0) != .unknown }) else { return }
        reload()
    }

    /// Lays the content out at `width` below a banner of `bannerHeight`; returns the height
    /// (the banner's included).
    @discardableResult
    func layout(width: CGFloat, bannerHeight: CGFloat) -> CGFloat {
        let pad = ProfileMetrics.padding
        let inner = max(40, width - pad * 2)

        if !followButton.isHidden {
            let size = followButton.intrinsicContentSize
            followButton.frame = CGRect(x: width - pad - size.width, y: bannerHeight + 12, width: size.width,
                                        height: ProfileMetrics.buttonHeight)
        }

        var y = bannerHeight - ProfileMetrics.avatarOverlap + ProfileMetrics.avatarSize + 10
        let nameHeight = ceil(nameLabel.sizeThatFits(CGSize(width: inner, height: .greatestFiniteMagnitude)).height)
        nameLabel.frame = CGRect(x: pad, y: y, width: inner, height: nameHeight)
        nameFrame = nameLabel.frame
        y += nameHeight + 1

        let acctHeight = ceil(acctLabel.sizeThatFits(CGSize(width: inner, height: 100)).height)
        var acctWidth = ceil(acctLabel.sizeThatFits(CGSize(width: inner, height: 100)).width)
        if !followsYouLabel.isHidden {
            let badge = followsYouLabel.sizeThatFits(CGSize(width: inner, height: 100))
            if acctWidth + 8 + badge.width <= inner {
                followsYouLabel.frame = CGRect(x: pad + acctWidth + 8, y: y + (acctHeight - badge.height) / 2,
                                               width: badge.width, height: badge.height)
            } else {
                acctWidth = min(acctWidth, inner)
                followsYouLabel.frame = CGRect(x: pad, y: y + acctHeight + 4, width: badge.width, height: badge.height)
            }
        }
        acctLabel.frame = CGRect(x: pad, y: y, width: min(acctWidth, inner), height: acctHeight)
        y = max(acctLabel.frame.maxY, followsYouLabel.isHidden ? 0 : followsYouLabel.frame.maxY) + 12

        if spinner.isAnimating {
            spinner.frame = CGRect(x: pad, y: y, width: 20, height: 20)
            y += 20 + 12
        }
        if !messageLabel.isHidden {
            let height = ceil(messageLabel.sizeThatFits(CGSize(width: inner, height: .greatestFiniteMagnitude)).height)
            messageLabel.frame = CGRect(x: pad, y: y, width: inner, height: height)
            y += height + 12
        }
        if !bioView.isHidden {
            let height = bioView.fittedHeight(width: inner)
            bioView.frame = CGRect(x: pad, y: y, width: inner, height: height)
            y += height + 12
        }

        let rows = fieldRows.filter { !$0.name.isHidden }
        if !rows.isEmpty {
            let nameWidth = min((inner / 3).rounded(), rows.map {
                ceil($0.name.sizeThatFits(CGSize(width: inner, height: 100)).width)
            }.max() ?? 0)
            let valueX = pad + nameWidth + 12
            let valueWidth = max(40, width - pad - valueX)
            for row in rows {
                let nameHeight = ceil(row.name.sizeThatFits(CGSize(width: nameWidth, height: 100)).height)
                let valueHeight = row.value.fittedHeight(width: valueWidth)
                row.name.frame = CGRect(x: pad, y: y, width: nameWidth, height: nameHeight)
                row.value.frame = CGRect(x: valueX, y: y, width: valueWidth, height: valueHeight)
                y += max(nameHeight, valueHeight) + 6
            }
            y += 6
        }

        let details = detailLabels.filter { !$0.isHidden }
        if !details.isEmpty {
            var x = pad
            var lineHeight: CGFloat = 0
            for label in details {
                var size = label.sizeThatFits(CGSize(width: inner, height: 100))
                size = CGSize(width: min(ceil(size.width), inner), height: ceil(size.height))
                if x > pad && x + size.width > pad + inner {
                    x = pad
                    y += lineHeight + 4
                    lineHeight = 0
                }
                label.frame = CGRect(x: x, y: y, width: size.width, height: size.height)
                x += size.width + 14
                lineHeight = max(lineHeight, size.height)
            }
            y += lineHeight + 12
        }

        if !countsLabel.isHidden {
            let height = ceil(countsLabel.sizeThatFits(CGSize(width: inner, height: 100)).height)
            countsLabel.frame = CGRect(x: pad, y: y, width: inner, height: height)
            y += height + 12
        }
        return ceil(y + 4)
    }
}

final class BadgeLabel: UILabel {
    private let insets = UIEdgeInsets(top: 2, left: 5, bottom: 2, right: 5)

    override init(frame: CGRect) {
        super.init(frame: frame)
        textColor = .hibari(.secondaryText)
        backgroundColor = .hibari(.chipBackground)
        layer.cornerRadius = 4
        layer.masksToBounds = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        let fitted = super.sizeThatFits(CGSize(width: size.width - insets.left - insets.right, height: size.height))
        return CGSize(width: ceil(fitted.width) + insets.left + insets.right,
                      height: ceil(fitted.height) + insets.top + insets.bottom)
    }

    override func drawText(in rect: CGRect) {
        super.drawText(in: rect.inset(by: insets))
    }
}

final class LinkTextView: UITextView {
    private let storage: NSTextStorage

    init() {
        // TextKit 1, for `layoutManager`'s hit testing.
        let storage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        storage.addLayoutManager(layoutManager)
        let container = NSTextContainer(size: CGSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layoutManager.addTextContainer(container)
        self.storage = storage
        super.init(frame: .zero, textContainer: container)
        isEditable = false
        isSelectable = false
        isScrollEnabled = false
        isUserInteractionEnabled = false
        backgroundColor = .clear
        textContainerInset = .zero
        textContainer.lineFragmentPadding = 0
        linkTextAttributes = [.foregroundColor: UIColor.hibari(.accent)]
        dataDetectorTypes = []
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func fittedHeight(width: CGFloat) -> CGFloat {
        ceil(sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height)
    }

    /// The raw link (`TextAttribute.link`) of the text at `point`, if a link is there.
    func link(at point: CGPoint) -> String? {
        let layoutManager = self.layoutManager
        guard textStorage.length > 0 else { return nil }
        let location = CGPoint(x: point.x - textContainerInset.left, y: point.y - textContainerInset.top)
        let glyph = layoutManager.glyphIndex(for: location, in: textContainer)
        let rect = layoutManager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: textContainer)
        guard rect.insetBy(dx: -6, dy: -6).contains(location) else { return nil }
        let index = layoutManager.characterIndexForGlyph(at: glyph)
        guard index < textStorage.length else { return nil }
        return textStorage.attribute(TextAttribute.link, at: index, effectiveRange: nil) as? String
    }
}
