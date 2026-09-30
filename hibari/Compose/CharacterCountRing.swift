import UIKit

final class CharacterCountRing: UIView {
    static let warningZone = 20
    private static let warning = UIColor(red: 1, green: 0.83, blue: 0, alpha: 1)
    private static let error = UIColor(red: 0.96, green: 0.13, blue: 0.18, alpha: 1)

    private static let diameter: CGFloat = 28
    private let ring = UIView()
    private let track = CAShapeLayer()
    private let bar = CAShapeLayer()
    private let label = UILabel()
    private var remaining = Int.max
    private var share: CGFloat = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        ring.isUserInteractionEnabled = false
        addSubview(ring)
        let path = UIBezierPath(arcCenter: CGPoint(x: Self.diameter / 2, y: Self.diameter / 2),
                                radius: Self.diameter / 2 - 1.5, startAngle: -.pi / 2, endAngle: .pi * 1.5,
                                clockwise: true).cgPath
        for layer in [track, bar] {
            layer.fillColor = nil
            layer.lineCap = .round
            layer.lineWidth = 2.5
            layer.frame = CGRect(x: 0, y: 0, width: Self.diameter, height: Self.diameter)
            layer.path = path
            ring.layer.addSublayer(layer)
        }
        ring.transform = Self.ringTransform(warning: false)
        bar.strokeEnd = 0
        label.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        label.textAlignment = .center
        addSubview(label)
        isAccessibilityElement = true
        accessibilityIdentifier = "compose.count"
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (self: Self, _) in self.applyColors() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: CGSize { CGSize(width: 30, height: 30) }

    func update(count: Int, limit: Int) {
        let remaining = limit - count
        let share = CGFloat(min(count, limit)) / CGFloat(max(1, limit))
        guard remaining != self.remaining || share != self.share else { return }
        let wasWarning = self.remaining <= Self.warningZone
        self.remaining = remaining
        self.share = share
        bar.strokeEnd = share
        label.text = remaining <= Self.warningZone ? "\(remaining)" : nil
        accessibilityLabel = "残り文字数"
        accessibilityValue = "\(remaining)"
        applyColors()
        ring.isHidden = remaining < -9
        let isWarning = remaining <= Self.warningZone
        if wasWarning != isWarning {
            UIView.animate(withDuration: 0.4, delay: 0, usingSpringWithDamping: 0.55, initialSpringVelocity: 0) {
                self.ring.transform = Self.ringTransform(warning: isWarning)
            }
        }
    }

    private static func ringTransform(warning: Bool) -> CGAffineTransform {
        warning ? .identity : CGAffineTransform(scaleX: 20 / diameter, y: 20 / diameter)
    }

    private func applyColors() {
        track.strokeColor = UIColor.hibari(.border).resolvedColor(with: traitCollection).cgColor
        let color: UIColor = remaining <= 0 ? Self.error : remaining <= Self.warningZone ? Self.warning : .hibari(.accent)
        bar.strokeColor = color.resolvedColor(with: traitCollection).cgColor
        label.textColor = remaining <= 0 ? Self.error : .hibari(.secondaryText)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        ring.bounds = CGRect(x: 0, y: 0, width: Self.diameter, height: Self.diameter)
        ring.center = CGPoint(x: bounds.midX, y: bounds.midY)
        label.frame = bounds.insetBy(dx: -12, dy: 0)
    }
}
