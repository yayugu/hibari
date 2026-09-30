import UIKit

final class EmojiPickerViewController: UIViewController {
    private enum Item: Hashable {
        case unicode(String)
        case custom(EmojiCatalog.Entry)

        var reaction: String {
            switch self {
            case .unicode(let emoji): emoji
            case .custom(let entry): ":\(entry.name):"
            }
        }
    }

    private struct Section {
        let title: String
        let items: [Item]
    }

    static let commonEmojis = [
        "👍", "❤️", "😆", "🤔", "😮", "🎉", "💢", "😥", "😇", "🍮",
        "🙏", "👀", "🥺", "😭", "🤣", "😂", "🥰", "😍", "😊", "🤗",
        "😢", "😱", "🤯", "🫠", "😎", "🙌", "👏", "💪", "🔥", "✨",
        "💯", "⭐", "🆗", "🙆", "🙅", "💦", "💤", "🍣", "🍺", "☕",
    ]

    private let emojis: EmojiCatalog
    private let recent: [String]
    private let imagePipeline: ImagePipeline
    private let aspects: EmojiAspectStore
    private let hidesSensitive: Bool
    private let onPick: (String) -> Void
    private let searchField = UISearchTextField()
    private let layout = EmojiPickerLayout()
    private lazy var collectionView = UICollectionView(frame: .zero, collectionViewLayout: layout)
    private var browseSections: [Section] = []
    private var sections: [Section] = []
    private var generation = 0
    private var prefetches: [IndexPath: ImageTask] = [:]
    private var learnedAspects: [IndexPath: Float] = [:]

    /// `recent`: the account's recently used emojis (`RecentReactions`). `hidesSensitive`:
    /// leaves out sensitive custom emojis (for a note that does not take them).
    init(emojis: EmojiCatalog, recent: [String], imagePipeline: ImagePipeline, aspects: EmojiAspectStore = .shared,
         hidesSensitive: Bool = false, onPick: @escaping (String) -> Void) {
        self.emojis = emojis
        self.recent = recent
        self.imagePipeline = imagePipeline
        self.aspects = aspects
        self.hidesSensitive = hidesSensitive
        self.onPick = onPick
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .pageSheet
        if let sheet = sheetPresentationController {
            sheet.detents = [.medium(), .large()]
            sheet.prefersGrabberVisible = true
            sheet.prefersScrollingExpandsWhenScrolledToEdge = true
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.accessibilityIdentifier = "emojiPicker"

        searchField.placeholder = "絵文字を検索"
        searchField.returnKeyType = .done
        searchField.autocorrectionType = .no
        searchField.autocapitalizationType = .none
        searchField.accessibilityIdentifier = "emojiPicker.search"
        searchField.addAction(UIAction { [weak self] _ in self?.searchChanged() }, for: .editingChanged)
        searchField.addAction(UIAction { [weak self] _ in self?.searchField.resignFirstResponder() },
                              for: .editingDidEndOnExit)
        view.addSubview(searchField)

        collectionView.backgroundColor = .clear
        collectionView.keyboardDismissMode = .onDrag
        collectionView.register(EmojiCell.self, forCellWithReuseIdentifier: EmojiCell.reuseIdentifier)
        collectionView.register(SectionHeader.self, forSupplementaryViewOfKind: UICollectionView.elementKindSectionHeader,
                                withReuseIdentifier: SectionHeader.reuseIdentifier)
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.prefetchDataSource = self
        view.addSubview(collectionView)

        browseSections = makeBrowseSections()
        show(browseSections)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let bounds = view.bounds
        searchField.frame = CGRect(x: 16, y: 20, width: bounds.width - 32, height: 36)
        let top = searchField.frame.maxY + 8
        collectionView.frame = CGRect(x: 0, y: top, width: bounds.width, height: bounds.height - top)
        if !learnedAspects.isEmpty {
            layout.updateAspects(learnedAspects)
            learnedAspects.removeAll()
        }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        aspects.save()
    }

    private func makeBrowseSections() -> [Section] {
        var sections: [Section] = []
        let recent = self.recent.compactMap(item(for:))
        if !recent.isEmpty {
            sections.append(Section(title: "最近使ったもの", items: recent))
        }
        sections.append(Section(title: "絵文字", items: Self.commonEmojis.map(Item.unicode)))
        for category in emojis.categories {
            let entries = category.entries.filter(offers)
            if !entries.isEmpty {
                sections.append(Section(title: category.name, items: entries.map(Item.custom)))
            }
        }
        return sections
    }

    private func offers(_ entry: EmojiCatalog.Entry) -> Bool {
        !hidesSensitive || entry.isSensitive != true
    }

    private func item(for reaction: String) -> Item? {
        guard let name = ReactionKey.customName(reaction) else { return .unicode(reaction) }
        return emojis.entry(named: name).flatMap { offers($0) ? .custom($0) : nil }
    }

    private func searchChanged() {
        let query = searchField.text ?? ""
        if query.trimmingCharacters(in: .whitespaces).isEmpty {
            show(browseSections)
        } else {
            var items: [Item] = []
            if Self.isEmoji(query) {
                items.append(.unicode(query.trimmingCharacters(in: .whitespaces)))
            }
            items += emojis.search(query).filter(offers).map(Item.custom)
            show([Section(title: items.isEmpty ? "見つかりませんでした" : "検索結果", items: items)])
        }
        collectionView.setContentOffset(.zero, animated: false)
    }

    private func show(_ newSections: [Section]) {
        sections = newSections
        generation += 1
        for task in prefetches.values { task.cancel() }
        prefetches.removeAll()
        learnedAspects.removeAll()
        layout.setAspects(newSections.map { section in
            section.items.map { item in
                guard case .custom(let entry) = item else { return 0 }
                return aspects.aspect(of: entry.url) ?? 0
            }
        })
        collectionView.reloadData()
    }

    private func item(at indexPath: IndexPath) -> Item? {
        guard sections.indices.contains(indexPath.section),
              sections[indexPath.section].items.indices.contains(indexPath.item)
        else { return nil }
        return sections[indexPath.section].items[indexPath.item]
    }

    private func imageRequest(for entry: EmojiCatalog.Entry) -> ImageRequest {
        let height = layout.metrics.imageHeight
        return ImageRequest(url: entry.url, size: CGSize(width: height * EmojiPickerLayout.Metrics.maxAspect, height: height),
                            scale: traitCollection.displayScale, mode: .fitted)
    }

    private func learn(_ image: CGImage, url: String, at indexPath: IndexPath, generation: Int) {
        let aspect = Float(image.width) / Float(image.height)
        aspects.record(aspect, for: url)
        guard generation == self.generation, let current = layout.aspect(at: indexPath),
              layout.metrics.span(forAspect: aspect) != layout.metrics.span(forAspect: current)
        else { return }
        learnedAspects[indexPath] = aspect
        view.setNeedsLayout()
    }

    /// A single unicode emoji (possibly a ZWJ sequence), as typed with the emoji keyboard.
    static func isEmoji(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard trimmed.count == 1, let character = trimmed.first else { return false }
        return character.unicodeScalars.contains { $0.properties.isEmojiPresentation }
            || (character.unicodeScalars.first?.properties.isEmoji == true && character.unicodeScalars.count > 1)
    }
}

extension EmojiPickerViewController: UICollectionViewDataSource, UICollectionViewDelegate {
    func numberOfSections(in collectionView: UICollectionView) -> Int {
        sections.count
    }

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        sections[section].items.count
    }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: EmojiCell.reuseIdentifier,
                                                      for: indexPath) as! EmojiCell
        switch sections[indexPath.section].items[indexPath.item] {
        case .unicode(let emoji):
            cell.show(emoji)
        case .custom(let entry):
            let generation = self.generation
            cell.show(entry, request: imageRequest(for: entry), imagePipeline: imagePipeline,
                      scale: traitCollection.displayScale) { [weak self] image in
                self?.learn(image, url: entry.url, at: indexPath, generation: generation)
            }
        }
        return cell
    }

    func collectionView(_ collectionView: UICollectionView, viewForSupplementaryElementOfKind kind: String,
                        at indexPath: IndexPath) -> UICollectionReusableView {
        let header = collectionView.dequeueReusableSupplementaryView(
            ofKind: kind, withReuseIdentifier: SectionHeader.reuseIdentifier, for: indexPath) as! SectionHeader
        header.label.text = sections[indexPath.section].title
        return header
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        let reaction = sections[indexPath.section].items[indexPath.item].reaction
        let onPick = self.onPick
        dismiss(animated: true)
        onPick(reaction)
    }
}

extension EmojiPickerViewController: UICollectionViewDataSourcePrefetching {
    func collectionView(_ collectionView: UICollectionView, prefetchItemsAt indexPaths: [IndexPath]) {
        let generation = self.generation
        for indexPath in indexPaths where prefetches[indexPath] == nil {
            guard case .custom(let entry) = item(at: indexPath) else { continue }
            let request = imageRequest(for: entry)
            if let image = imagePipeline.cachedImage(for: request) {
                learn(image, url: entry.url, at: indexPath, generation: generation)
                continue
            }
            prefetches[indexPath] = imagePipeline.load(request, priority: .low) { [weak self] image in
                guard let self, generation == self.generation else { return }
                prefetches[indexPath] = nil
                if let image {
                    learn(image, url: entry.url, at: indexPath, generation: generation)
                }
            }
        }
    }

    func collectionView(_ collectionView: UICollectionView, cancelPrefetchingForItemsAt indexPaths: [IndexPath]) {
        for indexPath in indexPaths {
            prefetches.removeValue(forKey: indexPath)?.cancel()
        }
    }
}

private final class EmojiCell: UICollectionViewCell {
    static let reuseIdentifier = "EmojiCell"

    private let label = UILabel()
    private let imageView = UIImageView()
    private var task: ImageTask?
    private var url: String?

    override init(frame: CGRect) {
        super.init(frame: frame)
        label.font = .systemFont(ofSize: 28)
        label.textAlignment = .center
        contentView.addSubview(label)
        imageView.contentMode = .scaleAspectFit
        contentView.addSubview(imageView)
        let highlight = UIView()
        highlight.backgroundColor = .hibari(.chipBackground)
        highlight.layer.cornerRadius = 10
        selectedBackgroundView = highlight
        isAccessibilityElement = true
        accessibilityTraits = .button
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func prepareForReuse() {
        super.prepareForReuse()
        task?.cancel()
        task = nil
        url = nil
        imageView.image = nil
        label.text = nil
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        label.frame = contentView.bounds
        layoutImage()
    }

    private func layoutImage() {
        guard let image = imageView.image else { return }
        let bounds = contentView.bounds
        var size = image.size
        let available = bounds.width - 2 * EmojiPickerLayout.Metrics.wideImageInset
        if size.width > available {
            size = CGSize(width: available, height: size.height * available / size.width)
        }
        let scale = image.scale
        imageView.frame = CGRect(x: ((bounds.width - size.width) / 2 * scale).rounded() / scale,
                                 y: ((bounds.height - size.height) / 2 * scale).rounded() / scale,
                                 width: size.width, height: size.height)
    }

    func show(_ emoji: String) {
        label.text = emoji
        accessibilityLabel = emoji
    }

    /// `onLoad`: with the image, once it is there (at once if it is cached).
    func show(_ entry: EmojiCatalog.Entry, request: ImageRequest, imagePipeline: ImagePipeline, scale: CGFloat,
              onLoad: @escaping (CGImage) -> Void) {
        accessibilityLabel = entry.name
        url = entry.url
        if let image = imagePipeline.cachedImage(for: request) {
            setImage(image, scale: scale)
            onLoad(image)
            return
        }
        task = imagePipeline.load(request) { [weak self] image in
            guard let self, self.url == entry.url, let image else { return }
            setImage(image, scale: scale)
            onLoad(image)
        }
    }

    private func setImage(_ image: CGImage, scale: CGFloat) {
        imageView.image = UIImage(cgImage: image, scale: scale, orientation: .up)
        setNeedsLayout()
    }
}

private final class SectionHeader: UICollectionReusableView {
    static let reuseIdentifier = "SectionHeader"
    let label = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        label.textColor = .hibari(.secondaryText)
        addSubview(label)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        label.frame = bounds.insetBy(dx: 16, dy: 0)
    }
}
