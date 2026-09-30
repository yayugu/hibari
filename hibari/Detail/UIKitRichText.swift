import CoreText
import UIKit

@MainActor
struct UIKitRichText {
    let resolver: EmojiResolver
    let imagePipeline: ImagePipeline
    let palette: Palette
    let scale: CGFloat
    /// Where a link goes (`NoteServices.url(forLink:)`); nil leaves it plain.
    let linkURL: (String) -> URL?

    struct Result {
        let text: NSAttributedString
        /// Emoji bitmaps that were not in memory: build again once they load.
        let missingEmojis: [ImageRequest]
        /// Emojis laid out as squares because their size was not known.
        let provisionalEmojis: Set<String>
    }

    /// `simple`: text and emojis only (display names).
    func build(_ source: String, emojis: EmojiContext, font: CTFont, color: ColorRole, simple: Bool = false,
               lineHeight: CGFloat? = nil) -> Result {
        let sizer = EmojiSizer(imagePipeline)
        let builder = RichTextBuilder(palette: palette, emojiResolver: resolver, emojiContext: emojis, sizer: sizer)
        let nodes = simple ? MFMParser.parseSimple(source) : MFMParser.parse(source)
        let coreText = builder.build(nodes, style: TextStyle(font: font, color: palette[color]))
        var missing: [ImageRequest] = []
        let text = convert(coreText, lineHeight: lineHeight, missing: &missing)
        return Result(text: text, missingEmojis: missing, provisionalEmojis: sizer.provisional)
    }

    private func convert(_ source: NSAttributedString, lineHeight: CGFloat?, missing: inout [ImageRequest])
        -> NSAttributedString {
        let result = NSMutableAttributedString(string: source.string)
        let whole = NSRange(location: 0, length: source.length)
        source.enumerateAttributes(in: whole) { attributes, range, _ in
            var converted: [NSAttributedString.Key: Any] = [:]
            if let font = attributes[TextAttribute.font] {
                converted[.font] = font
            }
            if let color = attributes[TextAttribute.foregroundColor] {
                converted[.foregroundColor] = UIColor(cgColor: color as! CGColor)
            }
            if let link = attributes[TextAttribute.link] as? String {
                converted[TextAttribute.link] = link
                if let url = linkURL(link) { converted[.link] = url }
            }
            if attributes[TextAttribute.strikethrough] != nil {
                converted[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
            }
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineBreakStrategy = .standard
            if let lineHeight { paragraph.minimumLineHeight = lineHeight }
            if let flush = attributes[TextAttribute.flush] as? CGFloat, flush >= 0.5 {
                paragraph.alignment = .center
            }
            if let indent = attributes[TextAttribute.indent] as? CGFloat {
                paragraph.firstLineHeadIndent = indent
                paragraph.headIndent = indent
            }
            converted[.paragraphStyle] = paragraph
            if let emoji = attributes[TextAttribute.emoji] as? EmojiAttachment {
                let attachment = NSTextAttachment()
                let request = NoteLayout.emojiRequest(emoji.url, CGSize(width: emoji.width, height: emoji.height), scale)
                if let image = imagePipeline.cachedImage(for: request) {
                    attachment.image = UIImage(cgImage: image, scale: scale, orientation: .up)
                } else {
                    attachment.image = UIImage()
                    missing.append(request)
                }
                attachment.bounds = CGRect(x: 0, y: -emoji.descent, width: emoji.width, height: emoji.height)
                converted[.attachment] = attachment
                converted[.foregroundColor] = UIColor(cgColor: emoji.textColor)
                converted[UIKitRichText.alt] = emoji.alt
            }
            result.setAttributes(converted, range: range)
        }
        return result
    }

    static let alt = NSAttributedString.Key("HibariAlt")

    /// `text` as plain text, emojis written as `:name:`.
    static func plainText(of text: NSAttributedString) -> String {
        var output = ""
        text.enumerateAttribute(alt, in: NSRange(location: 0, length: text.length)) { value, range, _ in
            if let value = value as? String {
                output += value
            } else {
                output += (text.string as NSString).substring(with: range)
            }
        }
        return output
    }
}

final class SelectableTextView: UITextView, UITextViewDelegate {
    /// The raw link (`TextAttribute.link`) that was tapped.
    var onLink: ((String) -> Void)?

    init() {
        super.init(frame: .zero, textContainer: nil)
        isEditable = false
        isSelectable = true
        isScrollEnabled = false
        backgroundColor = .clear
        textContainerInset = .zero
        textContainer.lineFragmentPadding = 0
        linkTextAttributes = [.foregroundColor: UIColor.hibari(.accent)]
        dataDetectorTypes = []
        delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func copy(_ sender: Any?) {
        let range = selectedRange
        guard range.length > 0, let attributedText, NSMaxRange(range) <= attributedText.length else {
            super.copy(sender)
            return
        }
        UIPasteboard.general.string = UIKitRichText.plainText(of: attributedText.attributedSubstring(from: range))
    }

    func textView(_ textView: UITextView, primaryActionFor textItem: UITextItem,
                  defaultAction: UIAction) -> UIAction? {
        guard case .link = textItem.content, let attributedText,
              textItem.range.location < attributedText.length,
              let link = attributedText.attribute(TextAttribute.link, at: textItem.range.location,
                                                  effectiveRange: nil) as? String
        else { return defaultAction }
        return UIAction { [weak self] _ in self?.onLink?(link) }
    }
}
