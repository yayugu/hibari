import UIKit

final class TimelineGapView: UICollectionReusableView {
    static let reuseIdentifier = "TimelineGap"

    enum State: Equatable {
        case idle
        case loading
        case failed
    }

    var onTap: (() -> Void)?

    private let spinner = UIActivityIndicatorView(style: .medium)
    private let label = UILabel()
    private let topLine = UIView()
    private let bottomLine = UIView()
    private var state = State.idle

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .hibari(.background)
        spinner.color = .hibari(.secondaryText)
        addSubview(spinner)
        label.font = .preferredFont(forTextStyle: .subheadline)
        label.adjustsFontForContentSizeCategory = true
        label.textAlignment = .center
        addSubview(label)
        for line in [topLine, bottomLine] {
            line.backgroundColor = .hibari(.separator)
            addSubview(line)
        }
        isAccessibilityElement = true
        accessibilityTraits = .button
        accessibilityIdentifier = "timeline.gap"
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped)))
        apply(.idle)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func apply(_ state: State) {
        self.state = state
        switch state {
        case .idle:
            spinner.stopAnimating()
            label.isHidden = false
            label.text = "さらに読み込む"
            label.textColor = .hibari(.accent)
        case .loading:
            spinner.startAnimating()
            label.isHidden = true
        case .failed:
            spinner.stopAnimating()
            label.isHidden = false
            label.text = "読み込めませんでした・タップで再試行"
            label.textColor = .hibari(.secondaryText)
        }
        accessibilityLabel = state == .loading ? "読み込み中" : label.text
        accessibilityValue = "\(state)"
    }

    @objc private func tapped() {
        guard state != .loading else { return }
        onTap?()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let scale = traitCollection.displayScale > 0 ? traitCollection.displayScale : 3
        spinner.center = CGPoint(x: bounds.midX, y: bounds.midY)
        label.frame = bounds.insetBy(dx: 16, dy: 0)
        topLine.frame = CGRect(x: 0, y: 0, width: bounds.width, height: 1 / scale)
        bottomLine.frame = CGRect(x: 0, y: bounds.height - 1 / scale, width: bounds.width, height: 1 / scale)
    }
}

final class NewNotesButton: UIControl {
    static let maxUsers = 3
    private static let height: CGFloat = 36
    private static let leadingPadding: CGFloat = 13.5
    private static let trailingPadding: CGFloat = 17
    static let avatarSize: CGFloat = 27
    private static let ringWidth: CGFloat = 1.5
    private static let avatarStep: CGFloat = 18
    private static let loadTimeout: Duration = .seconds(3)

    /// Newest first, at most `maxUsers`, the later ones over the earlier. Their avatars
    /// should be loaded (`loadAvatars`).
    var users: [User] = [] {
        didSet { updateUsers() }
    }

    var isLoadingAvatars: Bool { loading != nil }

    private let imagePipeline: ImagePipeline
    private let face = UIView()
    private let arrow = UIImageView()
    private let label = UILabel()
    private let avatars: [AvatarView]
    private let rings: [UIView]
    private var loading: AvatarLoad?
    private let feedback = UIImpactFeedbackGenerator(style: .light)

    init(imagePipeline: ImagePipeline) {
        self.imagePipeline = imagePipeline
        avatars = (0..<Self.maxUsers).map { _ in AvatarView(imagePipeline: imagePipeline) }
        rings = avatars.map { _ in UIView() }
        super.init(frame: .zero)
        face.isUserInteractionEnabled = false
        face.backgroundColor = .hibari(.accent)
        face.layer.shadowColor = UIColor.black.cgColor
        face.layer.shadowOpacity = 0.15
        face.layer.shadowRadius = 4
        face.layer.shadowOffset = CGSize(width: 0, height: 1)
        addSubview(face)
        arrow.image = UIImage(systemName: "arrow.up",
                              withConfiguration: UIImage.SymbolConfiguration(pointSize: 10, weight: .regular))
        arrow.tintColor = .white
        face.addSubview(arrow)
        label.text = "新しいノート"
        label.font = .systemFont(ofSize: 14, weight: .semibold)
        label.textColor = .white
        face.addSubview(label)
        for (ring, avatar) in zip(rings, avatars) {
            ring.isHidden = true
            ring.backgroundColor = .hibari(.accent)
            ring.layer.cornerRadius = Self.avatarSize / 2 + Self.ringWidth
            ring.addSubview(avatar)
            face.addSubview(ring)
        }
        accessibilityLabel = "新しいノート"
        accessibilityTraits = .button
        isAccessibilityElement = true
        accessibilityIdentifier = "timeline.newNotes"
        addAction(UIAction { [weak self] _ in self?.feedback.impactOccurred() }, for: .touchUpInside)
        updateUsers()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// Loads the avatars of the first `maxUsers` of `users`, then calls back with the ones
    /// ready to show (maybe at once): those that failed, or were still loading after
    /// `loadTimeout`, are left out. A load in progress is dropped; its completion is not
    /// called.
    func loadAvatars(of users: [User], completion: @escaping @MainActor ([User]) -> Void) {
        loading?.cancel()
        let scale = traitCollection.displayScale > 0 ? traitCollection.displayScale : 3
        let size = CGSize(width: Self.avatarSize, height: Self.avatarSize)
        let candidates = users.prefix(Self.maxUsers).compactMap { user in
            user.avatarUrl.map { (user: user, request: AvatarView.request(url: $0, size: size, scale: scale)) }
        }
        let load = AvatarLoad(candidates, pipeline: imagePipeline) { [weak self] ready in
            self?.loading = nil
            completion(ready)
        }
        loading = load
        load.start(timeout: Self.loadTimeout)
    }

    /// Drops a load in progress (`loadAvatars`); its completion is not called.
    func cancelLoading() {
        loading?.cancel()
        loading = nil
    }

    private var shownUsers: ArraySlice<User> { users.prefix(Self.maxUsers) }

    private func updateUsers() {
        let shown = shownUsers
        for (index, avatar) in avatars.enumerated() {
            rings[index].isHidden = index >= shown.count
            avatar.setURL(index < shown.count ? shown[index].avatarUrl : nil)
        }
        label.isHidden = !shown.isEmpty
        accessibilityValue = shown.isEmpty ? nil : shown.map(\.displayName).joined(separator: "、")
        setNeedsLayout()
    }

    private var spacing: CGFloat { shownUsers.isEmpty ? 4 : 5 }

    private var contentWidth: CGFloat {
        guard !shownUsers.isEmpty else {
            return ceil(label.sizeThatFits(CGSize(width: CGFloat.greatestFiniteMagnitude,
                                                  height: .greatestFiniteMagnitude)).width)
        }
        return Self.avatarSize + CGFloat(shownUsers.count - 1) * Self.avatarStep
    }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        let scale = traitCollection.displayScale > 0 ? traitCollection.displayScale : 3
        let width = Self.leadingPadding + arrow.intrinsicContentSize.width + spacing + contentWidth
            + Self.trailingPadding
        return CGSize(width: width.pixelCeil(scale: scale), height: Self.height)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let scale = traitCollection.displayScale > 0 ? traitCollection.displayScale : 3
        face.bounds = bounds
        face.center = CGPoint(x: bounds.midX, y: bounds.midY)
        face.layer.cornerRadius = bounds.height / 2
        face.layer.shadowPath = UIBezierPath(roundedRect: face.bounds, cornerRadius: bounds.height / 2).cgPath
        let arrowSize = arrow.intrinsicContentSize
        arrow.frame = CGRect(x: Self.leadingPadding, y: (bounds.height - arrowSize.height) / 2,
                             width: arrowSize.width, height: arrowSize.height).pixelAligned(scale: scale)
        let x = Self.leadingPadding + arrowSize.width + spacing
        if shownUsers.isEmpty {
            let height = ceil(label.sizeThatFits(bounds.size).height)
            label.frame = CGRect(x: x, y: (bounds.height - height) / 2, width: contentWidth, height: height)
                .pixelAligned(scale: scale)
        }
        let ringSize = Self.avatarSize + Self.ringWidth * 2
        for (index, (ring, avatar)) in zip(rings, avatars).enumerated() {
            ring.frame = CGRect(x: x + CGFloat(index) * Self.avatarStep - Self.ringWidth,
                                y: (bounds.height - ringSize) / 2, width: ringSize, height: ringSize)
                .pixelAligned(scale: scale)
            avatar.frame = CGRect(x: Self.ringWidth, y: Self.ringWidth, width: Self.avatarSize, height: Self.avatarSize)
                .pixelAligned(scale: scale)
        }
    }

    override var isHighlighted: Bool {
        didSet {
            UIView.animate(withDuration: 0.15, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction]) {
                self.face.transform = self.isHighlighted ? CGAffineTransform(scaleX: 0.95, y: 0.95) : .identity
            }
        }
    }
}

@MainActor
private final class AvatarLoad {
    private let candidates: [(user: User, request: ImageRequest)]
    private let pipeline: ImagePipeline
    private var completion: (@MainActor ([User]) -> Void)?
    private var loaded: [Bool]
    private var remaining: Int
    private var tasks: [ImageTask] = []
    private var timeout: Task<Void, Never>?

    init(_ candidates: [(user: User, request: ImageRequest)], pipeline: ImagePipeline,
         completion: @escaping @MainActor ([User]) -> Void) {
        self.candidates = candidates
        self.pipeline = pipeline
        self.completion = completion
        loaded = candidates.map { pipeline.cachedImage(for: $0.request) != nil }
        remaining = loaded.filter { !$0 }.count
    }

    func start(timeout: Duration) {
        guard remaining > 0 else { return finish() }
        for (index, candidate) in candidates.enumerated() where !loaded[index] {
            tasks.append(pipeline.load(candidate.request) { [weak self] image in
                guard let self else { return }
                loaded[index] = image != nil
                remaining -= 1
                if remaining == 0 { finish() }
            })
        }
        self.timeout = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            self?.finish()
        }
    }

    func cancel() {
        completion = nil
        stop()
    }

    private func finish() {
        guard let completion else { return }
        self.completion = nil
        stop()
        completion(zip(candidates, loaded).filter(\.1).map(\.0.user))
    }

    private func stop() {
        tasks.forEach { $0.cancel() }
        tasks = []
        timeout?.cancel()
    }
}
