import CoreGraphics

extension CGFloat {
    /// Rounds to the device pixel grid.
    func pixelAligned(scale: CGFloat) -> CGFloat {
        (self * scale).rounded() / scale
    }

    func pixelCeil(scale: CGFloat) -> CGFloat {
        (self * scale).rounded(.up) / scale
    }
}

extension CGRect {
    func pixelAligned(scale: CGFloat) -> CGRect {
        let minX = self.minX.pixelAligned(scale: scale)
        let minY = self.minY.pixelAligned(scale: scale)
        let maxX = self.maxX.pixelAligned(scale: scale)
        let maxY = self.maxY.pixelAligned(scale: scale)
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
}
