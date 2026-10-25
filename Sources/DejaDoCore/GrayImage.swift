import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// A small greyscale picture: one byte per pixel, row by row from the top left.
///
/// This is what the vision fallback compares. Colour adds little for finding
/// a control again, and one channel keeps recorded crops small enough to live
/// inside the task's JSON.
public struct GrayImage: Equatable {
    public let width: Int
    public let height: Int
    public var pixels: [UInt8]
    /// Pixels per point, so positions convert to and from window coordinates.
    public var scale: Double

    public init(width: Int, height: Int, pixels: [UInt8], scale: Double = 1) {
        precondition(width >= 0 && height >= 0 && pixels.count == width * height, "pixel count must be width × height")
        self.width = width
        self.height = height
        self.pixels = pixels
        self.scale = scale
    }

    /// A flat image, mainly for tests.
    public init(width: Int, height: Int, fill: UInt8 = 0, scale: Double = 1) {
        self.init(width: width, height: height, pixels: [UInt8](repeating: fill, count: width * height), scale: scale)
    }

    public var isEmpty: Bool { width == 0 || height == 0 }

    public subscript(x: Int, y: Int) -> UInt8 {
        get { pixels[y * width + x] }
        set { pixels[y * width + x] = newValue }
    }

    /// The part of the image inside the rectangle, clipped to its edges.
    public func cropped(x: Int, y: Int, width w: Int, height h: Int) -> GrayImage {
        let x0 = max(0, x), y0 = max(0, y)
        let x1 = min(width, x + w), y1 = min(height, y + h)
        guard x1 > x0, y1 > y0 else { return GrayImage(width: 0, height: 0, pixels: [], scale: scale) }
        var out = [UInt8]()
        out.reserveCapacity((x1 - x0) * (y1 - y0))
        for row in y0..<y1 {
            out.append(contentsOf: pixels[(row * width + x0)..<(row * width + x1)])
        }
        return GrayImage(width: x1 - x0, height: y1 - y0, pixels: out, scale: scale)
    }

    /// Resampled to a new size. Shrinking averages every source pixel that
    /// falls in a target pixel, so fine text doesn't alias into noise.
    public func resized(width w: Int, height h: Int) -> GrayImage {
        let newScale = width > 0 ? scale * Double(w) / Double(width) : scale
        guard w > 0, h > 0, !isEmpty else { return GrayImage(width: max(0, w), height: max(0, h), fill: 0, scale: newScale) }
        if w == width && h == height { return self }
        var out = [UInt8](repeating: 0, count: w * h)
        let sx = Double(width) / Double(w), sy = Double(height) / Double(h)
        for ty in 0..<h {
            let fy0 = Double(ty) * sy, fy1 = fy0 + sy
            for tx in 0..<w {
                let fx0 = Double(tx) * sx, fx1 = fx0 + sx
                if sx <= 1 && sy <= 1 {
                    // Enlarging: bilinear.
                    let cx = min(Double(width - 1), max(0, (Double(tx) + 0.5) * sx - 0.5))
                    let cy = min(Double(height - 1), max(0, (Double(ty) + 0.5) * sy - 0.5))
                    let x0 = Int(cx), y0 = Int(cy)
                    let x1 = min(width - 1, x0 + 1), y1 = min(height - 1, y0 + 1)
                    let ax = cx - Double(x0), ay = cy - Double(y0)
                    let top = Double(self[x0, y0]) * (1 - ax) + Double(self[x1, y0]) * ax
                    let bottom = Double(self[x0, y1]) * (1 - ax) + Double(self[x1, y1]) * ax
                    out[ty * w + tx] = UInt8(max(0, min(255, (top * (1 - ay) + bottom * ay).rounded())))
                    continue
                }
                // Shrinking: area average.
                var sum = 0.0, area = 0.0
                var yy = Int(fy0)
                while Double(yy) < fy1 && yy < height {
                    let wy = min(fy1, Double(yy + 1)) - max(fy0, Double(yy))
                    var xx = Int(fx0)
                    while Double(xx) < fx1 && xx < width {
                        let wx = min(fx1, Double(xx + 1)) - max(fx0, Double(xx))
                        let a = wx * wy
                        sum += Double(self[xx, yy]) * a
                        area += a
                        xx += 1
                    }
                    yy += 1
                }
                out[ty * w + tx] = UInt8(max(0, min(255, (sum / max(area, 1e-9)).rounded())))
            }
        }
        return GrayImage(width: w, height: h, pixels: out, scale: newScale)
    }

    /// Same picture at a different pixels-per-point scale.
    public func rescaled(to newScale: Double) -> GrayImage {
        guard scale > 0, abs(newScale - scale) > 1e-6 else { return self }
        let f = newScale / scale
        return resized(width: max(1, Int((Double(width) * f).rounded())), height: max(1, Int((Double(height) * f).rounded())))
    }

    public var mean: Double {
        guard !pixels.isEmpty else { return 0 }
        var s = 0
        for p in pixels { s += Int(p) }
        return Double(s) / Double(pixels.count)
    }

    /// Standard deviation of brightness. Near zero means a flat area with
    /// nothing distinctive to match on.
    public var contrast: Double {
        guard !pixels.isEmpty else { return 0 }
        let m = mean
        var s = 0.0
        for p in pixels { let d = Double(p) - m; s += d * d }
        return (s / Double(pixels.count)).squareRoot()
    }

    /// Each pixel replaced by the average of the square around it.
    public func blurred(radius r: Int) -> GrayImage {
        guard !isEmpty, r > 0 else { return self }
        let sat = summedArea()
        let sw = width + 1
        var out = [UInt8](repeating: 0, count: pixels.count)
        for y in 0..<height {
            let y0 = max(0, y - r), y1 = min(height, y + r + 1)
            for x in 0..<width {
                let x0 = max(0, x - r), x1 = min(width, x + r + 1)
                let s = sat[y1 * sw + x1] - sat[y0 * sw + x1] - sat[y1 * sw + x0] + sat[y0 * sw + x0]
                out[y * width + x] = UInt8((Double(s) / Double((x1 - x0) * (y1 - y0))).rounded())
            }
        }
        return GrayImage(width: width, height: height, pixels: out, scale: scale)
    }

    /// Fine detail only: each pixel minus the average around it, centred on
    /// 128. Removes broad shapes (every icon is "a dark square on a light
    /// background") and keeps the strokes that tell one icon from another.
    public func highPassed(radius r: Int = 2) -> GrayImage {
        guard !isEmpty, r > 0 else { return self }
        let avg = blurred(radius: r)
        var out = [UInt8](repeating: 128, count: pixels.count)
        for i in 0..<pixels.count {
            out[i] = UInt8(max(0, min(255, Int(pixels[i]) - Int(avg.pixels[i]) + 128)))
        }
        return GrayImage(width: width, height: height, pixels: out, scale: scale)
    }

    private func summedArea() -> [Int] {
        let sw = width + 1
        var sat = [Int](repeating: 0, count: sw * (height + 1))
        for y in 0..<height {
            var row = 0
            for x in 0..<width {
                row += Int(pixels[y * width + x])
                sat[(y + 1) * sw + x + 1] = sat[y * sw + x + 1] + row
            }
        }
        return sat
    }

    /// Average difference per pixel from 0 (same) to 1 (inverted), after
    /// bringing the other image to this size. Used to tell whether a screen changed.
    public func difference(from other: GrayImage) -> Double {
        guard !isEmpty, !other.isEmpty else { return isEmpty == other.isEmpty ? 0 : 1 }
        let o = (other.width == width && other.height == height) ? other : other.resized(width: width, height: height)
        var s = 0
        for i in 0..<pixels.count { s += abs(Int(pixels[i]) - Int(o.pixels[i])) }
        return Double(s) / Double(pixels.count) / 255
    }
}

extension GrayImage: Codable {
    private enum CodingKeys: String, CodingKey { case width, height, scale, data }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let w = try c.decode(Int.self, forKey: .width)
        let h = try c.decode(Int.self, forKey: .height)
        let s = try c.decodeIfPresent(Double.self, forKey: .scale) ?? 1
        let b64 = try c.decode(String.self, forKey: .data)
        guard let data = Data(base64Encoded: b64), data.count == w * h, w >= 0, h >= 0 else {
            throw DecodingError.dataCorruptedError(forKey: .data, in: c, debugDescription: "image data doesn't match its size")
        }
        self.init(width: w, height: h, pixels: [UInt8](data), scale: s)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(width, forKey: .width)
        try c.encode(height, forKey: .height)
        try c.encode(scale, forKey: .scale)
        try c.encode(Data(pixels).base64EncodedString(), forKey: .data)
    }
}
