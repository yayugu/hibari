import UIKit

/// The note buttons' answer to a tap, played over the icon drawn in the note: the icon of
/// the new state does it, and a patch of `cover` hides the one underneath meanwhile.
@MainActor
enum ActionIconAnimation {
    enum Kind {
        /// The arrows wind back, whip round a full turn (flinging sparks along the way) and
        /// settle, gone green.
        case renote
        /// The arrows unwind half a turn (to the same look) and go grey.
        case undoRenote
        /// The bookmark swells and shrinks back, whichever way it went.
        case bookmark(Bool)

        var action: NoteTapAction {
            switch self {
            case .renote, .undoRenote: .renote
            case .bookmark: .bookmark
            }
        }

        /// Everything in it is done by then, sparks included.
        var duration: CFTimeInterval {
            switch self {
            case .renote: 0.72
            case .undoRenote: 0.42
            case .bookmark: 0.32
            }
        }

        /// Its sparks fly out past the row it plays in.
        var reachesOutside: Bool {
            if case .renote = self { true } else { false }
        }

        var icon: (Icon, ColorRole) {
            switch self {
            case .renote: (.renote, .renote)
            case .undoRenote: (.renote, .secondaryText)
            case .bookmark(let bookmarked): bookmarked ? (.bookmarked, .accent) : (.bookmark, .secondaryText)
            }
        }
    }

    /// `frame`: the icon's, in `host`'s coordinates. Returns the layer playing it, nil with
    /// Reduce Motion. Once done (`kind.duration`) it shows the new icon as drawn, still over
    /// the patch, until the caller takes it out.
    static func play(_ kind: Kind, frame: CGRect, cover: CGColor, palette: Palette, scale: CGFloat,
                     in host: CALayer) -> CALayer? {
        guard !UIAccessibility.isReduceMotionEnabled else { return nil }
        let (icon, role) = kind.icon
        // Sharp when it swells.
        let imageScale = scale * 2
        guard let image = IconStore.shared.image(icon, size: frame.size, role: role, palette: palette, scale: imageScale)
        else { return nil }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let container = CALayer()
        container.frame = host.bounds
        host.addSublayer(container)
        let patch = CALayer()
        patch.frame = frame.insetBy(dx: -1, dy: -1)
        patch.backgroundColor = cover
        container.addSublayer(patch)
        let iconLayer = CALayer()
        iconLayer.frame = frame
        iconLayer.contents = image
        iconLayer.contentsScale = imageScale

        let duration = kind.duration
        switch kind {
        case .renote:
            let tint = palette[.renote]
            container.addSublayer(glow(at: frame, color: tint))
            for spark in sparks(around: frame, color: tint) { container.addSublayer(spark) }
            iconLayer.add(spin(duration: duration), forKey: "spin")
        case .undoRenote:
            iconLayer.add(unwind(duration: duration), forKey: "unwind")
        case .bookmark:
            iconLayer.add(swell(duration: duration), forKey: "swell")
        }
        container.addSublayer(iconLayer)
        CATransaction.commit()
        return container
    }

    private static func spin(duration: CFTimeInterval) -> CAAnimationGroup {
        let keyTimes: [NSNumber] = [0, 0.16, 0.6, 0.8, 1]
        let timing = [CAMediaTimingFunction(name: .easeOut), CAMediaTimingFunction(controlPoints: 0.3, 0, 0.2, 1),
                      CAMediaTimingFunction(name: .easeInEaseOut), CAMediaTimingFunction(name: .easeInEaseOut)]
        let rotation = CAKeyframeAnimation(keyPath: "transform.rotation.z")
        rotation.values = [0, -0.4, 2 * CGFloat.pi + 0.28, 2 * CGFloat.pi - 0.1, 2 * CGFloat.pi]
        rotation.keyTimes = keyTimes
        rotation.timingFunctions = timing
        let scale = CAKeyframeAnimation(keyPath: "transform.scale")
        scale.values = [1, 0.75, 1.38, 0.93, 1]
        scale.keyTimes = keyTimes
        scale.timingFunctions = timing
        let group = CAAnimationGroup()
        group.animations = [rotation, scale]
        group.duration = duration
        return group
    }

    private static func unwind(duration: CFTimeInterval) -> CAAnimationGroup {
        let rotation = CABasicAnimation(keyPath: "transform.rotation.z")
        rotation.fromValue = 0
        rotation.toValue = -CGFloat.pi
        rotation.timingFunction = CAMediaTimingFunction(controlPoints: 0.4, 0, 0.2, 1)
        let scale = CAKeyframeAnimation(keyPath: "transform.scale")
        scale.values = [1, 0.8, 1]
        scale.keyTimes = [0, 0.45, 1]
        scale.timingFunctions = [CAMediaTimingFunction(name: .easeOut), CAMediaTimingFunction(name: .easeInEaseOut)]
        let group = CAAnimationGroup()
        group.animations = [rotation, scale]
        group.duration = duration
        return group
    }

    private static func swell(duration: CFTimeInterval) -> CAKeyframeAnimation {
        let scale = CAKeyframeAnimation(keyPath: "transform.scale")
        scale.values = [1, 1.6, 1]
        scale.keyTimes = [0, 0.3, 1]
        scale.timingFunctions = [CAMediaTimingFunction(name: .easeOut), CAMediaTimingFunction(name: .easeInEaseOut)]
        scale.duration = duration
        return scale
    }

    /// A soft disc that blooms behind the icon as it whips round.
    private static func glow(at frame: CGRect, color: CGColor) -> CALayer {
        let size = frame.width * 2.2
        let glow = CALayer()
        glow.frame = CGRect(x: frame.midX - size / 2, y: frame.midY - size / 2, width: size, height: size)
        glow.cornerRadius = size / 2
        glow.backgroundColor = color
        glow.opacity = 0
        let scale = CABasicAnimation(keyPath: "transform.scale")
        scale.fromValue = 0.2
        scale.toValue = 1
        scale.timingFunction = CAMediaTimingFunction(name: .easeOut)
        let opacity = CAKeyframeAnimation(keyPath: "opacity")
        opacity.values = [0, 0.22, 0]
        opacity.keyTimes = [0, 0.3, 1]
        let group = CAAnimationGroup()
        group.animations = [scale, opacity]
        group.beginTime = CACurrentMediaTime() + 0.1
        group.duration = 0.5
        glow.add(group, forKey: "glow")
        return glow
    }

    /// Dots flung off the arrows: each spirals outwards clockwise, the way they turn.
    private static func sparks(around frame: CGRect, color: CGColor) -> [CALayer] {
        let center = CGPoint(x: frame.midX, y: frame.midY)
        let count = 8
        let begin = CACurrentMediaTime() + 0.14
        return (0..<count).map { index in
            let big = index.isMultiple(of: 2)
            let size: CGFloat = big ? 4.5 : 3
            let spark = CALayer()
            spark.bounds = CGRect(x: 0, y: 0, width: size, height: size)
            spark.cornerRadius = size / 2
            spark.backgroundColor = color
            spark.position = center
            spark.opacity = 0

            let start = CGFloat(index) / CGFloat(count) * 2 * .pi
            let sweep: CGFloat = big ? 1.1 : 1.5
            let reach = frame.width * (big ? 1.45 : 1.15)
            let path = UIBezierPath()
            let steps = 12
            for step in 0...steps {
                let t = CGFloat(step) / CGFloat(steps)
                let angle = start + sweep * t
                let radius = frame.width * 0.3 + (reach - frame.width * 0.3) * (1 - (1 - t) * (1 - t))
                let point = CGPoint(x: center.x + cos(angle) * radius, y: center.y + sin(angle) * radius)
                if step == 0 { path.move(to: point) } else { path.addLine(to: point) }
            }
            let position = CAKeyframeAnimation(keyPath: "position")
            position.path = path.cgPath
            position.calculationMode = .paced
            position.timingFunction = CAMediaTimingFunction(name: .easeOut)
            let opacity = CAKeyframeAnimation(keyPath: "opacity")
            opacity.values = [0, 1, 1, 0]
            opacity.keyTimes = [0, 0.1, 0.55, 1]
            let scale = CAKeyframeAnimation(keyPath: "transform.scale")
            scale.values = [0.5, 1.2, 0.2]
            scale.keyTimes = [0, 0.3, 1]
            let group = CAAnimationGroup()
            group.animations = [position, opacity, scale]
            group.beginTime = begin + Double(index % 3) * 0.02
            group.duration = big ? 0.5 : 0.45
            spark.add(group, forKey: "spark")
            return spark
        }
    }
}
