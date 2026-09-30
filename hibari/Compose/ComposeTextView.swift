import UIKit

final class ComposeTextView: UITextView, UITextViewDelegate {
    /// The text changed (and so, maybe, the height).
    var onChange: (() -> Void)?
    var onSelectionChange: (() -> Void)?
    /// Text longer than a character about to go in (pasted, dropped, dictated). Returning
    /// true keeps it out: the composer takes a note's link as a quote instead.
    var interceptsInsertion: ((String) -> Bool)?

    var placeholder: String? {
        get { placeholderLabel.text }
        set { placeholderLabel.text = newValue }
    }

    private let emojis: EmojiCatalog
    private let imagePipeline: ImagePipeline
    private let placeholderLabel = UILabel()
    private var fontSize: CGFloat = 18
    private var needsEmojiRedraw = false

    /// The text Misskey gets, emoji images written as `:name:`.
    var source: String { Self.source(of: textStorage) }

    init(emojis: EmojiCatalog, imagePipeline: ImagePipeline) {
        self.emojis = emojis
        self.imagePipeline = imagePipeline
        super.init(frame: .zero, textContainer: nil)
        backgroundColor = .clear
        isScrollEnabled = false
        textContainerInset = UIEdgeInsets(top: 8, left: 0, bottom: 8, right: 0)
        textContainer.lineFragmentPadding = 0
        allowsEditingTextAttributes = false
        dataDetectorTypes = []
        smartInsertDeleteType = .no
        spellCheckingType = .no
        tintColor = .hibari(.accent)
        delegate = self

        placeholderLabel.textColor = .hibari(.secondaryText)
        placeholderLabel.isUserInteractionEnabled = false
        addSubview(placeholderLabel)

        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (self: Self, _) in
            self.updateFont()
        }
        updateFont()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        let size = placeholderLabel.sizeThatFits(CGSize(width: bounds.width, height: .greatestFiniteMagnitude))
        let lineHeight = baseParagraph.minimumLineHeight
        placeholderLabel.frame = CGRect(x: textContainerInset.left,
                                        y: textContainerInset.top + max(0, lineHeight - size.height),
                                        width: bounds.width - textContainerInset.left - textContainerInset.right,
                                        height: size.height)
    }

    private var baseParagraph: NSParagraphStyle {
        let paragraph = NSMutableParagraphStyle()
        paragraph.minimumLineHeight = (fontSize * 1.35).rounded()
        return paragraph
    }

    private var baseAttributes: [NSAttributedString.Key: Any] {
        [.font: Typography.system(fontSize) as UIFont, .foregroundColor: UIColor.hibari(.primaryText),
         .paragraphStyle: baseParagraph]
    }

    private func updateFont() {
        fontSize = (UIFontMetrics(forTextStyle: .body).scaledValue(for: 18, compatibleWith: traitCollection)).rounded()
        placeholderLabel.font = Typography.system(fontSize) as UIFont
        forEachEmoji { attachment, _ in size(attachment) }
        redrawEmojis()
        restyle()
        setNeedsLayout()
    }

    private func restyle() {
        guard markedTextRange == nil else { return }
        convertEmojiCodes()
        var map = SourceMap()
        let source = Self.source(of: textStorage, map: &map)
        let whole = NSRange(location: 0, length: textStorage.length)
        textStorage.beginEditing()
        textStorage.addAttributes(baseAttributes, range: whole)
        for highlight in MFMParser.highlights(in: source) {
            if case .emoji = highlight.kind { continue }
            textStorage.addAttribute(.foregroundColor, value: UIColor.hibari(.accent),
                                     range: map.storageRange(highlight.range))
        }
        if needsEmojiRedraw {
            needsEmojiRedraw = false
            textStorage.edited(.editedAttributes, range: whole, changeInLength: 0)
        }
        textStorage.endEditing()
        typingAttributes = baseAttributes
        placeholderLabel.isHidden = textStorage.length > 0
    }

    private func convertEmojiCodes() {
        var map = SourceMap()
        let source = Self.source(of: textStorage, map: &map)
        guard source.contains(":") else { return }
        var replacements: [(NSRange, EmojiCatalog.Entry)] = []
        for highlight in MFMParser.highlights(in: source) {
            guard case .emoji(let name) = highlight.kind, let entry = emojis.entry(named: name) else { continue }
            let range = map.storageRange(highlight.range)
            guard range.length == highlight.range.count else { continue }
            replacements.append((range, entry))
        }
        guard !replacements.isEmpty else { return }
        var selection = selectedRange
        textStorage.beginEditing()
        for (range, entry) in replacements.sorted(by: { $0.0.location > $1.0.location }) {
            textStorage.replaceCharacters(in: range, with: emojiString(entry))
            selection = Self.adjust(selection, replacing: range, withLength: 1)
        }
        textStorage.endEditing()
        selectedRange = selection
        undoManager?.removeAllActions()
    }

    private static func adjust(_ selection: NSRange, replacing range: NSRange, withLength length: Int) -> NSRange {
        func moved(_ location: Int) -> Int {
            if location >= NSMaxRange(range) { return location - range.length + length }
            if location > range.location { return range.location + length }
            return location
        }
        let start = moved(selection.location)
        return NSRange(location: start, length: max(0, moved(NSMaxRange(selection)) - start))
    }

    /// At the cursor: a custom emoji (`:name:`) as its image, or a unicode emoji.
    func insertEmoji(_ emoji: String) {
        let piece: NSAttributedString
        if let name = ReactionKey.customName(emoji), let entry = emojis.entry(named: name) {
            piece = emojiString(entry)
        } else {
            piece = NSAttributedString(string: emoji, attributes: baseAttributes)
        }
        let range = selectedRange
        textStorage.replaceCharacters(in: range, with: piece)
        selectedRange = NSRange(location: range.location + piece.length, length: 0)
        undoManager?.removeAllActions()
        restyle()
        onChange?()
    }

    /// At the cursor, as if typed (codes of emojis become images).
    func insertPlainText(_ text: String) {
        let range = selectedRange
        textStorage.replaceCharacters(in: range, with: NSAttributedString(string: text, attributes: baseAttributes))
        selectedRange = NSRange(location: range.location + (text as NSString).length, length: 0)
        undoManager?.removeAllActions()
        restyle()
        onChange?()
    }

    private func emojiString(_ entry: EmojiCatalog.Entry) -> NSAttributedString {
        let attachment = EmojiTextAttachment(name: entry.name, url: entry.url)
        size(attachment)
        var attributes = baseAttributes
        attributes[.attachment] = attachment
        return NSAttributedString(string: "\u{FFFC}", attributes: attributes)
    }

    private func size(_ attachment: EmojiTextAttachment) {
        let height = (fontSize * 1.25).rounded()
        let descent = (fontSize * 0.25).rounded()
        var aspect: CGFloat = 1
        let url = attachment.url
        switch imagePipeline.mediaSize(for: url) {
        case .known(let size) where size.width > 0 && size.height > 0:
            aspect = size.width / size.height
        case .unknown:
            Task { [weak self, imagePipeline] in
                await imagePipeline.prepareSizes(of: [url], timeout: .seconds(10))
                guard let self, imagePipeline.mediaSize(for: url) != .unknown else { return }
                self.forEachEmoji { attachment, _ in
                    if attachment.url == url { self.size(attachment) }
                }
                self.redrawEmojis()
            }
        default:
            break
        }
        let width = min(320, max(height * 0.5, (height * min(aspect, 8)).rounded()))
        let bounds = CGRect(x: 0, y: -descent, width: width, height: height)
        guard bounds != attachment.bounds || attachment.request == nil else { return }
        attachment.bounds = bounds
        let scale = traitCollection.displayScale > 0 ? traitCollection.displayScale : 3
        let request = NoteLayout.emojiRequest(url, bounds.size, scale)
        attachment.request = request
        if let image = imagePipeline.cachedImage(for: request) {
            attachment.image = UIImage(cgImage: image, scale: scale, orientation: .up)
        } else {
            attachment.image = UIImage()
            imagePipeline.load(request) { [weak self] image in
                guard let self, let image else { return }
                self.forEachEmoji { attachment, _ in
                    guard attachment.request == request else { return }
                    attachment.image = UIImage(cgImage: image, scale: scale, orientation: .up)
                }
                self.redrawEmojis()
            }
        }
    }

    private func forEachEmoji(_ body: (EmojiTextAttachment, NSRange) -> Void) {
        textStorage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: textStorage.length)) { value, range, _ in
            if let attachment = value as? EmojiTextAttachment { body(attachment, range) }
        }
    }

    private func redrawEmojis() {
        guard markedTextRange == nil else {
            needsEmojiRedraw = true
            return
        }
        textStorage.beginEditing()
        forEachEmoji { _, range in
            textStorage.edited(.editedAttributes, range: range, changeInLength: 0)
        }
        textStorage.endEditing()
    }

    struct SourceMap {
        fileprivate var emojis: [(storage: Int, source: Int, length: Int)] = []

        /// The text view offset of a source offset: inside an emoji's `:name:`, the start of
        /// the image (or its end, `roundingUp`).
        func storageOffset(_ offset: Int, roundingUp: Bool) -> Int {
            var shift = 0
            for emoji in emojis {
                if offset >= emoji.source + emoji.length {
                    shift += emoji.length - 1
                } else if offset > emoji.source {
                    return emoji.storage + (roundingUp ? 1 : 0)
                } else {
                    break
                }
            }
            return offset - shift
        }

        func storageRange(_ range: Range<Int>) -> NSRange {
            let start = storageOffset(range.lowerBound, roundingUp: false)
            return NSRange(location: start, length: storageOffset(range.upperBound, roundingUp: true) - start)
        }
    }

    static func source(of text: NSAttributedString) -> String {
        var map = SourceMap()
        return source(of: text, map: &map)
    }

    /// Emoji images become `:name:`, with a zero-width space where MFM would otherwise
    /// not take the code for an emoji: before a letter or digit after it (`:name:abc` is
    /// text), and before it when what precedes swallows it (a URL: `https://a.b:name:`).
    /// What shows as an image is sent as one.
    static func source(of text: NSAttributedString, map: inout SourceMap) -> String {
        let source = source(of: text, separatingBefore: [], map: &map)
        guard !map.emojis.isEmpty else { return source }
        var starts = Set<Int>()
        for highlight in MFMParser.highlights(in: source) {
            if case .emoji = highlight.kind { starts.insert(highlight.range.lowerBound) }
        }
        let swallowed = Set(map.emojis.filter { !starts.contains($0.source) }.map(\.storage))
        guard !swallowed.isEmpty else { return source }
        map = SourceMap()
        return self.source(of: text, separatingBefore: swallowed, map: &map)
    }

    private static func source(of text: NSAttributedString, separatingBefore separated: Set<Int>,
                               map: inout SourceMap) -> String {
        let string = text.string as NSString
        var output = ""
        var length = 0
        text.enumerateAttribute(.attachment, in: NSRange(location: 0, length: text.length)) { value, range, _ in
            guard let attachment = value as? EmojiTextAttachment else {
                let piece = string.substring(with: range)
                output += piece
                length += piece.utf16.count
                return
            }
            for location in range.location..<NSMaxRange(range) {
                var code = separated.contains(location) ? "\u{200B}:\(attachment.name):" : ":\(attachment.name):"
                if location + 1 < string.length, let next = Unicode.Scalar(string.character(at: location + 1)),
                   next.isASCII, next.properties.isAlphabetic || ("0"..."9").contains(next) {
                    code += "\u{200B}"
                }
                map.emojis.append((location, length, code.utf16.count))
                output += code
                length += code.utf16.count
            }
        }
        return output
    }

    func textViewDidChange(_ textView: UITextView) {
        restyle()
        onChange?()
    }

    func textViewDidChangeSelection(_ textView: UITextView) {
        if markedTextRange == nil { typingAttributes = baseAttributes }
        onSelectionChange?()
    }

    func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
        guard text.count > 1, let interceptsInsertion else { return true }
        return !interceptsInsertion(text)
    }

    override func copy(_ sender: Any?) {
        guard selectedRange.length > 0 else { return super.copy(sender) }
        UIPasteboard.general.string = Self.source(of: textStorage.attributedSubstring(from: selectedRange))
    }

    override func cut(_ sender: Any?) {
        guard selectedRange.length > 0, let selection = selectedTextRange else { return super.cut(sender) }
        UIPasteboard.general.string = Self.source(of: textStorage.attributedSubstring(from: selectedRange))
        replace(selection, withText: "")
        restyle()
        onChange?()
    }

    override var accessibilityValue: String? {
        get { source }
        set {}
    }
}

final class EmojiTextAttachment: NSTextAttachment {
    let name: String
    let url: String
    fileprivate var request: ImageRequest?

    init(name: String, url: String) {
        self.name = name
        self.url = url
        super.init(data: nil, ofType: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var accessibilityLabel: String? {
        get { name }
        set {}
    }
}
