import UIKit

final class QuoteView: UIControl {
    var onMedia: ((Int) -> Void)? {
        get { media.onTap }
        set { media.onTap = newValue }
    }

    var onUser: (() -> Void)?

    let media = MediaGridView()
    private let files = FileListView()
    private let avatar = UIImageView()
    private let header = UILabel()
    private let userArea = UIControl()
    private let body = UILabel()
    private var mediaFiles: [DriveFile] = []
    private var otherFiles: [DriveFile] = []
    private var avatarTask: ImageTask?
    private static let padding: CGFloat = 12
    private static let avatarSize: CGFloat = 20

    override init(frame: CGRect) {
        super.init(frame: frame)
        layer.cornerRadius = 16
        layer.cornerCurve = .continuous
        layer.borderWidth = 1
        layer.borderColor = UIColor.hibari(.border).cgColor
        clipsToBounds = true
        avatar.layer.cornerRadius = Self.avatarSize / 2
        avatar.clipsToBounds = true
        avatar.backgroundColor = .hibari(.mediaPlaceholder)
        avatar.isUserInteractionEnabled = false
        addSubview(avatar)
        header.isUserInteractionEnabled = false
        header.lineBreakMode = .byTruncatingTail
        addSubview(header)
        body.numberOfLines = 6
        body.isUserInteractionEnabled = false
        addSubview(body)
        media.isFramed = false
        media.onReveal = { [weak self] in self?.sendActions(for: .touchUpInside) }
        addSubview(media)
        addSubview(files)
        userArea.addAction(UIAction { [weak self] _ in self?.onUser?() }, for: .touchUpInside)
        addSubview(userArea)
        accessibilityTraits = .button
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (self: Self, _) in
            self.layer.borderColor = UIColor.hibari(.border).resolvedColor(with: self.traitCollection).cgColor
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(header: NSAttributedString, body: NSAttributedString?, note: Note, width: CGFloat,
                   fileFontSize: CGFloat, revealsSensitiveMedia: Bool, imagePipeline: ImagePipeline,
                   scale: CGFloat) {
        self.header.attributedText = header
        self.body.attributedText = body
        self.body.isHidden = body == nil
        layer.borderWidth = 1 / scale
        mediaFiles = note.cw == nil ? note.visualFiles : []
        media.isHidden = mediaFiles.isEmpty
        if !mediaFiles.isEmpty {
            media.configure(files: mediaFiles, revealed: revealsSensitiveMedia, width: width,
                            imagePipeline: imagePipeline, scale: scale)
        }
        otherFiles = note.cw == nil ? note.otherFiles : []
        files.isHidden = otherFiles.isEmpty
        files.configure(files: otherFiles, fontSize: fileFontSize, scale: scale)
        accessibilityLabel = "引用: \(note.user.displayName)、\(note.cw ?? note.text ?? "")"
        avatarTask?.cancel()
        avatar.image = nil
        if let url = note.user.avatarUrl {
            let request = ImageRequest(url: url, size: CGSize(width: Self.avatarSize, height: Self.avatarSize),
                                       scale: scale, shape: .circle)
            if let image = imagePipeline.cachedImage(for: request) {
                avatar.image = UIImage(cgImage: image, scale: scale, orientation: .up)
            } else {
                avatarTask = imagePipeline.load(request) { [weak self] image in
                    guard let image else { return }
                    self?.avatar.image = UIImage(cgImage: image, scale: scale, orientation: .up)
                }
            }
        }
    }

    /// Lays out at `width`; returns the height.
    @discardableResult
    func layout(width: CGFloat, apply: Bool) -> CGFloat {
        let inner = width - Self.padding * 2
        var y = Self.padding
        let headerHeight = max(Self.avatarSize, header.sizeThatFits(CGSize(width: inner, height: 100)).height)
        if apply {
            avatar.frame = CGRect(x: Self.padding, y: y + (headerHeight - Self.avatarSize) / 2,
                                  width: Self.avatarSize, height: Self.avatarSize)
            header.frame = CGRect(x: Self.padding + Self.avatarSize + 6, y: y,
                                  width: inner - Self.avatarSize - 6, height: headerHeight)
            let nameWidth = min(header.frame.width, ceil(header.sizeThatFits(CGSize(width: 1000, height: 100)).width))
            userArea.frame = CGRect(x: 0, y: 0, width: header.frame.minX + nameWidth + 4, height: y + headerHeight + 4)
        }
        y += headerHeight
        if !body.isHidden {
            let height = body.sizeThatFits(CGSize(width: inner, height: .greatestFiniteMagnitude)).height
            y += 4
            if apply { body.frame = CGRect(x: Self.padding, y: y, width: inner, height: height) }
            y += height
        }
        if !mediaFiles.isEmpty {
            y += 10
            let height = MediaGridView.height(for: mediaFiles, width: width)
            if apply { media.frame = CGRect(x: 0, y: y, width: width, height: height) }
            y += height
            if otherFiles.isEmpty { return y }
        }
        if !otherFiles.isEmpty {
            y += 10
            if apply { files.frame = CGRect(x: Self.padding, y: y, width: inner, height: files.height) }
            y += files.height
        }
        return y + Self.padding
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        layout(width: bounds.width, apply: true)
    }

    override var isHighlighted: Bool {
        didSet {
            backgroundColor = isHighlighted ? .hibari(.chipBackground) : .clear
        }
    }
}

/// The files that are neither images nor videos (audio, text, ...): a bordered row each
/// with the file's name, as on the timeline. A row opens the file in the browser; with no
/// `onTap` (in a quote) the rows take no touches and the box behind gets them.
final class FileListView: UIView {
    var onTap: ((String) -> Void)? {
        didSet { isUserInteractionEnabled = onTap != nil }
    }

    private var rows: [FileRow] = []
    private var rowHeight: CGFloat = 0
    private static let rowSpacing: CGFloat = 6

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(files: [DriveFile], fontSize: CGFloat, scale: CGFloat) {
        rows.forEach { $0.removeFromSuperview() }
        let font = UIFont.systemFont(ofSize: fontSize)
        rowHeight = ceil(font.lineHeight) + 18
        rows = files.map { file in
            let row = FileRow(name: file.name, font: font, hairline: 1 / scale)
            if let url = file.url {
                row.addAction(UIAction { [weak self] _ in self?.onTap?(url) }, for: .touchUpInside)
            }
            addSubview(row)
            return row
        }
        setNeedsLayout()
    }

    var height: CGFloat {
        rows.isEmpty ? 0 : CGFloat(rows.count) * (rowHeight + Self.rowSpacing) - Self.rowSpacing
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        for (index, row) in rows.enumerated() {
            row.frame = CGRect(x: 0, y: CGFloat(index) * (rowHeight + Self.rowSpacing), width: bounds.width,
                               height: rowHeight)
        }
    }
}

private final class FileRow: UIControl {
    private let icon = UIImageView()
    private let label = UILabel()

    init(name: String, font: UIFont, hairline: CGFloat) {
        super.init(frame: .zero)
        layer.cornerRadius = 10
        layer.cornerCurve = .continuous
        layer.borderWidth = hairline
        layer.borderColor = UIColor.hibari(.border).cgColor
        icon.image = UIImage(systemName: Icon.file.symbolName,
                             withConfiguration: UIImage.SymbolConfiguration(pointSize: font.pointSize))
        icon.tintColor = .hibari(.secondaryText)
        icon.contentMode = .center
        addSubview(icon)
        label.font = font
        label.textColor = .hibari(.primaryText)
        label.lineBreakMode = .byTruncatingTail
        label.text = name
        addSubview(label)
        isAccessibilityElement = true
        accessibilityLabel = name
        accessibilityTraits = .link
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (self: Self, _) in
            self.layer.borderColor = UIColor.hibari(.border).resolvedColor(with: self.traitCollection).cgColor
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isHighlighted: Bool {
        didSet {
            backgroundColor = isHighlighted ? .hibari(.chipBackground) : .clear
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let iconSize = (label.font.pointSize * 1.3).rounded()
        icon.frame = CGRect(x: 12, y: (bounds.height - iconSize) / 2, width: iconSize, height: iconSize)
        let labelX = icon.frame.maxX + 8
        label.frame = CGRect(x: labelX, y: 0, width: max(0, bounds.width - labelX - 12), height: bounds.height)
    }
}

/// A poll: choices take votes until the account voted (one, or all for a `multiple` poll)
/// or the poll ended. Until it voted, results show only when it asks ("結果を見る").
final class PollView: UIView {
    /// The choice at this index was tapped to vote.
    var onVote: ((Int) -> Void)?
    /// "結果を見る" / "投票する" was tapped.
    var onToggleResults: (() -> Void)?

    private var rows: [PollRow] = []
    private let footer = UILabel()
    private let toggle = UIButton(type: .system)
    private static let rowHeight: CGFloat = 38
    private static let rowSpacing: CGFloat = 6
    private static let footerHeight: CGFloat = 18

    override init(frame: CGRect) {
        super.init(frame: frame)
        footer.font = .systemFont(ofSize: 13)
        footer.textColor = .hibari(.secondaryText)
        addSubview(footer)
        toggle.titleLabel?.font = .systemFont(ofSize: 13)
        toggle.setTitleColor(.hibari(.secondaryText), for: .normal)
        toggle.accessibilityIdentifier = "noteDetail.pollResults"
        toggle.addAction(UIAction { [weak self] _ in self?.onToggleResults?() }, for: .touchUpInside)
        addSubview(toggle)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// `peeking`: the account asked to see the results before voting.
    func configure(_ poll: Poll, peeking: Bool, now: Date = Date(), text: (String) -> NSAttributedString) {
        rows.forEach { $0.removeFromSuperview() }
        let closed = poll.isClosed(at: now)
        let showsResults = poll.showsResults(peeking: peeking, closed: closed)
        rows = zip(poll.choices, poll.voteRatios).enumerated().map { index, entry in
            let (choice, ratio) = entry
            let row = PollRow(text: text(choice.isVoted == true ? "✓ \(choice.text)" : choice.text),
                              ratio: showsResults ? CGFloat(ratio) : nil,
                              votable: poll.canVote(for: index, closed: closed))
            row.accessibilityIdentifier = "noteDetail.poll.\(index)"
            row.addAction(UIAction { [weak self] _ in self?.onVote?(index) }, for: .touchUpInside)
            insertSubview(row, belowSubview: footer)
            return row
        }
        var summary = "\(poll.voteTotal)票"
        if let expiresAt = poll.expiresAt {
            let remaining = expiresAt.timeIntervalSince(now)
            summary += remaining > 0 ? " · 残り\(RelativeTime.duration(remaining))" : " · 終了"
        }
        footer.text = summary
        toggle.isHidden = poll.hasVoted || !poll.canVote(closed: closed)
        toggle.setTitle(showsResults ? "投票する" : "結果を見る", for: .normal)
        setNeedsLayout()
    }

    var height: CGFloat {
        CGFloat(rows.count) * (Self.rowHeight + Self.rowSpacing) + Self.footerHeight
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        var y: CGFloat = 0
        for row in rows {
            row.frame = CGRect(x: 0, y: y, width: bounds.width, height: Self.rowHeight)
            y += Self.rowHeight + Self.rowSpacing
        }
        let toggleWidth = toggle.isHidden ? 0 : toggle.intrinsicContentSize.width
        toggle.frame = CGRect(x: bounds.width - toggleWidth, y: y - 8, width: toggleWidth, height: Self.footerHeight + 16)
        footer.frame = CGRect(x: 0, y: y, width: bounds.width - toggleWidth - 8, height: Self.footerHeight)
    }
}

/// A poll choice: outlined while it takes votes and the results are hidden, filled up to
/// its share of the votes once they show (`ratio`).
private final class PollRow: UIControl {
    private let fill = UIView()
    private let label = UILabel()
    private let percent = UILabel()
    private let ratio: CGFloat?
    private let votable: Bool

    init(text: NSAttributedString, ratio: CGFloat?, votable: Bool) {
        self.ratio = ratio
        self.votable = votable
        super.init(frame: .zero)
        layer.cornerRadius = 8
        clipsToBounds = true
        isEnabled = votable
        if ratio != nil {
            backgroundColor = .hibari(.chipBackground)
            fill.backgroundColor = .hibari(.chipReactedBackground)
            fill.isUserInteractionEnabled = false
            addSubview(fill)
            percent.font = .systemFont(ofSize: 14, weight: .semibold)
            percent.textColor = .hibari(.secondaryText)
            percent.text = "\(Int(((ratio ?? 0) * 100).rounded()))%"
            addSubview(percent)
        } else {
            layer.borderWidth = 1
            updateBorderColor()
            registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (self: Self, _) in self.updateBorderColor() }
        }
        label.attributedText = text
        label.lineBreakMode = .byTruncatingTail
        addSubview(label)
        isAccessibilityElement = true
        accessibilityLabel = [text.string, ratio == nil ? nil : percent.text].compactMap { $0 }.joined(separator: " ")
        accessibilityTraits = votable ? .button : .staticText
        if votable { accessibilityHint = "投票します" }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func updateBorderColor() {
        layer.borderColor = UIColor.hibari(.border).resolvedColor(with: traitCollection).cgColor
    }

    override var isHighlighted: Bool {
        didSet {
            guard votable, isHighlighted != oldValue else { return }
            let base: UIColor = ratio == nil ? .clear : .hibari(.chipBackground)
            UIView.animate(withDuration: isHighlighted ? 0 : 0.2, delay: 0, options: [.allowUserInteraction]) {
                self.backgroundColor = self.isHighlighted ? .hibari(.border) : base
                self.transform = self.isHighlighted ? CGAffineTransform(scaleX: 0.98, y: 0.98) : .identity
            }
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let ratio = ratio ?? 0
        fill.frame = CGRect(x: 0, y: 0, width: ratio > 0 ? max(16, bounds.width * ratio) : 0, height: bounds.height)
        let percentWidth = self.ratio == nil ? 0 : percent.intrinsicContentSize.width
        percent.frame = CGRect(x: bounds.width - 12 - percentWidth, y: 0, width: percentWidth, height: bounds.height)
        label.frame = CGRect(x: 12, y: 0, width: max(0, bounds.width - 12 - percentWidth - 20), height: bounds.height)
    }
}
