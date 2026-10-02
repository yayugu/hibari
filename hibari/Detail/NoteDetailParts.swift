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

final class PollView: UIView {
    private var rows: [(background: UIView, fill: UIView, label: UILabel, percent: UILabel)] = []
    private let footer = UILabel()
    private var ratios: [CGFloat] = []
    private static let rowHeight: CGFloat = 38
    private static let rowSpacing: CGFloat = 6

    func configure(_ poll: Poll, text: (String) -> NSAttributedString) {
        rows.forEach { $0.background.removeFromSuperview() }
        rows = []
        ratios = poll.voteRatios.map { CGFloat($0) }
        for (choice, ratio) in zip(poll.choices, ratios) {
            let background = UIView()
            background.backgroundColor = .hibari(.chipBackground)
            background.layer.cornerRadius = 8
            background.clipsToBounds = true
            let fill = UIView()
            fill.backgroundColor = .hibari(.chipReactedBackground)
            background.addSubview(fill)
            let label = UILabel()
            label.attributedText = text(choice.isVoted == true ? "✓ \(choice.text)" : choice.text)
            label.lineBreakMode = .byTruncatingTail
            background.addSubview(label)
            let percent = UILabel()
            percent.font = .systemFont(ofSize: 14, weight: .semibold)
            percent.textColor = .hibari(.secondaryText)
            percent.text = "\(Int((ratio * 100).rounded()))%"
            background.addSubview(percent)
            addSubview(background)
            rows.append((background, fill, label, percent))
        }
        footer.font = .systemFont(ofSize: 13)
        footer.textColor = .hibari(.secondaryText)
        var summary = "\(poll.voteTotal)票"
        if let expiresAt = poll.expiresAt {
            let remaining = expiresAt.timeIntervalSinceNow
            summary += remaining > 0 ? " · 残り\(RelativeTime.duration(remaining))" : " · 終了"
        }
        footer.text = summary
        addSubview(footer)
        setNeedsLayout()
    }

    var height: CGFloat {
        CGFloat(rows.count) * (Self.rowHeight + Self.rowSpacing) + 18
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        var y: CGFloat = 0
        for (row, ratio) in zip(rows, ratios) {
            row.background.frame = CGRect(x: 0, y: y, width: bounds.width, height: Self.rowHeight)
            row.fill.frame = CGRect(x: 0, y: 0, width: ratio > 0 ? max(16, bounds.width * ratio) : 0, height: Self.rowHeight)
            let percentWidth = row.percent.intrinsicContentSize.width
            row.percent.frame = CGRect(x: bounds.width - 12 - percentWidth, y: 0, width: percentWidth, height: Self.rowHeight)
            row.label.frame = CGRect(x: 12, y: 0, width: row.percent.frame.minX - 20, height: Self.rowHeight)
            y += Self.rowHeight + Self.rowSpacing
        }
        footer.frame = CGRect(x: 0, y: y, width: bounds.width, height: 18)
    }
}
