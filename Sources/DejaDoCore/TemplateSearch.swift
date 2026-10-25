import Foundation

/// Finds where a small picture appears inside a bigger one, using normalised
/// cross correlation (NCC). NCC ignores overall brightness and contrast, so a
/// button still matches after a theme tint, a hover highlight or a dimmed window.
///
/// Searching every position at full size is slow, so the search runs coarse
/// to fine: both images are shrunk, every position is scored there, and only
/// the best few peaks are refined at full size.
public enum TemplateSearch {
    public struct Peak: Equatable {
        /// Template's top left corner in the image, in pixels.
        public let x: Int
        public let y: Int
        /// -1...1, where 1 is a perfect match.
        public let score: Double
        /// Template scale the peak was found at, relative to the recorded size.
        public let scale: Double
    }

    /// NCC of the template placed with its top left at (x, y). Only the part
    /// that overlaps the image counts, and less than 60% overlap scores 0.
    public static func score(template t: GrayImage, image: GrayImage, x: Int, y: Int) -> Double {
        let x0 = max(0, x), y0 = max(0, y)
        let x1 = min(image.width, x + t.width), y1 = min(image.height, y + t.height)
        guard x1 > x0, y1 > y0 else { return 0 }
        let n = (x1 - x0) * (y1 - y0)
        guard Double(n) >= 0.6 * Double(t.width * t.height) else { return 0 }
        var st = 0.0, si = 0.0, stt = 0.0, sii = 0.0, sti = 0.0
        for iy in y0..<y1 {
            let ty = iy - y
            var ti = ty * t.width + (x0 - x)
            var ii = iy * image.width + x0
            for _ in x0..<x1 {
                let a = Double(t.pixels[ti]), b = Double(image.pixels[ii])
                st += a; si += b; stt += a * a; sii += b * b; sti += a * b
                ti += 1; ii += 1
            }
        }
        let fn = Double(n)
        let cov = sti - st * si / fn
        let vt = stt - st * st / fn, vi = sii - si * si / fn
        guard vt > 1e-6, vi > 1e-6 else { return 0 }
        return max(-1, min(1, cov / (vt * vi).squareRoot()))
    }

    /// Best matches of the template anywhere in the image, strongest first.
    /// Both must already be at the same pixels-per-point scale.
    public static func search(template: GrayImage, in image: GrayImage, scales: [Double] = [1, 0.9, 1.1],
                              maxPeaks: Int = 6, minScore: Double = 0.45) -> [Peak] {
        guard !template.isEmpty, !image.isEmpty, template.contrast >= 2 else { return [] }
        var peaks: [Peak] = []
        for s in scales {
            let tw = max(4, Int((Double(template.width) * s).rounded()))
            let th = max(4, Int((Double(template.height) * s).rounded()))
            guard tw <= image.width, th <= image.height else { continue }
            let t = (s == 1) ? template : template.resized(width: tw, height: th)
            peaks += searchOneScale(t, image, scale: s, maxPeaks: maxPeaks)
        }
        // Same spot found at several scales: keep the best.
        peaks.sort { $0.score > $1.score }
        var kept: [Peak] = []
        let radius = max(3, min(template.width, template.height) / 3)
        for p in peaks where p.score >= minScore {
            if kept.contains(where: { abs($0.x - p.x) <= radius && abs($0.y - p.y) <= radius }) { continue }
            kept.append(p)
            if kept.count >= maxPeaks { break }
        }
        return kept
    }

    private static func searchOneScale(_ t: GrayImage, _ image: GrayImage, scale: Double, maxPeaks: Int) -> [Peak] {
        // Shrink so the template is about 12 pixels across at the coarse level.
        let factor = max(1, min(6, min(t.width, t.height) / 12))
        let ct = factor > 1 ? t.resized(width: max(2, t.width / factor), height: max(2, t.height / factor)) : t
        let ci = factor > 1 ? image.resized(width: max(1, image.width / factor), height: max(1, image.height / factor)) : image
        guard ct.width <= ci.width, ct.height <= ci.height else { return [] }

        let coarse = denseNCC(ct, ci)
        let cw = ci.width - ct.width + 1, ch = ci.height - ct.height + 1
        // Local maxima, then the strongest few.
        var candidates: [(Int, Int, Float)] = []
        let nms = max(1, min(ct.width, ct.height) / 2)
        for y in 0..<ch {
            for x in 0..<cw {
                let v = coarse[y * cw + x]
                guard v > 0.25 else { continue }
                var isMax = true
                var yy = max(0, y - nms)
                outer: while yy <= min(ch - 1, y + nms) {
                    var xx = max(0, x - nms)
                    while xx <= min(cw - 1, x + nms) {
                        let o = coarse[yy * cw + xx]
                        if o > v || (o == v && (yy * cw + xx) < (y * cw + x)) { isMax = false; break outer }
                        xx += 1
                    }
                    yy += 1
                }
                if isMax { candidates.append((x, y, v)) }
            }
        }
        candidates.sort { $0.2 > $1.2 }

        var out: [Peak] = []
        for (cx, cy, _) in candidates.prefix(maxPeaks * 2) {
            // Refine around the coarse hit at full size.
            let bx = cx * factor, by = cy * factor
            var best = (bx, by, -2.0)
            let r = factor + 1
            for y in (by - r)...(by + r) where y >= 0 && y + t.height <= image.height {
                for x in (bx - r)...(bx + r) where x >= 0 && x + t.width <= image.width {
                    let s = score(template: t, image: image, x: x, y: y)
                    if s > best.2 { best = (x, y, s) }
                }
            }
            if best.2 > -2 { out.append(Peak(x: best.0, y: best.1, score: best.2, scale: scale)) }
        }
        return out
    }

    /// NCC at every position where the template fits, using summed area
    /// tables for each window's mean and variance.
    static func denseNCC(_ t: GrayImage, _ image: GrayImage) -> [Float] {
        let tw = t.width, th = t.height, iw = image.width, ih = image.height
        let cw = iw - tw + 1, ch = ih - th + 1
        guard cw > 0, ch > 0 else { return [] }
        let n = Float(tw * th)

        var tz = [Float](repeating: 0, count: tw * th)
        let tMean = Float(t.mean)
        var tVar: Float = 0
        for i in 0..<tz.count { let d = Float(t.pixels[i]) - tMean; tz[i] = d; tVar += d * d }
        guard tVar > 1e-3 else { return [Float](repeating: 0, count: cw * ch) }

        let img = image.pixels.map(Float.init)
        // Summed area tables with a zero border.
        let sw = iw + 1
        var sum = [Double](repeating: 0, count: sw * (ih + 1))
        var sq = [Double](repeating: 0, count: sw * (ih + 1))
        for y in 0..<ih {
            var rs = 0.0, rq = 0.0
            for x in 0..<iw {
                let v = Double(img[y * iw + x])
                rs += v; rq += v * v
                sum[(y + 1) * sw + x + 1] = sum[y * sw + x + 1] + rs
                sq[(y + 1) * sw + x + 1] = sq[y * sw + x + 1] + rq
            }
        }

        var out = [Float](repeating: 0, count: cw * ch)
        img.withUnsafeBufferPointer { ip in
            tz.withUnsafeBufferPointer { tp in
                for y in 0..<ch {
                    for x in 0..<cw {
                        let a = y * sw + x, b = y * sw + x + tw, c = (y + th) * sw + x, d = (y + th) * sw + x + tw
                        let s = sum[d] - sum[b] - sum[c] + sum[a]
                        let q = sq[d] - sq[b] - sq[c] + sq[a]
                        let iVar = Float(q - s * s / Double(n))
                        guard iVar > 1e-3 else { continue }
                        var dot: Float = 0
                        for ty in 0..<th {
                            let ib = (y + ty) * iw + x, tb = ty * tw
                            for tx in 0..<tw { dot += tp[tb + tx] * ip[ib + tx] }
                        }
                        out[y * cw + x] = dot / (tVar * iVar).squareRoot()
                    }
                }
            }
        }
        return out
    }
}
