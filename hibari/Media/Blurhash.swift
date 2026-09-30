import CoreGraphics
import Foundation

enum Blurhash {
    /// Placeholder size in pixels; stretched to the slot.
    static let defaultSize = 24

    nonisolated(unsafe) private static let cache = NSCache<NSString, ImageBox>()  // NSCache is thread-safe
    private static let queue = DispatchQueue(label: "hibari.blurhash", qos: .userInitiated)

    private static func cacheKey(_ hash: String, size: Int) -> NSString {
        "\(size)#\(hash)" as NSString
    }

    /// Memory cache only; cheap enough for the main thread.
    static func cachedImage(for hash: String, size: Int = defaultSize) -> CGImage? {
        cache.object(forKey: cacheKey(hash, size: size))?.image
    }

    /// Decodes (≈0.1ms at the default size) and caches. Keep off the main thread.
    static func image(for hash: String, size: Int = defaultSize) -> CGImage? {
        if let hit = cachedImage(for: hash, size: size) { return hit }
        guard let image = decode(hash, width: size, height: size) else { return nil }
        cache.setObject(ImageBox(image), forKey: cacheKey(hash, size: size))
        return image
    }

    /// Decodes in the background and calls back on the main thread.
    static func load(_ hash: String, completion: @escaping @MainActor @Sendable (CGImage?) -> Void) {
        queue.async {
            let image = image(for: hash).map(ImageBox.init)
            Task { @MainActor in completion(image?.image) }
        }
    }

    static func prefetch(_ hashes: [String]) {
        guard !hashes.isEmpty else { return }
        queue.async {
            for hash in hashes { _ = image(for: hash) }
        }
    }

    static func decode(_ hash: String, width: Int, height: Int, punch: Float = 1) -> CGImage? {
        let chars = Array(hash.utf8)
        guard chars.count >= 6, let sizeFlag = decode83(chars[0..<1]) else { return nil }
        let numY = (sizeFlag / 9) + 1
        let numX = (sizeFlag % 9) + 1
        guard chars.count == 4 + 2 * numX * numY,
              let quantisedMax = decode83(chars[1..<2])
        else { return nil }
        let maxValue = Float(quantisedMax + 1) / 166

        var colors: [(Float, Float, Float)] = []
        colors.reserveCapacity(numX * numY)
        for i in 0..<(numX * numY) {
            if i == 0 {
                guard let value = decode83(chars[2..<6]) else { return nil }
                colors.append(decodeDC(value))
            } else {
                let start = 4 + i * 2
                guard let value = decode83(chars[start..<(start + 2)]) else { return nil }
                colors.append(decodeAC(value, maximumValue: maxValue * punch))
            }
        }

        let bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 255, count: bytesPerRow * height)
        var cosX = [Float](repeating: 0, count: width * numX)
        for x in 0..<width {
            for i in 0..<numX {
                cosX[x * numX + i] = cos(Float.pi * Float(x) * Float(i) / Float(width))
            }
        }
        for y in 0..<height {
            for x in 0..<width {
                var r: Float = 0, g: Float = 0, b: Float = 0
                for j in 0..<numY {
                    let cy = cos(Float.pi * Float(y) * Float(j) / Float(height))
                    for i in 0..<numX {
                        let basis = cosX[x * numX + i] * cy
                        let color = colors[i + j * numX]
                        r += color.0 * basis
                        g += color.1 * basis
                        b += color.2 * basis
                    }
                }
                let offset = y * bytesPerRow + x * 4
                pixels[offset] = linearTosRGB(b)
                pixels[offset + 1] = linearTosRGB(g)
                pixels[offset + 2] = linearTosRGB(r)
            }
        }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: bytesPerRow,
            space: Bitmap.colorSpace,
            bitmapInfo: CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.noneSkipFirst.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent
        )
    }

    private static let alphabet: [UInt8: Int] = {
        let chars = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz#$%*+,-.:;=?@[]^_{|}~".utf8)
        return Dictionary(uniqueKeysWithValues: chars.enumerated().map { ($1, $0) })
    }()

    private static func decode83(_ chars: ArraySlice<UInt8>) -> Int? {
        var value = 0
        for c in chars {
            guard let digit = alphabet[c] else { return nil }
            value = value * 83 + digit
        }
        return value
    }

    private static func decodeDC(_ value: Int) -> (Float, Float, Float) {
        (sRGBToLinear(value >> 16), sRGBToLinear((value >> 8) & 255), sRGBToLinear(value & 255))
    }

    private static func decodeAC(_ value: Int, maximumValue: Float) -> (Float, Float, Float) {
        let r = value / (19 * 19)
        let g = (value / 19) % 19
        let b = value % 19
        return (
            signPow((Float(r) - 9) / 9, 2) * maximumValue,
            signPow((Float(g) - 9) / 9, 2) * maximumValue,
            signPow((Float(b) - 9) / 9, 2) * maximumValue
        )
    }

    private static func signPow(_ value: Float, _ exp: Float) -> Float {
        copysign(pow(abs(value), exp), value)
    }

    private static func sRGBToLinear(_ value: Int) -> Float {
        let v = Float(value) / 255
        return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
    }

    private static func linearTosRGB(_ value: Float) -> UInt8 {
        let v = max(0, min(1, value))
        let s = v <= 0.0031308 ? v * 12.92 : 1.055 * pow(v, 1 / 2.4) - 0.055
        return UInt8(max(0, min(255, (s * 255 + 0.5).rounded(.down))))
    }
}
