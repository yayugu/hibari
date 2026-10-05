import CoreText
import UIKit

final class FocusedNoteView: UIView {
    var onLink: ((String) -> Void)?
    /// Media tapped: whose (the note's or the quote's) and its index in their visual files.
    var onMedia: ((MediaOwner, Int) -> Void)?
    var onQuote: (() -> Void)?
    /// A reaction chip, with where it is in window coordinates.
    var onReaction: ((String, CGRect) -> Void)?
    /// The reaction button, with where it is in window coordinates.
    var onReact: ((CGRect) -> Void)?
    var onReply: (() -> Void)?
    var onBookmark: (() -> Void)?
    var onRenote: (() -> Void)?
    var onShare: (() -> Void)?
    /// The avatar or the name: the author's profile.
    var onUser: ((User) -> Void)?
    var onFollow: (() -> Void)?
    /// The follow button's, nil without it (the account follows the author, or it is theirs).
    var followState: FollowState? {
        didSet {
            guard followState != oldValue else { return }
            if let followState { followButton.apply(followState) }
            let appears = oldValue == nil && followState != nil && window != nil
            followButton.isHidden = followState == nil
            setNeedsLayout()
            guard appears else { return }
            layoutIfNeeded()
            followButton.alpha = 0
            UIView.animate(withDuration: 0.2) { self.followButton.alpha = 1 }
        }
    }
    /// The content changed height.
    var onResize: (() -> Void)?

    private(set) var note: Note
    var showsThreadLine = false {
        didSet { setNeedsLayout() }
    }

    private let services: NoteServices
    private var cwExpanded = false
    private var pollResultsShown = false
    private lazy var sensitiveRevealed = services.sensitiveMedia == .show
    private var provisionalEmojis: Set<String> = []
    private var emojiReloadPending = false
    private var avatarTask: ImageTask?
    private var loadedAvatar: String?

    private let threadLine = UIView()
    private let avatar = UIImageView()
    private let nameLabel = UILabel()
    private let acctLabel = UILabel()
    private let followButton = FollowButton(height: 26, fontSize: 11)
    private let cwTextView = SelectableTextView()
    private let cwButton = UIButton(configuration: .gray())
    private let bodyTextView = SelectableTextView()
    private let media = MediaGridView()
    private let files = FileListView()
    private let poll = PollView()
    private let quote = QuoteView()
    private let reactions = ReactionChipsView()
    private let timeLabel = UILabel()
    private let bottomSeparator = UIView()
    private let replyButton = UIButton(configuration: .plain())
    private let renoteButton = UIButton(configuration: .plain())
    private let reactButton = UIButton(configuration: .plain())
    private let bookmarkButton = UIButton(configuration: .plain())
    private let shareButton = UIButton(configuration: .plain())

    private static let padding = LayoutMetrics().contentInsets.left
    private static let avatarSize = LayoutMetrics().avatarSize
    private static let actionRowHeight: CGFloat = 48

    init(note: Note, services: NoteServices) {
        self.note = note
        self.services = services
        super.init(frame: .zero)
        backgroundColor = .hibari(.background)

        threadLine.backgroundColor = .hibari(.border)
        threadLine.layer.cornerRadius = 1
        addSubview(threadLine)
        avatar.layer.cornerRadius = Self.avatarSize / 2
        avatar.clipsToBounds = true
        avatar.backgroundColor = .hibari(.mediaPlaceholder)
        addSubview(avatar)
        nameLabel.lineBreakMode = .byTruncatingTail
        addSubview(nameLabel)
        acctLabel.textColor = .hibari(.secondaryText)
        acctLabel.lineBreakMode = .byTruncatingMiddle
        addSubview(acctLabel)
        for view in [avatar, nameLabel, acctLabel] as [UIView] {
            view.isUserInteractionEnabled = true
            view.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(userTapped)))
        }
        avatar.accessibilityIdentifier = "noteDetail.avatar"
        followButton.isHidden = true
        followButton.accessibilityIdentifier = "noteDetail.follow"
        followButton.addAction(UIAction { [weak self] _ in self?.onFollow?() }, for: .touchUpInside)
        addSubview(followButton)

        cwTextView.onLink = { [weak self] in self?.onLink?($0) }
        addSubview(cwTextView)
        cwButton.configuration?.cornerStyle = .capsule
        cwButton.configuration?.baseForegroundColor = .hibari(.primaryText)
        cwButton.accessibilityIdentifier = "noteDetail.cw"
        cwButton.addAction(UIAction { [weak self] _ in self?.toggleCW() }, for: .touchUpInside)
        addSubview(cwButton)

        bodyTextView.onLink = { [weak self] in self?.onLink?($0) }
        bodyTextView.accessibilityIdentifier = "noteDetail.text"
        addSubview(bodyTextView)
        media.onTap = { [weak self] index in self?.onMedia?(.note, index) }
        media.onReveal = { [weak self] in self?.revealSensitive() }
        addSubview(media)
        files.onTap = { [weak self] in self?.onLink?($0) }
        addSubview(files)
        poll.onVote = { [weak self] index in
            guard let self else { return }
            self.services.vote(for: index, in: self.note)
        }
        poll.onToggleResults = { [weak self] in
            guard let self else { return }
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            self.pollResultsShown.toggle()
            self.reloadContent()
        }
        addSubview(poll)
        quote.onMedia = { [weak self] index in self?.onMedia?(.quote, index) }
        quote.addAction(UIAction { [weak self] _ in self?.onQuote?() }, for: .touchUpInside)
        quote.onUser = { [weak self] in
            guard let self, let quoted = self.note.renote else { return }
            self.onUser?(quoted.user)
        }
        addSubview(quote)
        reactions.onTap = { [weak self] key, frame in self?.onReaction?(key, frame) }
        addSubview(reactions)

        timeLabel.textColor = .hibari(.secondaryText)
        timeLabel.accessibilityIdentifier = "noteDetail.time"
        addSubview(timeLabel)
        bottomSeparator.backgroundColor = .hibari(.separator)
        addSubview(bottomSeparator)

        let actions: [(UIButton, String, () -> Void)] = [
            (replyButton, "noteDetail.reply", { [weak self] in self?.onReply?() }),
            (renoteButton, "noteDetail.renote", { [weak self] in self?.onRenote?() }),
            (reactButton, "noteDetail.react", { [weak self] in
                guard let self else { return }
                self.onReact?(self.reactButton.convert(self.reactButton.bounds, to: nil))
            }),
            (bookmarkButton, "noteDetail.bookmark", { [weak self] in self?.onBookmark?() }),
            (shareButton, "noteDetail.share", { [weak self] in self?.onShare?() }),
        ]
        for (button, identifier, action) in actions {
            button.accessibilityIdentifier = identifier
            button.addAction(UIAction { _ in action() }, for: .touchUpInside)
            addSubview(button)
        }
        replyButton.accessibilityLabel = "返信"
        shareButton.accessibilityLabel = "共有"

        registerForTraitChanges([UITraitUserInterfaceStyle.self, UITraitPreferredContentSizeCategory.self,
                                 UITraitDisplayScale.self]) { (self: Self, _) in
            self.reloadContent()
        }
        NotificationCenter.default.addObserver(self, selector: #selector(mediaSizesDidChange),
                                               name: ImagePipeline.mediaSizesDidChange, object: services.imagePipeline)
        reloadContent()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func update(_ note: Note) {
        self.note = note
        reloadContent()
    }

    /// Plays `kind` over its button's icon.
    func playActionAnimation(_ kind: ActionIconAnimation.Kind) {
        let button = kind.action == .renote ? renoteButton : bookmarkButton
        guard let imageView = button.imageView, imageView.bounds.width > 0 else { return }
        let palette = Palette.palette(for: ThemeStyle(traitCollection.userInterfaceStyle))
        guard let animation = ActionIconAnimation.play(kind, frame: imageView.convert(imageView.bounds, to: self),
                                                       cover: palette[.background], palette: palette,
                                                       scale: traitCollection.displayScale, in: layer)
        else { return }
        // The image the button changes to waits under the cover until it is done.
        animation.zPosition = 1
        DispatchQueue.main.asyncAfter(deadline: .now() + kind.duration) {
            animation.removeFromSuperlayer()
        }
    }

    /// Where media `index` of `owner` is shown, in window coordinates.
    func mediaTarget(owner: MediaOwner, index: Int) -> MediaTransitionTarget? {
        let grid = owner == .note ? media : quote.media
        guard !grid.isHidden, window != nil, let tile = grid.tile(at: index) else { return nil }
        let bounds = grid.bounds
        var corners: CACornerMask = []
        if tile.frame.minX <= 0.5 && tile.frame.minY <= 0.5 { corners.insert(.layerMinXMinYCorner) }
        if tile.frame.maxX >= bounds.width - 0.5 && tile.frame.minY <= 0.5 { corners.insert(.layerMaxXMinYCorner) }
        if tile.frame.minX <= 0.5 && tile.frame.maxY >= bounds.height - 0.5 { corners.insert(.layerMinXMaxYCorner) }
        if tile.frame.maxX >= bounds.width - 0.5 && tile.frame.maxY >= bounds.height - 0.5 {
            corners.insert(.layerMaxXMaxYCorner)
        }
        if owner == .quote {
            corners.subtract([.layerMinXMinYCorner, .layerMaxXMinYCorner])
        }
        return MediaTransitionTarget(frame: grid.convert(tile.frame, to: nil), cornerRadius: 16, corners: corners,
                                     image: tile.image)
    }

    func setHiddenMedia(owner: MediaOwner, index: Int?) {
        media.setHiddenTile(owner == .note ? index : nil)
        quote.media.setHiddenTile(owner == .quote ? index : nil)
    }

    private var palette: Palette { Palette.palette(for: ThemeStyle(traitCollection.userInterfaceStyle)) }
    private var scale: CGFloat { traitCollection.displayScale > 0 ? traitCollection.displayScale : 3 }
    private var fontScale: CGFloat {
        UIFontMetrics(forTextStyle: .body).scaledValue(for: 100, compatibleWith: traitCollection) / 100
    }

    private func richText() -> UIKitRichText {
        UIKitRichText(resolver: services.engine.emojiResolver, imagePipeline: services.imagePipeline, palette: palette,
                      scale: scale, linkURL: { [services] in services.url(forLink: $0) })
    }

    private func reloadContent() {
        let text = richText()
        let size = { (base: CGFloat) in (base * self.fontScale).rounded() }
        var missing: [ImageRequest] = []
        var provisional: Set<String> = []
        func collect(_ result: UIKitRichText.Result) -> NSAttributedString {
            missing += result.missingEmojis
            provisional.formUnion(result.provisionalEmojis)
            return result.text
        }

        let user = note.user
        nameLabel.attributedText = collect(text.build(user.displayName, emojis: .name(of: user),
                                                      font: Typography.system(size(17), bold: true),
                                                      color: .primaryText, simple: true))
        acctLabel.font = .systemFont(ofSize: size(15))
        acctLabel.text = user.acct
        loadAvatar()

        let bodyFont = Typography.system(size(18))
        let lineHeight = (size(18) * 1.45).rounded()
        if let cw = note.cw {
            cwTextView.attributedText = collect(text.build(cw, emojis: .text(of: note), font: bodyFont, color: .primaryText,
                                                           lineHeight: lineHeight))
            let files = note.files.count
            var title = AttributedString(cwExpanded ? "隠す" : (files > 0 ? "もっと見る (\(files)ファイル)" : "もっと見る"))
            title.font = .systemFont(ofSize: size(14), weight: .semibold)
            cwButton.configuration?.attributedTitle = title
        }
        if let body = note.text, !body.isEmpty {
            bodyTextView.attributedText = collect(text.build(body, emojis: .text(of: note), font: bodyFont,
                                                             color: .primaryText, lineHeight: lineHeight))
        } else {
            bodyTextView.attributedText = nil
        }
        if let poll = note.poll {
            let choiceFont = Typography.system(size(15))
            self.poll.configure(poll, peeking: pollResultsShown) { collect(text.build($0, emojis: .text(of: note), font: choiceFont, color: .primaryText)) }
        }
        if let quoted = note.renote {
            let header = NSMutableAttributedString(attributedString: collect(text.build(
                quoted.user.displayName, emojis: .name(of: quoted.user), font: Typography.system(size(15), bold: true),
                color: .primaryText, simple: true)))
            header.append(NSAttributedString(string: " \(quoted.user.acct)", attributes: [
                .font: UIFont.systemFont(ofSize: size(15)), .foregroundColor: UIColor.hibari(.secondaryText),
            ]))
            let body = (quoted.cw ?? quoted.text).map {
                collect(text.build($0, emojis: .text(of: quoted), font: Typography.system(size(16)), color: .primaryText))
            }
            quote.configure(header: header, body: body, note: quoted, width: contentWidth, fileFontSize: size(14),
                            revealsSensitiveMedia: services.sensitiveMedia == .show,
                            imagePipeline: services.imagePipeline, scale: scale)
        }
        reactions.configure(note, resolver: services.engine.emojiResolver, imagePipeline: services.imagePipeline,
                            scale: scale)
        provisional.formUnion(reactions.provisionalEmojis)

        timeLabel.font = .monospacedDigitSystemFont(ofSize: size(15), weight: .regular)
        timeLabel.text = Self.timestamp(note)
        configureActions(fontSize: size(14))
        configureMedia()
        files.configure(files: note.otherFiles, fontSize: size(15), scale: scale)

        provisionalEmojis = provisional
        loadMissingEmojis(missing)
        setNeedsLayout()
        onResize?()
    }

    private var contentWidth: CGFloat {
        max(40, (bounds.width > 0 ? bounds.width : window?.bounds.width ?? 390) - Self.padding * 2)
    }

    private var showsContent: Bool { note.cw == nil || cwExpanded }

    private func configureMedia() {
        let files = note.visualFiles
        media.isHidden = files.isEmpty || !showsContent
        if !media.isHidden {
            media.configure(files: files, revealed: sensitiveRevealed, width: contentWidth,
                            imagePipeline: services.imagePipeline, scale: scale)
        }
    }

    private func configureActions(fontSize: CGFloat) {
        func style(_ button: UIButton, icon: Icon, count: Int?, tint: UIColor) {
            var configuration = UIButton.Configuration.plain()
            configuration.image = IconStore.shared.templateImage(icon, size: CGSize(width: 18, height: 18), scale: scale)
            configuration.imagePadding = 5
            configuration.baseForegroundColor = tint
            configuration.contentInsets = NSDirectionalEdgeInsets(top: 13, leading: 13, bottom: 13, trailing: 13)
            if let count, count > 0 {
                var title = AttributedString(CountLabel.format(count))
                title.font = .monospacedDigitSystemFont(ofSize: fontSize, weight: .regular)
                configuration.attributedTitle = title
            }
            button.configuration = configuration
            button.accessibilityValue = count.map { "\($0)" }
        }
        style(replyButton, icon: .reply, count: note.repliesCount, tint: .hibari(.secondaryText))
        style(renoteButton, icon: .renote, count: note.renoteCount,
              tint: note.isRenotedByMe ? .hibari(.renote) : .hibari(.secondaryText))
        renoteButton.accessibilityLabel = note.isRenotedByMe ? "リノート済み" : "リノート"
        let react = Icon.reactButton(for: note)
        style(reactButton, icon: react.icon, count: note.reactionTotal, tint: .hibari(react.color))
        reactButton.accessibilityLabel = react.label
        style(bookmarkButton, icon: note.isBookmarked ? .bookmarked : .bookmark, count: nil,
              tint: note.isBookmarked ? .hibari(.accent) : .hibari(.secondaryText))
        bookmarkButton.accessibilityLabel = note.isBookmarked ? "ブックマークから削除" : "ブックマーク"
        style(shareButton, icon: .share, count: nil, tint: .hibari(.secondaryText))
    }

    static func timestamp(_ note: Note) -> String {
        var parts = [timestampFormatter.string(from: note.createdAt)]
        switch note.visibility {
        case "home": parts.append("ホーム")
        case "followers": parts.append("フォロワー")
        case "specified": parts.append("ダイレクト")
        default: break
        }
        if note.localOnly { parts.append("連合なし") }
        return parts.joined(separator: " · ")
    }

    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "H:mm · yyyy/MM/dd"
        return formatter
    }()

    private func loadAvatar() {
        guard let url = note.user.avatarUrl else {
            avatar.image = nil
            return
        }
        let request = ImageRequest(url: url, size: CGSize(width: Self.avatarSize, height: Self.avatarSize), scale: scale,
                                   shape: .circle)
        guard request.cacheKey != loadedAvatar else { return }
        loadedAvatar = request.cacheKey
        avatarTask?.cancel()
        if let image = services.imagePipeline.cachedImage(for: request) {
            avatar.image = UIImage(cgImage: image, scale: scale, orientation: .up)
            return
        }
        let scale = self.scale
        avatarTask = services.imagePipeline.load(request) { [weak self] image in
            guard let image else { return }
            self?.avatar.image = UIImage(cgImage: image, scale: scale, orientation: .up)
        }
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
                    self.reloadContent()
                }
            }
        }
    }

    @objc private func mediaSizesDidChange() {
        guard provisionalEmojis.contains(where: { services.imagePipeline.mediaSize(for: $0) != .unknown }) else { return }
        reloadContent()
    }

    @objc private func userTapped() {
        onUser?(note.user)
    }

    private func toggleCW() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        cwExpanded.toggle()
        reloadContent()
    }

    private func revealSensitive() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        sensitiveRevealed = true
        configureMedia()
    }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        CGSize(width: size.width, height: layout(width: size.width, apply: false))
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let widthChanged = media.bounds.width != contentWidth && !media.isHidden
        layout(width: bounds.width, apply: true)
        if widthChanged {
            configureMedia()
        }
    }

    @discardableResult
    private func layout(width: CGFloat, apply: Bool) -> CGFloat {
        let pad = Self.padding
        let inner = max(40, width - pad * 2)
        let hairline = 1 / scale
        var y: CGFloat = 12

        if apply {
            threadLine.isHidden = !showsThreadLine
            threadLine.frame = CGRect(x: pad + Self.avatarSize / 2 - 1, y: 0, width: 2, height: max(0, y - 4))
            avatar.frame = CGRect(x: pad, y: y, width: Self.avatarSize, height: Self.avatarSize)
        }
        let nameX = pad + Self.avatarSize + LayoutMetrics().avatarSpacing
        var nameWidth = width - nameX - pad
        if !followButton.isHidden {
            let size = followButton.intrinsicContentSize
            if apply {
                followButton.frame = CGRect(x: width - pad - size.width,
                                            y: y + ((Self.avatarSize - size.height) / 2).rounded(),
                                            width: size.width, height: size.height)
            }
            nameWidth -= size.width + 12
        }
        let nameHeight = ceil(nameLabel.sizeThatFits(CGSize(width: nameWidth, height: 100)).height)
        let acctHeight = ceil(acctLabel.sizeThatFits(CGSize(width: nameWidth, height: 100)).height)
        let namesTop = y + (Self.avatarSize - nameHeight - acctHeight) / 2
        if apply {
            nameLabel.frame = CGRect(x: nameX, y: namesTop, width: nameWidth, height: nameHeight)
            acctLabel.frame = CGRect(x: nameX, y: namesTop + nameHeight, width: nameWidth, height: acctHeight)
        }
        y += Self.avatarSize + 12

        func place(_ view: UIView, height: CGFloat, gap: CGFloat = 12) {
            if apply { view.frame = CGRect(x: pad, y: y, width: inner, height: height) }
            y += height + gap
        }
        func fittedHeight(_ textView: UITextView) -> CGFloat {
            ceil(textView.sizeThatFits(CGSize(width: inner, height: .greatestFiniteMagnitude)).height)
        }

        cwTextView.isHidden = note.cw == nil
        cwButton.isHidden = note.cw == nil
        if note.cw != nil {
            place(cwTextView, height: fittedHeight(cwTextView), gap: 8)
            let size = cwButton.sizeThatFits(CGSize(width: inner, height: 44))
            if apply { cwButton.frame = CGRect(x: pad, y: y, width: size.width, height: size.height) }
            y += size.height + 12
        }
        let hasBody = bodyTextView.attributedText.map { $0.length > 0 } ?? false
        bodyTextView.isHidden = !showsContent || !hasBody
        if !bodyTextView.isHidden {
            place(bodyTextView, height: fittedHeight(bodyTextView))
        }
        files.isHidden = !showsContent || note.otherFiles.isEmpty
        if !media.isHidden {
            place(media, height: MediaGridView.height(for: note.visualFiles, width: inner), gap: files.isHidden ? 12 : 8)
        }
        if !files.isHidden {
            place(files, height: files.height)
        }
        poll.isHidden = !showsContent || note.poll == nil
        if !poll.isHidden {
            place(poll, height: poll.height)
        }
        quote.isHidden = !showsContent || note.renote == nil
        if !quote.isHidden {
            place(quote, height: quote.layout(width: inner, apply: false))
        }
        reactions.isHidden = note.reactions.isEmpty || note.isLikeOnly
        if !reactions.isHidden {
            place(reactions, height: reactions.height(for: inner), gap: 14)
        }

        let timeHeight = ceil(timeLabel.sizeThatFits(CGSize(width: inner, height: 100)).height)
        place(timeLabel, height: timeHeight, gap: 2)

        let buttons = [replyButton, renoteButton, reactButton, bookmarkButton, shareButton]
        if apply {
            let iconXs = LayoutMetrics().actionIconXs(for: inner)
            for (index, button) in buttons.enumerated() {
                let availableWidth = index < 3 ? iconXs[index + 1] - iconXs[index] : 44
                let size = button.sizeThatFits(CGSize(width: availableWidth, height: Self.actionRowHeight))
                let x = pad + iconXs[index] - 13
                button.frame = CGRect(x: x, y: y + (Self.actionRowHeight - size.height) / 2,
                                      width: size.width, height: size.height)
            }
        }
        y += Self.actionRowHeight
        if apply { bottomSeparator.frame = CGRect(x: 0, y: y, width: width, height: hairline) }
        return ceil(y + hairline)
    }
}
