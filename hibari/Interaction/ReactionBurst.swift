import UIKit

@MainActor
enum ReactionBurst {
    private static let emojiSize: CGFloat = 34

    /// `key` is a stored reaction key; `origin` is in window coordinates.
    static func show(_ key: String, emojis: EmojiCatalog, imagePipeline: ImagePipeline, from origin: CGRect) {
        guard !UIAccessibility.isReduceMotionEnabled,
              let window = UIApplication.shared.connectedScenes.compactMap({ ($0 as? UIWindowScene)?.keyWindow }).first
        else { return }
        let center = CGPoint(x: origin.midX, y: origin.midY)
        if let name = ReactionKey.customName(key) {
            guard let url = emojis.entry(named: name)?.url else { return }
            let scale = window.traitCollection.displayScale
            let request = ImageRequest(url: url, size: CGSize(width: emojiSize * 2, height: emojiSize),
                                       scale: scale, mode: .aspectFit)
            if let image = imagePipeline.cachedImage(for: request) {
                play(imageView(image, scale: scale), at: center, in: window)
            } else {
                let started = Date()
                imagePipeline.load(request) { image in
                    guard let image, Date().timeIntervalSince(started) < 0.4 else { return }
                    play(imageView(image, scale: scale), at: center, in: window)
                }
            }
        } else {
            let label = UILabel()
            label.text = key
            label.font = .systemFont(ofSize: emojiSize * 0.85)
            label.sizeToFit()
            play(label, at: center, in: window)
        }
    }

    private static func imageView(_ image: CGImage, scale: CGFloat) -> UIImageView {
        let view = UIImageView(image: UIImage(cgImage: image, scale: scale, orientation: .up))
        view.contentMode = .scaleAspectFit
        view.bounds.size = CGSize(width: emojiSize * 2, height: emojiSize)
        return view
    }

    private static func play(_ emoji: UIView, at center: CGPoint, in window: UIWindow) {
        emoji.isUserInteractionEnabled = false
        emoji.center = center
        emoji.transform = CGAffineTransform(scaleX: 0.3, y: 0.3)
        emoji.alpha = 0
        window.addSubview(emoji)

        let ring = CAShapeLayer()
        let radius: CGFloat = 26
        ring.path = UIBezierPath(ovalIn: CGRect(x: -radius, y: -radius, width: radius * 2, height: radius * 2)).cgPath
        ring.position = center
        ring.fillColor = nil
        ring.strokeColor = UIColor.hibari(.accent).cgColor
        ring.lineWidth = 2
        ring.opacity = 0
        window.layer.addSublayer(ring)
        let grow = CABasicAnimation(keyPath: "transform.scale")
        grow.fromValue = 0.3
        grow.toValue = 1.2
        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.values = [0.8, 0.5, 0]
        let group = CAAnimationGroup()
        group.animations = [grow, fade]
        group.duration = 0.45
        group.timingFunction = CAMediaTimingFunction(name: .easeOut)
        ring.add(group, forKey: "burst")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { ring.removeFromSuperlayer() }

        UIView.animate(withDuration: 0.42, delay: 0, usingSpringWithDamping: 0.5, initialSpringVelocity: 0.8) {
            emoji.alpha = 1
            emoji.transform = CGAffineTransform(translationX: 0, y: -34).scaledBy(x: 1.3, y: 1.3)
        }
        UIView.animate(withDuration: 0.3, delay: 0.45, options: [.curveEaseIn]) {
            emoji.alpha = 0
            emoji.transform = CGAffineTransform(translationX: 0, y: -52).scaledBy(x: 0.9, y: 0.9)
        } completion: { _ in
            emoji.removeFromSuperview()
        }
    }
}
