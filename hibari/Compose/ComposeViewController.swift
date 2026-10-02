import PhotosUI
import UIKit

final class ComposeViewController: UIViewController {
    static let maxAttachments = 16

    private let services: NoteServices
    private let client: MisskeyClient
    private let reply: Note?
    private var quote: Note?
    private var visibility: NoteVisibility
    private let recipientIDs: [String]
    private var recipientNames: [String: String] = [:]
    private var attachments: [ComposeAttachment] = []
    private var isPosting = false {
        didSet { updateState() }
    }
    private var loadingQuote = false
    private var didFocus = false

    private let topBar = UIView()
    private let cancelButton = UIButton(type: .system)
    private let postButton = UIButton(configuration: .filled())
    private let scrollView = UIScrollView()
    private let replyTarget: ReplyTargetView?
    private let avatar = UIImageView()
    private let visibilityButton = UIButton(configuration: .plain())
    private let addressLabel = UILabel()
    private let textView: ComposeTextView
    private let attachmentStrip = AttachmentStripView()
    private let quoteView = QuoteView()
    private let removeQuoteButton = UIButton(configuration: .filled())
    private let toolbar = UIView()
    private let toolbarLine = UIView()
    private let photoButton = UIButton(type: .system)
    private let emojiButton = UIButton(type: .system)
    private let countRing = CharacterCountRing()
    private var avatarTask: ImageTask?

    private static let padding: CGFloat = 16
    private static let avatarSize: CGFloat = 40
    private static let columnX = padding + avatarSize + 12
    private static let topBarHeight: CGFloat = 52
    private static let toolbarHeight: CGFloat = 48

    /// `recipient`: a direct note to them.
    init(services: NoteServices, client: MisskeyClient, reply: Note? = nil, quote: Note? = nil, recipient: User? = nil) {
        self.services = services
        self.client = client
        self.reply = reply
        self.quote = quote
        if let recipient {
            visibility = .specified
            recipientIDs = [recipient.id]
            recipientNames[recipient.id] = recipient.acct
        } else {
            visibility = NoteVisibility.remembered(for: services.account)
                .narrowed(to: reply.flatMap(NoteVisibility.init(of:)))
                .narrowed(to: quote.flatMap(NoteVisibility.init(of:)))
            recipientIDs = visibility == .specified
                ? reply?.directRecipientIDs(excluding: services.account.userID) ?? [] : []
            if let reply { recipientNames[reply.user.id] = reply.user.acct }
        }
        replyTarget = reply.map { ReplyTargetView(note: $0, services: services) }
        textView = ComposeTextView(emojis: services.emojis, imagePipeline: services.imagePipeline)
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .fullScreen
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private var isDirect: Bool { visibility == .specified }

    private var showsAddress: Bool { reply != nil || isDirect }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .hibari(.background)
        view.accessibilityIdentifier = "compose"

        configureTopBar()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.alwaysBounceVertical = true
        scrollView.keyboardDismissMode = .interactive
        let backgroundTap = UITapGestureRecognizer(target: self, action: #selector(backgroundTapped))
        backgroundTap.delegate = self
        scrollView.addGestureRecognizer(backgroundTap)
        view.addSubview(scrollView)

        if let replyTarget { scrollView.addSubview(replyTarget) }
        avatar.layer.cornerRadius = Self.avatarSize / 2
        avatar.clipsToBounds = true
        avatar.backgroundColor = .hibari(.mediaPlaceholder)
        scrollView.addSubview(avatar)
        visibilityButton.showsMenuAsPrimaryAction = true
        visibilityButton.accessibilityIdentifier = "compose.visibility"
        visibilityButton.layer.borderWidth = 1
        visibilityButton.layer.cornerCurve = .continuous
        scrollView.addSubview(visibilityButton)
        if showsAddress {
            addressLabel.lineBreakMode = .byTruncatingTail
            addressLabel.accessibilityIdentifier = "compose.address"
            scrollView.addSubview(addressLabel)
            updateAddress()
            loadRecipientNames()
        }

        textView.placeholder = reply != nil ? "返信をノート" : isDirect ? "メッセージを入力"
            : quote != nil ? "コメントを追加" : "いまどうしてる？"
        textView.accessibilityIdentifier = "compose.text"
        textView.onChange = { [weak self] in self?.textDidChange() }
        textView.onSelectionChange = { [weak self] in self?.scrollToCaret() }
        textView.interceptsInsertion = { [weak self] text in self?.quoteIfNoteLink(text) ?? false }
        scrollView.addSubview(textView)

        attachmentStrip.leadingInset = Self.columnX
        attachmentStrip.onRemove = { [weak self] attachment in self?.remove(attachment) }
        scrollView.addSubview(attachmentStrip)

        quoteView.isUserInteractionEnabled = false
        quoteView.accessibilityIdentifier = "compose.quote"
        scrollView.addSubview(quoteView)
        var remove = UIButton.Configuration.filled()
        remove.image = UIImage(systemName: "xmark",
                               withConfiguration: UIImage.SymbolConfiguration(pointSize: 11, weight: .bold))
        remove.baseBackgroundColor = .hibari(.secondaryText)
        remove.baseForegroundColor = .hibari(.background)
        remove.cornerStyle = .capsule
        remove.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 6, bottom: 6, trailing: 6)
        removeQuoteButton.configuration = remove
        removeQuoteButton.accessibilityLabel = "引用をやめる"
        removeQuoteButton.accessibilityIdentifier = "compose.quote.remove"
        removeQuoteButton.addAction(UIAction { [weak self] _ in
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            self?.setQuote(nil)
        }, for: .touchUpInside)
        scrollView.addSubview(removeQuoteButton)

        configureToolbar()
        NSLayoutConstraint.activate([
            topBar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            topBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            topBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            topBar.heightAnchor.constraint(equalToConstant: Self.topBarHeight),
            scrollView.topAnchor.constraint(equalTo: topBar.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: toolbar.topAnchor),
            toolbar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            toolbar.heightAnchor.constraint(equalToConstant: Self.toolbarHeight),
            toolbar.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),
        ])

        loadAvatar()
        setQuote(quote)
        updateVisibility()
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (self: Self, _) in
            self.visibilityButton.layer.borderColor = UIColor.hibari(.border).resolvedColor(with: self.traitCollection).cgColor
        }
        updateState()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        if !didFocus {
            didFocus = true
            textView.becomeFirstResponder()
        }
    }

    private func configureTopBar() {
        topBar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(topBar)
        var cancel = UIButton.Configuration.plain()
        var cancelTitle = AttributedString("キャンセル")
        cancelTitle.font = .systemFont(ofSize: 17)
        cancel.attributedTitle = cancelTitle
        cancel.baseForegroundColor = .hibari(.primaryText)
        cancel.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8)
        cancelButton.configuration = cancel
        cancelButton.accessibilityIdentifier = "compose.cancel"
        cancelButton.addAction(UIAction { [weak self] _ in self?.cancelTapped() }, for: .touchUpInside)
        topBar.addSubview(cancelButton)

        var post = UIButton.Configuration.filled()
        var postTitle = AttributedString(reply != nil ? "返信" : isDirect ? "送信" : "ノート")
        postTitle.font = .systemFont(ofSize: 15, weight: .bold)
        post.attributedTitle = postTitle
        post.cornerStyle = .capsule
        post.contentInsets = NSDirectionalEdgeInsets(top: 7, leading: 16, bottom: 7, trailing: 16)
        post.imagePadding = 6
        postButton.configuration = post
        postButton.configurationUpdateHandler = { button in
            guard var configuration = button.configuration else { return }
            let enabled = button.isEnabled || configuration.showsActivityIndicator
            configuration.baseBackgroundColor = UIColor.hibari(.accent).withAlphaComponent(enabled ? 1 : 0.5)
            configuration.baseForegroundColor = UIColor.white.withAlphaComponent(enabled ? 1 : 0.7)
            configuration.background.backgroundColor = configuration.baseBackgroundColor
            button.configuration = configuration
        }
        postButton.accessibilityIdentifier = "compose.post"
        postButton.addAction(UIAction { [weak self] _ in self?.post() }, for: .touchUpInside)
        topBar.addSubview(postButton)
    }

    private func configureToolbar() {
        toolbar.translatesAutoresizingMaskIntoConstraints = false
        toolbar.backgroundColor = .hibari(.background)
        view.addSubview(toolbar)
        toolbarLine.backgroundColor = .hibari(.separator)
        toolbar.addSubview(toolbarLine)
        let symbol = UIImage.SymbolConfiguration(pointSize: 20, weight: .regular)
        photoButton.setImage(UIImage(systemName: "photo", withConfiguration: symbol), for: .normal)
        photoButton.accessibilityLabel = "写真を追加"
        photoButton.accessibilityIdentifier = "compose.photo"
        photoButton.addAction(UIAction { [weak self] _ in self?.pickPhotos() }, for: .touchUpInside)
        emojiButton.setImage(UIImage(systemName: "face.smiling", withConfiguration: symbol), for: .normal)
        emojiButton.accessibilityLabel = "絵文字"
        emojiButton.accessibilityIdentifier = "compose.emoji"
        emojiButton.addAction(UIAction { [weak self] _ in self?.pickEmoji() }, for: .touchUpInside)
        for button in [photoButton, emojiButton] {
            button.tintColor = .hibari(.accent)
            toolbar.addSubview(button)
        }
        toolbar.addSubview(countRing)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let width = view.bounds.width
        let cancelSize = cancelButton.sizeThatFits(CGSize(width: 200, height: Self.topBarHeight))
        cancelButton.frame = CGRect(x: Self.padding - 8, y: (Self.topBarHeight - cancelSize.height) / 2,
                                    width: cancelSize.width, height: cancelSize.height)
        let postSize = postButton.sizeThatFits(CGSize(width: 200, height: 36))
        postButton.frame = CGRect(x: width - Self.padding - postSize.width, y: (Self.topBarHeight - postSize.height) / 2,
                                  width: postSize.width, height: postSize.height)

        let scale = traitCollection.displayScale > 0 ? traitCollection.displayScale : 3
        toolbarLine.frame = CGRect(x: 0, y: 0, width: width, height: 1 / scale)
        photoButton.frame = CGRect(x: Self.padding - 10, y: 0, width: 44, height: Self.toolbarHeight)
        emojiButton.frame = CGRect(x: photoButton.frame.maxX + 4, y: 0, width: 44, height: Self.toolbarHeight)
        countRing.frame = CGRect(x: width - Self.padding - 36, y: (Self.toolbarHeight - 36) / 2, width: 36, height: 36)
        layoutContent()
    }

    private func layoutContent() {
        let width = scrollView.bounds.width
        guard width > 0 else { return }
        let column = width - Self.columnX - Self.padding
        var y: CGFloat = 4
        if let replyTarget {
            let height = replyTarget.height(for: width)
            replyTarget.frame = CGRect(x: 0, y: y, width: width, height: height)
            y += height
        }
        avatar.frame = CGRect(x: Self.padding, y: y, width: Self.avatarSize, height: Self.avatarSize)
        let pill = visibilityButton.sizeThatFits(CGSize(width: column, height: 32))
        visibilityButton.frame = CGRect(x: Self.columnX, y: y + (Self.avatarSize - 30) / 2, width: pill.width, height: 30)
        visibilityButton.layer.cornerRadius = 15
        y += Self.avatarSize + 2
        if showsAddress {
            let height = ceil(addressLabel.sizeThatFits(CGSize(width: column, height: 40)).height)
            addressLabel.frame = CGRect(x: Self.columnX, y: y, width: column, height: height)
            y += height
        }
        let minimumTextHeight: CGFloat = attachments.isEmpty && quote == nil ? 80 : 0
        let textHeight = max(minimumTextHeight,
                             ceil(textView.sizeThatFits(CGSize(width: column, height: .greatestFiniteMagnitude)).height))
        textView.frame = CGRect(x: Self.columnX, y: y, width: column, height: textHeight)
        y += textHeight + 8

        let stripHeight = attachmentStrip.height(columnWidth: column)
        attachmentStrip.isHidden = stripHeight == 0
        attachmentStrip.frame = CGRect(x: 0, y: y, width: width, height: stripHeight)
        if stripHeight > 0 { y += stripHeight + 12 }

        quoteView.isHidden = quote == nil
        removeQuoteButton.isHidden = quote == nil
        if quote != nil {
            if column != quoteWidth { configureQuoteView() }
            let height = quoteView.layout(width: column, apply: false)
            quoteView.frame = CGRect(x: Self.columnX, y: y, width: column, height: height)
            let size = removeQuoteButton.sizeThatFits(CGSize(width: 44, height: 44))
            removeQuoteButton.frame = CGRect(x: quoteView.frame.maxX - size.width - 8, y: y + 8,
                                             width: size.width, height: size.height)
            y += height + 12
        }
        scrollView.contentSize = CGSize(width: width, height: y + 16)
    }

    private func scrollToCaret() {
        guard textView.isFirstResponder, let position = textView.selectedTextRange?.end else { return }
        view.layoutIfNeeded()
        let caret = textView.convert(textView.caretRect(for: position), to: scrollView)
        scrollView.scrollRectToVisible(caret.insetBy(dx: 0, dy: -12), animated: false)
    }

    @objc private func backgroundTapped() {
        guard !textView.isFirstResponder else { return }
        textView.becomeFirstResponder()
        textView.selectedRange = NSRange(location: textView.textStorage.length, length: 0)
    }

    private var textLength: Int { NoteText.length(textView.source) }

    private var canPost: Bool {
        let length = textLength
        return !isPosting && !loadingQuote && length <= services.maxNoteTextLength
            && (length > 0 || !attachments.isEmpty)
    }

    private func textDidChange() {
        updateState()
        view.setNeedsLayout()
        view.layoutIfNeeded()
        scrollToCaret()
    }

    private func updateState() {
        countRing.update(count: textLength, limit: services.maxNoteTextLength)
        postButton.isEnabled = canPost
        var configuration = postButton.configuration
        configuration?.showsActivityIndicator = isPosting
        postButton.configuration = configuration
        photoButton.isEnabled = !isPosting && attachments.count < Self.maxAttachments
        emojiButton.isEnabled = !isPosting
        textView.isEditable = !isPosting
        cancelButton.isEnabled = !isPosting
        attachmentStrip.isEditable = !isPosting
        removeQuoteButton.isEnabled = !isPosting
        visibilityButton.isEnabled = !isPosting
    }

    private var widestVisibility: NoteVisibility {
        NoteVisibility.public.narrowed(to: reply.flatMap(NoteVisibility.init(of:)))
            .narrowed(to: quote.flatMap(NoteVisibility.init(of:)))
    }

    private func updateVisibility() {
        visibility = visibility.narrowed(to: widestVisibility)
        var configuration = UIButton.Configuration.plain()
        var title = AttributedString(visibility.title)
        title.font = .systemFont(ofSize: 14, weight: .bold)
        configuration.attributedTitle = title
        configuration.image = UIImage(systemName: visibility.symbol,
                                      withConfiguration: UIImage.SymbolConfiguration(pointSize: 12, weight: .bold))
        configuration.imagePadding = 4
        configuration.baseForegroundColor = .hibari(.accent)
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12)
        visibilityButton.configuration = configuration
        visibilityButton.layer.borderColor = UIColor.hibari(.border).resolvedColor(with: traitCollection).cgColor
        visibilityButton.accessibilityLabel = "公開範囲"
        visibilityButton.accessibilityValue = visibility.title
        guard !isDirect else {
            visibilityButton.menu = nil
            visibilityButton.isUserInteractionEnabled = false
            visibilityButton.accessibilityTraits = .staticText
            view.setNeedsLayout()
            return
        }
        let widest = widestVisibility
        visibilityButton.menu = UIMenu(title: "公開範囲", children: NoteVisibility.pickable.map { option in
            UIAction(title: option.title, subtitle: option.subtitle, image: UIImage(systemName: option.symbol),
                     attributes: option.isNoWiderThan(widest) ? [] : .disabled,
                     state: option == visibility ? .on : .off) { [weak self] _ in
                guard let self else { return }
                UISelectionFeedbackGenerator().selectionChanged()
                self.visibility = option
                NoteVisibility.remember(option, for: self.services.account)
                self.updateVisibility()
            }
        })
        view.setNeedsLayout()
    }

    private func loadAvatar() {
        guard let url = services.account.avatarUrl else { return }
        let scale = traitCollection.displayScale > 0 ? traitCollection.displayScale : 3
        let request = ImageRequest(url: url, size: CGSize(width: Self.avatarSize, height: Self.avatarSize), scale: scale,
                                   shape: .circle)
        if let image = services.imagePipeline.cachedImage(for: request) {
            avatar.image = UIImage(cgImage: image, scale: scale, orientation: .up)
            return
        }
        avatarTask = services.imagePipeline.load(request) { [weak self] image in
            guard let image else { return }
            self?.avatar.image = UIImage(cgImage: image, scale: scale, orientation: .up)
        }
    }

    private func updateAddress() {
        let plain: [NSAttributedString.Key: Any] = [
            .foregroundColor: UIColor.hibari(.secondaryText), .font: UIFont.systemFont(ofSize: 15),
        ]
        let accent: [NSAttributedString.Key: Any] = [
            .foregroundColor: UIColor.hibari(.accent), .font: UIFont.systemFont(ofSize: 15),
        ]
        let text = NSMutableAttributedString(string: isDirect ? "宛先: " : "返信先: ", attributes: plain)
        if !isDirect, let reply {
            text.append(NSAttributedString(string: reply.user.acct, attributes: accent))
        } else if recipientIDs.isEmpty {
            text.append(NSAttributedString(string: "自分だけ", attributes: plain))
        } else {
            let names = recipientIDs.compactMap { recipientNames[$0] }
            text.append(NSAttributedString(string: names.joined(separator: " "), attributes: accent))
            let unknown = recipientIDs.count - names.count
            if unknown > 0 {
                text.append(NSAttributedString(string: names.isEmpty ? "\(unknown)人" : " ほか\(unknown)人",
                                               attributes: plain))
            }
        }
        addressLabel.attributedText = text
    }

    private func loadRecipientNames() {
        let unknown = recipientIDs.filter { recipientNames[$0] == nil }
        guard isDirect, !unknown.isEmpty else { return }
        Task { [weak self, client] in
            guard let users = try? await client.users(ids: unknown), let self else { return }
            for user in users { self.recipientNames[user.id] = user.acct }
            self.updateAddress()
            self.view.setNeedsLayout()
        }
    }

    private func setQuote(_ note: Note?) {
        quote = note
        configureQuoteView()
        updateVisibility()
        updateState()
        view.setNeedsLayout()
    }

    private var quoteWidth: CGFloat = 0

    private func configureQuoteView() {
        guard let note = quote else { return }
        let scale = traitCollection.displayScale > 0 ? traitCollection.displayScale : 3
        quoteWidth = max(40, view.bounds.width - Self.columnX - Self.padding)
        let text = UIKitRichText(resolver: services.engine.emojiResolver, imagePipeline: services.imagePipeline,
                                 palette: Palette.palette(for: ThemeStyle(traitCollection.userInterfaceStyle)),
                                 scale: scale, linkURL: { _ in nil })
        let header = NSMutableAttributedString(attributedString: text.build(
            note.user.displayName, emojis: .name(of: note.user), font: Typography.system(15, bold: true),
            color: .primaryText, simple: true).text)
        header.append(NSAttributedString(string: " \(note.user.acct)", attributes: [
            .font: UIFont.systemFont(ofSize: 15), .foregroundColor: UIColor.hibari(.secondaryText),
        ]))
        let body = (note.cw ?? note.text).map {
            text.build($0, emojis: .text(of: note), font: Typography.system(15), color: .primaryText).text
        }
        quoteView.configure(header: header, body: body, note: note, width: quoteWidth, fileFontSize: 14,
                            revealsSensitiveMedia: services.sensitiveMedia == .show,
                            imagePipeline: services.imagePipeline, scale: scale)
    }

    private func quoteIfNoteLink(_ text: String) -> Bool {
        guard quote == nil, !loadingQuote, let noteID = NoteText.linkedNoteID(text, server: client.server) else {
            return false
        }
        loadingQuote = true
        updateState()
        Task { [weak self, client] in
            let note = try? await client.note(noteID)
            guard let self else { return }
            self.loadingQuote = false
            if let note, note.canBeRenoted(by: self.services.account) {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                self.setQuote(note)
            } else {
                self.textView.insertPlainText(text)
            }
            self.updateState()
        }
        return true
    }

    private func pickPhotos() {
        let room = Self.maxAttachments - attachments.count
        guard room > 0 else { return }
        #if DEBUG
        if AppSettings.composeSampleImages > 0 {
            addSampleImages(min(room, AppSettings.composeSampleImages))
            return
        }
        #endif
        var configuration = PHPickerConfiguration()
        configuration.filter = .images
        configuration.selectionLimit = room
        configuration.selection = .ordered
        configuration.preferredAssetRepresentationMode = .current
        let picker = PHPickerViewController(configuration: configuration)
        picker.delegate = self
        present(picker, animated: true)
    }

    private func add(_ attachment: ComposeAttachment) {
        attachments.append(attachment)
        attachment.onChange = { [weak self, weak attachment] in
            guard let self, let attachment else { return }
            self.attachmentStrip.update(attachment)
            self.view.setNeedsLayout()
        }
        attachmentStrip.show(attachments)
        updateState()
        view.setNeedsLayout()
    }

    private func remove(_ attachment: ComposeAttachment) {
        guard !isPosting else { return }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        attachment.cancel()
        attachments.removeAll { $0 === attachment }
        attachmentStrip.show(attachments)
        updateState()
        UIView.animate(withDuration: 0.25) {
            self.view.setNeedsLayout()
            self.view.layoutIfNeeded()
        }
    }

    #if DEBUG
    private func addSampleImages(_ count: Int) {
        for index in 0..<count {
            let data = SampleImage.png(width: index % 2 == 0 ? 1200 : 900, height: index % 2 == 0 ? 900 : 1200,
                                       hue: CGFloat(attachments.count + index) / 7)
            add(ComposeAttachment(name: "sample\(attachments.count + 1)", client: client) { data })
        }
    }
    #endif

    private func pickEmoji() {
        let picker = EmojiPickerViewController(emojis: services.emojis, recent: services.recentReactions.all,
                                               imagePipeline: services.imagePipeline) { [weak self] emoji in
            self?.services.recentReactions.add(emoji)
            self?.textView.insertEmoji(emoji)
            self?.textView.becomeFirstResponder()
        }
        picker.presentationController?.delegate = self
        present(picker, animated: true)
    }

    private func post() {
        guard canPost else { return }
        isPosting = true
        let text = NoteText.trimmed(textView.source)
        let attachments = self.attachments
        let draft = NoteDraft(text: text.isEmpty ? nil : text, visibility: visibility,
                              visibleUserIDs: isDirect ? recipientIDs : [], replyID: reply?.id, renoteID: quote?.id)
        let sent = isDirect ? "ダイレクトを送信しました" : "ノートを送信しました"
        Task { [weak self, client] in
            do {
                var draft = draft
                for attachment in attachments {
                    do {
                        draft.fileIDs.append(try await attachment.file().id)
                    } catch {
                        throw UploadFailure()
                    }
                }
                let note = try await client.createNote(draft)
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                self?.services.didPost(note)
                self?.dismiss(animated: true) {
                    Toast.show(sent)
                }
            } catch {
                guard let self else { return }
                self.isPosting = false
                UINotificationFeedbackGenerator().notificationOccurred(.error)
                if (error as? MisskeyAPIError)?.isAuthenticationFailure == true {
                    self.services.onAuthenticationFailure?()
                }
                let message = (error as? LocalizedError)?.errorDescription ?? "ノートを送信できませんでした"
                let alert = UIAlertController(title: "送信できませんでした", message: message, preferredStyle: .alert)
                alert.addAction(UIAlertAction(title: "OK", style: .default))
                self.present(alert, animated: true)
            }
        }
    }

    private struct UploadFailure: LocalizedError {
        var errorDescription: String? { "画像をアップロードできませんでした" }
    }

    private func cancelTapped() {
        let hasContent = !NoteText.trimmed(textView.source).isEmpty || !attachments.isEmpty
        guard hasContent else {
            close()
            return
        }
        let sheet = UIAlertController(title: nil, message: nil, preferredStyle: .actionSheet)
        sheet.addAction(UIAlertAction(title: "破棄", style: .destructive) { [weak self] _ in self?.close() })
        sheet.addAction(UIAlertAction(title: "キャンセル", style: .cancel))
        sheet.popoverPresentationController?.sourceView = cancelButton
        present(sheet, animated: true)
    }

    private func close() {
        attachments.forEach { $0.cancel() }
        textView.resignFirstResponder()
        dismiss(animated: true)
    }
}

extension ComposeViewController: PHPickerViewControllerDelegate {
    func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        picker.dismiss(animated: true)
        for result in results.prefix(Self.maxAttachments - attachments.count) {
            add(ComposeAttachment(result.itemProvider, client: client))
        }
        textView.becomeFirstResponder()
    }
}

extension ComposeViewController: UIGestureRecognizerDelegate {
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        touch.view === scrollView
    }
}

extension ComposeViewController: UIAdaptivePresentationControllerDelegate {
    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
        textView.becomeFirstResponder()
    }
}

final class ReplyTargetView: UIView {
    private let note: Note
    private let services: NoteServices
    private let avatar = UIImageView()
    private let header = UILabel()
    private let body = UILabel()
    private let threadLine = UIView()
    private var avatarTask: ImageTask?
    private var didReloadEmojis = false

    private static let padding: CGFloat = 16
    private static let avatarSize: CGFloat = 40

    init(note: Note, services: NoteServices) {
        self.note = note
        self.services = services
        super.init(frame: .zero)
        avatar.layer.cornerRadius = Self.avatarSize / 2
        avatar.clipsToBounds = true
        avatar.backgroundColor = .hibari(.mediaPlaceholder)
        addSubview(avatar)
        header.lineBreakMode = .byTruncatingTail
        addSubview(header)
        body.numberOfLines = 4
        addSubview(body)
        threadLine.backgroundColor = .hibari(.border)
        threadLine.layer.cornerRadius = 1
        addSubview(threadLine)
        isAccessibilityElement = true
        accessibilityIdentifier = "compose.replyTarget"
        accessibilityLabel = "返信先: \(note.user.displayName)、\(note.cw ?? note.text ?? "")"
        reloadText()
        loadAvatar()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private var columnX: CGFloat { Self.padding + Self.avatarSize + 12 }

    func height(for width: CGFloat) -> CGFloat {
        let column = width - columnX - Self.padding
        let headerHeight = ceil(header.sizeThatFits(CGSize(width: column, height: 100)).height)
        let bodyHeight = body.attributedText.map { $0.length > 0 } == true
            ? ceil(body.sizeThatFits(CGSize(width: column, height: .greatestFiniteMagnitude)).height) : 0
        return max(Self.avatarSize, headerHeight + 2 + bodyHeight) + 20
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let column = bounds.width - columnX - Self.padding
        avatar.frame = CGRect(x: Self.padding, y: 0, width: Self.avatarSize, height: Self.avatarSize)
        let headerHeight = ceil(header.sizeThatFits(CGSize(width: column, height: 100)).height)
        header.frame = CGRect(x: columnX, y: 0, width: column, height: headerHeight)
        let bodyHeight = ceil(body.sizeThatFits(CGSize(width: column, height: .greatestFiniteMagnitude)).height)
        body.frame = CGRect(x: columnX, y: headerHeight + 2, width: column, height: bodyHeight)
        threadLine.frame = CGRect(x: Self.padding + Self.avatarSize / 2 - 1, y: Self.avatarSize + 4, width: 2,
                                  height: max(0, bounds.height - Self.avatarSize - 8))
    }

    private func reloadText() {
        let scale = traitCollection.displayScale > 0 ? traitCollection.displayScale : 3
        let text = UIKitRichText(resolver: services.engine.emojiResolver, imagePipeline: services.imagePipeline,
                                 palette: Palette.palette(for: ThemeStyle(traitCollection.userInterfaceStyle)),
                                 scale: scale, linkURL: { _ in nil })
        let name = text.build(note.user.displayName, emojis: .name(of: note.user), font: Typography.system(15, bold: true),
                              color: .primaryText, simple: true)
        let headerText = NSMutableAttributedString(attributedString: name.text)
        headerText.append(NSAttributedString(string: " \(note.user.acct)", attributes: [
            .font: UIFont.systemFont(ofSize: 15), .foregroundColor: UIColor.hibari(.secondaryText),
        ]))
        header.attributedText = headerText
        var missing = name.missingEmojis
        if let content = note.cw ?? note.text {
            let built = text.build(content, emojis: .text(of: note), font: Typography.system(15), color: .primaryText)
            body.attributedText = built.text
            missing += built.missingEmojis
        } else if !note.files.isEmpty {
            body.attributedText = NSAttributedString(string: "ファイル \(note.files.count) 件", attributes: [
                .font: UIFont.systemFont(ofSize: 15), .foregroundColor: UIColor.hibari(.secondaryText),
            ])
        }
        guard !missing.isEmpty, !didReloadEmojis else { return }
        didReloadEmojis = true
        let group = DispatchGroup()
        for request in missing {
            group.enter()
            services.imagePipeline.load(request) { _ in group.leave() }
        }
        group.notify(queue: .main) { [weak self] in
            MainActor.assumeIsolated {
                self?.reloadText()
                self?.setNeedsLayout()
            }
        }
    }

    private func loadAvatar() {
        guard let url = note.user.avatarUrl else { return }
        let scale = traitCollection.displayScale > 0 ? traitCollection.displayScale : 3
        let request = ImageRequest(url: url, size: CGSize(width: Self.avatarSize, height: Self.avatarSize), scale: scale,
                                   shape: .circle)
        if let image = services.imagePipeline.cachedImage(for: request) {
            avatar.image = UIImage(cgImage: image, scale: scale, orientation: .up)
            return
        }
        avatarTask = services.imagePipeline.load(request) { [weak self] image in
            guard let image else { return }
            self?.avatar.image = UIImage(cgImage: image, scale: scale, orientation: .up)
        }
    }
}

#if DEBUG
enum SampleImage {
    static func png(width: Int, height: Int, hue: CGFloat) -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format).image { context in
            UIColor(hue: hue.truncatingRemainder(dividingBy: 1), saturation: 0.6, brightness: 0.9, alpha: 1).setFill()
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
        return image.pngData() ?? Data()
    }
}
#endif
