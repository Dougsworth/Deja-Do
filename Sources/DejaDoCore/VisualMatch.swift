import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// One line of text read off the screen, in window points from the top left.
public struct OCRLine: Codable, Equatable {
    public var text: String
    public var frame: CGRect
    public var confidence: Double?

    public init(text: String, frame: CGRect, confidence: Double? = nil) {
        self.text = text
        self.frame = frame
        self.confidence = confidence
    }

    var center: CGPoint { CGPoint(x: frame.midX, y: frame.midY) }
}

/// What the screen looked like around a click, for apps that don't describe
/// their buttons through Accessibility: canvas apps, games, custom drawn UIs
/// and virtual machine windows.
public struct VisualTarget: Codable, Equatable {
    /// Greyscale pixels around the click.
    public var crop: GrayImage
    /// The crop's top left corner, in window points.
    public var cropOrigin: CGPoint
    /// Where the click landed, in window points.
    public var click: CGPoint
    /// The line of text the click landed on, if any.
    public var clickedText: OCRLine?
    /// Lines of text around the click, with their offset from it.
    public var nearby: [Anchor]
    /// Window size when recorded.
    public var windowSize: CGSize?

    public init(crop: GrayImage, cropOrigin: CGPoint, click: CGPoint, clickedText: OCRLine?,
                nearby: [Anchor], windowSize: CGSize?) {
        self.crop = crop
        self.cropOrigin = cropOrigin
        self.click = click
        self.clickedText = clickedText
        self.nearby = nearby
        self.windowSize = windowSize
    }

    public static let anchorRole = "OCRText"

    /// Builds the record for a click from a picture of the whole window and
    /// the text read off it.
    /// - Parameters:
    ///   - window: the window's pixels; its `scale` says how many pixels make a point.
    ///   - lines: text read from the same picture, in window points.
    ///   - click: click position in window points.
    ///   - cropSize: side of the square kept around the click, in points.
    public static func make(window: GrayImage, lines: [OCRLine], click: CGPoint, windowSize: CGSize?,
                            cropSize: Double = 64) -> VisualTarget {
        let s = window.scale
        let half = cropSize / 2
        let px = Int(((Double(click.x) - half) * s).rounded()), py = Int(((Double(click.y) - half) * s).rounded())
        let side = Int((cropSize * s).rounded())
        var crop = window.cropped(x: px, y: py, width: side, height: side)
        let origin = CGPoint(x: Double(max(0, px)) / s, y: Double(max(0, py)) / s)
        // Keep stored crops at one pixel per point: Retina doubles the size for no gain in matching.
        if s > 1.01 { crop = crop.rescaled(to: 1) }

        let clicked = lineAt(click, in: lines)
        var picks: [(Anchor, Double)] = []
        var seen = Set<String>()
        if let c = clicked { seen.insert(TextSimilarity.normalize(c.text)) }
        for line in lines {
            let key = TextSimilarity.normalize(line.text)
            guard key.count >= 2, line.text.count <= 60, !seen.contains(key), line != clicked else { continue }
            let offset = CGPoint(x: line.center.x - click.x, y: line.center.y - click.y)
            let d = Double(hypot(offset.x, offset.y))
            guard d <= 260 else { continue }
            seen.insert(key)
            picks.append((Anchor(label: line.text, role: anchorRole, offset: offset), d))
        }
        let nearby = picks.sorted { $0.1 < $1.1 }.prefix(6).map(\.0)
        return VisualTarget(crop: crop, cropOrigin: origin, click: click, clickedText: clicked,
                            nearby: Array(nearby), windowSize: windowSize)
    }

    /// The text line under a point, allowing a few points of slack because
    /// people click just beside short labels.
    public static func lineAt(_ p: CGPoint, in lines: [OCRLine], slack: CGFloat = 6) -> OCRLine? {
        let hits = lines.filter { $0.frame.insetBy(dx: -slack, dy: -slack).contains(p) }
        return hits.min { a, b in
            let da = hypot(a.center.x - p.x, a.center.y - p.y), db = hypot(b.center.x - p.x, b.center.y - p.y)
            return da < db
        }
    }

    /// Click point relative to the crop's top left, in points.
    var clickInCrop: CGPoint { CGPoint(x: click.x - cropOrigin.x, y: click.y - cropOrigin.y) }
}

extension ElementLocator {
    /// True when the screen is a better guide than the accessibility tree:
    /// the click was recorded only by position, or it landed on one big
    /// unlabelled element, like the guest screen of a virtual machine or a
    /// drawing canvas, where Accessibility can only say "somewhere in here".
    public var prefersVisual: Bool {
        guard visual != nil else { return false }
        if role == "AXPosition" { return true }
        guard !hasText, (anchors ?? []).isEmpty else { return false }
        guard let f = frameInWindow else { return true }
        return f.width * f.height >= 40_000
    }
}

// MARK: - Matching

public enum VisualSignal: String, CaseIterable {
    case text, anchor, image, spatial
}

public struct VisualCandidate: Equatable {
    /// Where to click, in window points.
    public let point: CGPoint
    public let score: Double
    public let parts: [VisualSignal: Double]
    /// Which evidence proposed this spot first.
    public let source: VisualSignal
}

public enum VisualDecision: Equatable {
    case confident(VisualCandidate)
    case ambiguous([VisualCandidate])
    case notFound([VisualCandidate])
}

public struct VisualReport {
    public let decision: VisualDecision
    public let candidates: [VisualCandidate]
    /// How far the text around the target moved, if it could tell.
    public let shift: CGVector?

    public var best: VisualCandidate? { candidates.first }
}

/// Finds a recorded click spot again from a picture of the window and the
/// text on it.
///
/// Spots are proposed three ways: the clicked label found again by OCR,
/// the surrounding labels agreeing on how far things moved, and the recorded
/// crop found again by template matching. Each spot is then scored on all
/// the evidence (label under it, agreement with the surrounding labels, how
/// well the pixels match, and distance from where it should be) and the
/// decision looks at the margin over the next distinct spot, just like the
/// accessibility engine, so two lookalike buttons are never guessed between.
public struct VisualMatcher {
    public var weights: [VisualSignal: Double] = [.text: 4, .anchor: 2.5, .image: 3, .spatial: 1]
    public var acceptScore = 0.72
    public var requiredMargin = 0.08
    public var plausibleScore = 0.45
    /// Two spots closer than this are the same spot.
    public var distinctDistance: CGFloat = 20

    public init() {}

    public func match(_ t: VisualTarget, window: GrayImage, lines: [OCRLine], windowSize: CGSize?) -> VisualReport {
        let fits = Self.locateAnchors(t, lines: lines)
        let shift = Self.estimateShift(fits)
        // A label that shows exactly once is strong evidence on its own.
        let strongLabelMatches = t.clickedText.map { c in
            lines.filter { (TextSimilarity.similarity(c.text, $0.text) ?? 0) >= 0.9 }.count
        } ?? 0
        let template = t.crop.rescaled(to: window.scale)
        let texture = t.crop.contrast
        // Detail only versions, to tell lookalike icons apart.
        // Softened a little first so a slightly softer rendering (a scaled
        // VM viewer, another display) doesn't wipe the detail out.
        let fineTemplate = texture >= 6 ? Self.detail(template) : template
        let fineWindow = texture >= 6 ? Self.detail(window) : window
        // The few points right under the click. Lookalike buttons (a row of round
        // operator keys, a toolbar of same-shaped icons) share almost everything in
        // the wider picture and differ only here, so this part has to match too.
        // Both lightly softened, so a slightly softer rendering still lines up.
        let core = Self.core(of: template, clickInCrop: t.clickInCrop, scale: window.scale)
        let softWindow = core == nil ? window : window.blurred(radius: 1)

        // 1. Propose spots.
        var proposals: [(CGPoint, VisualSignal)] = []
        if let clicked = t.clickedText {
            for line in lines where (TextSimilarity.similarity(clicked.text, line.text) ?? 0) >= 0.75 {
                proposals.append((Self.pointInLine(line, recorded: clicked, click: t.click), .text))
            }
        }
        if let shift {
            proposals.append((CGPoint(x: t.click.x + shift.dx, y: t.click.y + shift.dy), .anchor))
        }
        if texture >= 6 {
            let inCrop = t.clickInCrop
            for peak in TemplateSearch.search(template: template, in: window) {
                let s = window.scale
                let p = CGPoint(x: Double(peak.x) / s + Double(inCrop.x) * peak.scale,
                                y: Double(peak.y) / s + Double(inCrop.y) * peak.scale)
                proposals.append((p, .image))
            }
        }

        var unique: [(CGPoint, VisualSignal)] = []
        for p in proposals where !unique.contains(where: { hypot($0.0.x - p.0.x, $0.0.y - p.0.y) < 8 }) {
            unique.append(p)
        }

        // 2. Score every spot on all the evidence.
        var scored: [VisualCandidate] = unique.map { point, source in
            var x: [VisualSignal: Double] = [:]
            if let clicked = t.clickedText {
                // Text read at this spot that matches counts for it, different text counts
                // against it, and no text read here at all (OCR often misses single
                // characters and symbols) says nothing either way.
                // But if the label was read somewhere else on screen, a spot without it is a wrong spot.
                let here = lines.filter { $0.frame.insetBy(dx: -6, dy: -6).contains(point) }
                if !here.isEmpty || strongLabelMatches > 0 {
                    x[.text] = here.compactMap { TextSimilarity.similarity(clicked.text, $0.text) }.max() ?? 0
                }
            }
            if !fits.isEmpty { x[.anchor] = Self.anchorSupport(point, fits) }
            if texture >= 6 {
                let coarse = imageScore(template, window, at: point, clickInCrop: t.clickInCrop)
                let fine = imageScore(fineTemplate, fineWindow, at: point, clickInCrop: t.clickInCrop)
                var signal = Self.imageSignal(coarse: coarse, fine: fine)
                if let core {
                    let c = imageScore(core.image, softWindow, at: point, clickInCrop: core.clickInCore)
                    signal = min(signal, min(1, max(0, (c - 0.6) / 0.32)))
                }
                x[.image] = signal
            }
            x[.spatial] = MatchEngine.spatialScore(recorded: t.click, candidate: point, shift: shift,
                                                   recordedWindow: t.windowSize, currentWindow: windowSize)
            var num = 0.0, den = 0.0
            for (signal, v) in x {
                // A flat crop says little; trust its pixel score less.
                var w = (weights[signal] ?? 1) * (signal == .image ? min(1, texture / 20) : 1)
                if signal == .text, strongLabelMatches == 1, v >= 0.9 { w *= 3 }
                num += w * v
                den += w
            }
            var s = den > 0 ? num / den : 0
            // A spot whose label is gone needs very convincing pixels.
            if let tx = x[.text], tx < 0.5, (x[.image] ?? 0) < 0.9 { s *= 0.75 }
            // Position alone is never enough.
            if x[.text] == nil && x[.anchor] == nil && (x[.image] ?? 0) < 0.5 { s *= 0.6 }
            return VisualCandidate(point: point, score: s, parts: x, source: source)
        }
        scored.sort { $0.score > $1.score }
        return VisualReport(decision: decide(scored), candidates: scored, shift: shift)
    }

    func decide(_ ranked: [VisualCandidate]) -> VisualDecision {
        guard let top = ranked.first else { return .notFound([]) }
        let rival = ranked.dropFirst().first {
            hypot($0.point.x - top.point.x, $0.point.y - top.point.y) >= distinctDistance
        }
        let margin = top.score - (rival?.score ?? 0)
        if top.score >= acceptScore && margin >= requiredMargin { return .confident(top) }
        if top.score >= plausibleScore { return .ambiguous(Array(ranked.prefix(6))) }
        return .notFound(Array(ranked.prefix(6)))
    }

    static let coreSide = 22.0

    /// The square of `coreSide` points centred on the click, when it has enough detail to compare.
    static func core(of template: GrayImage, clickInCrop: CGPoint, scale: Double) -> (image: GrayImage, clickInCore: CGPoint)? {
        let half = coreSide / 2
        let originX = max(0, Double(clickInCrop.x) - half), originY = max(0, Double(clickInCrop.y) - half)
        let side = Int((coreSide * scale).rounded())
        let image = template.cropped(x: Int((originX * scale).rounded()), y: Int((originY * scale).rounded()),
                                     width: side, height: side)
        guard image.width >= 6, image.height >= 6, image.contrast >= 6 else { return nil }
        return (image.blurred(radius: 1), CGPoint(x: Double(clickInCrop.x) - originX, y: Double(clickInCrop.y) - originY))
    }

    /// A band of detail: lightly softened first, so a rendering that is a
    /// little softer than the recording still lines up, then broad shapes removed.
    static func detail(_ img: GrayImage) -> GrayImage {
        img.blurred(radius: 1).highPassed(radius: 3)
    }

    /// Pixel evidence from 0 to 1. Icons of the same size on the same
    /// background correlate around 0.8 through their outline alone, so the
    /// raw score only counts above 0.7, and most of the weight goes to the
    /// detail score, where lookalikes land near 0.7 and the real icon,
    /// even rendered a little softer, above 0.9.
    static func imageSignal(coarse: Double, fine: Double) -> Double {
        let c = min(1, max(0, (coarse - 0.7) / 0.28))
        let f = min(1, max(0, (fine - 0.6) / 0.35))
        return 0.35 * c + 0.65 * f
    }

    /// How far things moved. Labels that agree win, as in the accessibility
    /// engine. When they don't agree, a label right next to the target (a
    /// message header above its Reply button) is trusted to have moved with it.
    static func estimateShift(_ fits: [MatchEngine.AnchorFit]) -> CGVector? {
        if let s = MatchEngine.consensusShift(fits) { return s }
        let nearest = fits.min { hypot($0.anchor.offset.x, $0.anchor.offset.y) < hypot($1.anchor.offset.x, $1.anchor.offset.y) }
        guard let n = nearest, hypot(n.anchor.offset.x, n.anchor.offset.y) <= 60 else { return nil }
        return n.displacement
    }

    /// How well a spot sits where the remembered labels say it should, with
    /// closer labels counting more than far ones.
    static func anchorSupport(_ p: CGPoint, _ fits: [MatchEngine.AnchorFit], sigma: CGFloat = 30) -> Double {
        var total = 0.0, weight = 0.0
        for f in fits {
            let w = 1 / (1 + Double(hypot(f.anchor.offset.x, f.anchor.offset.y)) / 60)
            let expected = CGPoint(x: f.now.x - f.anchor.offset.x, y: f.now.y - f.anchor.offset.y)
            let d = hypot(p.x - expected.x, p.y - expected.y)
            total += w * exp(-Double(d * d) / Double(2 * sigma * sigma))
            weight += w
        }
        return weight > 0 ? total / weight : 0
    }

    /// NCC with the recorded crop placed so its click point sits on `point`.
    func imageScore(_ template: GrayImage, _ window: GrayImage, at point: CGPoint, clickInCrop: CGPoint) -> Double {
        let s = window.scale
        let x = Int(((Double(point.x) - Double(clickInCrop.x)) * s).rounded())
        let y = Int(((Double(point.y) - Double(clickInCrop.y)) * s).rounded())
        // Allow a pixel or two of slop from rounding.
        var best = -1.0
        for dy in -1...1 {
            for dx in -1...1 {
                best = max(best, TemplateSearch.score(template: template, image: window, x: x + dx, y: y + dy))
            }
        }
        return best
    }

    /// Where to click inside a label found again. Labels are usually left
    /// aligned, so keep the distance from the left edge (clamped to the new
    /// width) rather than a fraction, which drifts when text gets longer.
    static func pointInLine(_ line: OCRLine, recorded: OCRLine, click: CGPoint) -> CGPoint {
        let dx = min(max(0, click.x - recorded.frame.minX), max(line.frame.width, 1))
        let fy = recorded.frame.height > 0 ? (click.y - recorded.frame.minY) / recorded.frame.height : 0.5
        return CGPoint(x: line.frame.minX + dx, y: line.frame.minY + min(max(fy, 0), 1) * line.frame.height)
    }

    /// Each remembered nearby label, found again: the copy closest to where it used to be.
    static func locateAnchors(_ t: VisualTarget, lines: [OCRLine]) -> [MatchEngine.AnchorFit] {
        var fits: [MatchEngine.AnchorFit] = []
        for a in t.nearby {
            let was = CGPoint(x: t.click.x + a.offset.x, y: t.click.y + a.offset.y)
            var best: (CGPoint, CGFloat)?
            for line in lines where (TextSimilarity.similarity(a.label, line.text) ?? 0) >= 0.85 {
                let d = hypot(line.center.x - was.x, line.center.y - was.y)
                if d < (best?.1 ?? .infinity) { best = (line.center, d) }
            }
            if let now = best?.0 {
                fits.append(MatchEngine.AnchorFit(anchor: a, now: now,
                                                  displacement: CGVector(dx: now.x - was.x, dy: now.y - was.y)))
            }
        }
        return fits
    }
}
