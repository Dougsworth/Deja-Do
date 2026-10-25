import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// What we can read about one on-screen element, with no live handle attached.
/// Frames are relative to the window's top left corner.
public struct ElementSnapshot: Equatable {
    public var role: String
    public var subrole: String?
    public var title: String?
    public var desc: String?
    public var identifier: String?
    public var help: String?
    public var value: String?
    public var label: String?
    public var frame: CGRect?
    public var path: [PathStep]
    public var context: [String]

    public init(role: String, subrole: String? = nil, title: String? = nil, desc: String? = nil,
                identifier: String? = nil, help: String? = nil, value: String? = nil, label: String? = nil,
                frame: CGRect? = nil, path: [PathStep] = [], context: [String] = []) {
        self.role = role
        self.subrole = subrole
        self.title = title
        self.desc = desc
        self.identifier = identifier
        self.help = help
        self.value = value
        self.label = label
        self.frame = frame
        self.path = path
        self.context = context
    }

    var center: CGPoint? { frame.map { CGPoint(x: $0.midX, y: $0.midY) } }
    var texts: [String?] { [label, title, desc] }
}

/// The signals we compare a candidate on. Each one scores 0...1.
public enum Feature: String, Codable, CaseIterable {
    case role, identifier, text, help, value, path, context, spatial, anchor
}

public typealias FeatureVector = [Feature: Double]

/// How much each signal counts. Starts from sensible defaults and is nudged,
/// per app, every time the AI has to step in.
public struct MatchWeights: Codable, Equatable {
    public var values: [String: Double]

    public static let defaults: [Feature: Double] = [
        .role: 2.0, .identifier: 4.0, .text: 4.0, .help: 0.8, .value: 0.5,
        .path: 1.5, .context: 1.0, .spatial: 1.5, .anchor: 2.5
    ]
    public static let floor = 0.2
    public static let ceiling = 8.0

    public init(_ weights: [Feature: Double] = MatchWeights.defaults) {
        values = Dictionary(uniqueKeysWithValues: weights.map { ($0.key.rawValue, $0.value) })
    }

    public subscript(_ f: Feature) -> Double {
        get { values[f.rawValue] ?? Self.defaults[f] ?? 1 }
        set { values[f.rawValue] = min(Self.ceiling, max(Self.floor, newValue)) }
    }

    /// Weighted average over the signals that apply, so a target with no
    /// identifier isn't punished for lacking one.
    public func score(_ x: FeatureVector) -> Double {
        var num = 0.0, den = 0.0
        for (f, v) in x {
            num += self[f] * v
            den += self[f]
        }
        return den > 0 ? num / den : 0
    }

    /// Pairwise ranking update (a perceptron on score differences). When the
    /// AI says `chosen` was right and the engine ranked `others` at least as
    /// high, shift weight toward the signals where `chosen` beat them.
    public mutating func learn(chosen: FeatureVector, others: [FeatureVector], rate: Double = 0.6) {
        let target = score(chosen)
        let violators = others.filter { score($0) >= target - 0.05 }
        guard !violators.isEmpty else { return }
        for other in violators {
            for f in Feature.allCases {
                guard let a = chosen[f], let b = other[f] else { continue }
                self[f] += rate * (a - b) / Double(violators.count)
            }
        }
    }
}

public struct RankedCandidate: Equatable {
    public let index: Int
    public let score: Double
    public let features: FeatureVector
}

public enum MatchDecision: Equatable {
    /// Safe to act on without asking anyone.
    case confident(RankedCandidate)
    /// A few plausible elements and no clear winner. Worth asking the AI, top few only.
    case ambiguous([RankedCandidate])
    /// Nothing looks right.
    case notFound([RankedCandidate])
}

public struct MatchReport {
    public let decision: MatchDecision
    public let ranked: [RankedCandidate]
    /// How far the neighbourhood around the target moved, if anchors could tell.
    public let shift: CGVector?
    public let anchorsMatched: Int

    public var best: RankedCandidate? { ranked.first }

    public init(decision: MatchDecision, ranked: [RankedCandidate], shift: CGVector?, anchorsMatched: Int) {
        self.decision = decision
        self.ranked = ranked
        self.shift = shift
        self.anchorsMatched = anchorsMatched
    }

    /// The same report when the window couldn't be scanned completely: the real
    /// target may not have been looked at, so only a near perfect match stays confident.
    public func incomplete() -> MatchReport {
        guard case .confident(let top) = decision, top.score < 0.95 else { return self }
        return MatchReport(decision: .ambiguous(Array(ranked.prefix(12))), ranked: ranked, shift: shift,
                           anchorsMatched: anchorsMatched)
    }
}

/// Finds a recorded element among the elements on screen now.
///
/// Every candidate is scored on nine signals (role, identifier, text, help,
/// value, tree path, surrounding groups, position and nearby labels), combined
/// with per app learned weights. Position is predicted rather than taken
/// literally: anchors estimate how the neighbourhood moved, and when there are
/// no anchors several resize hypotheses are tried (left, right, bottom aligned
/// and proportional). The decision then looks at the margin over the runner up,
/// not just the top score, so two similar buttons are never guessed between.
public struct MatchEngine {
    public var weights: MatchWeights
    public var acceptScore = 0.80
    public var acceptWithMargin = 0.66
    public var requiredMargin = 0.10
    public var plausibleScore = 0.40
    public var ambiguousTopK = 12

    public init(weights: MatchWeights = MatchWeights()) {
        self.weights = weights
    }

    public func match(_ target: ElementLocator, among candidates: [ElementSnapshot],
                      windowSize: CGSize? = nil) -> MatchReport {
        let recorded = target.snapshot
        let anchorFit = Self.locateAnchors(target, candidates: candidates)
        let shift = Self.consensusShift(anchorFit)

        var ranked: [RankedCandidate] = []
        ranked.reserveCapacity(candidates.count)
        for (i, c) in candidates.enumerated() {
            let x = features(recorded, target, c, anchorFit: anchorFit, shift: shift, windowSize: windowSize)
            var s = weights.score(x)
            // A labelled target must not be matched on position alone.
            if let t = x[.text], t < 0.4, (x[.identifier] ?? 0) < 0.9 { s *= 0.7 }
            ranked.append(RankedCandidate(index: i, score: s, features: x))
        }
        ranked.sort { $0.score > $1.score }
        let decision = decide(ranked, candidates: candidates)
        return MatchReport(decision: decision, ranked: ranked, shift: shift, anchorsMatched: anchorFit.count)
    }

    func decide(_ ranked: [RankedCandidate], candidates: [ElementSnapshot]) -> MatchDecision {
        guard let top = ranked.first else { return .notFound([]) }
        // The runner up must be a genuinely different element, not the label
        // inside the same button or the cell wrapping the same text.
        let runnerUp = ranked.dropFirst().first {
            !Self.sameTarget(candidates[top.index], candidates[$0.index])
        }
        let margin = top.score - (runnerUp?.score ?? 0)
        if top.score >= acceptScore && margin >= requiredMargin / 2 { return .confident(top) }
        if top.score >= acceptWithMargin && margin >= requiredMargin { return .confident(top) }
        // The only control with exactly this label and this kind of role is it,
        // however far the layout moved it. A reflowed page or a resized window
        // changes position, path and neighbours all at once, but not the label.
        if (top.features[.text] ?? 0) >= 0.97, (top.features[.role] ?? 0) >= 0.85, top.score >= plausibleScore,
           !ranked.dropFirst().contains(where: {
               (($0.features[.text] ?? 0) >= 0.9) && (($0.features[.role] ?? 0) > 0)
                   && !Self.sameTarget(candidates[top.index], candidates[$0.index])
           }) {
            return .confident(top)
        }
        if top.score >= plausibleScore { return .ambiguous(Array(ranked.prefix(ambiguousTopK))) }
        return .notFound(Array(ranked.prefix(150)))
    }

    /// One element nested inside the other with near identical text.
    static func sameTarget(_ a: ElementSnapshot, _ b: ElementSnapshot) -> Bool {
        guard let fa = a.frame, let fb = b.frame else { return false }
        let nested = (fa.contains(CGPoint(x: fb.midX, y: fb.midY)) && fa.width * fa.height >= fb.width * fb.height)
            || (fb.contains(CGPoint(x: fa.midX, y: fa.midY)) && fb.width * fb.height >= fa.width * fa.height)
        guard nested else { return false }
        return (TextSimilarity.best(a.texts, b.texts) ?? 0) >= 0.9
    }

    // MARK: Features

    func features(_ t: ElementSnapshot, _ locator: ElementLocator, _ c: ElementSnapshot,
                  anchorFit: [AnchorFit], shift: CGVector?, windowSize: CGSize?) -> FeatureVector {
        var x: FeatureVector = [:]
        x[.role] = Self.roleCompatibility(t.role, c.role, t.subrole, c.subrole)

        if TextSimilarity.isStableIdentifier(t.identifier) {
            if let ci = c.identifier { x[.identifier] = ci == t.identifier ? 1 : 0.7 * (TextSimilarity.similarity(t.identifier, ci) ?? 0) }
            else { x[.identifier] = 0 }
        }
        if t.texts.contains(where: { !($0 ?? "").isEmpty }) {
            x[.text] = TextSimilarity.best(t.texts, c.texts) ?? 0
        }
        if t.help != nil { x[.help] = TextSimilarity.similarity(t.help, c.help) ?? 0 }
        if t.value != nil { x[.value] = TextSimilarity.similarity(t.value, c.value) ?? 0 }
        if !t.path.isEmpty, !c.path.isEmpty { x[.path] = Self.pathSimilarity(t.path, c.path) }
        if !t.context.isEmpty {
            x[.context] = TextSimilarity.jaccard(
                t.context.flatMap { TextSimilarity.tokens(TextSimilarity.normalize($0)) },
                c.context.flatMap { TextSimilarity.tokens(TextSimilarity.normalize($0)) })
        }
        if let tc = t.center {
            if let cc = c.center {
                x[.spatial] = Self.spatialScore(recorded: tc, candidate: cc, shift: shift,
                                                recordedWindow: locator.windowSize, currentWindow: windowSize)
            } else {
                x[.spatial] = 0
            }
        }
        if !anchorFit.isEmpty {
            x[.anchor] = c.center.map { Self.anchorSupport($0, anchorFit) } ?? 0
        }
        return x
    }

    static let roleGroups: [Set<String>] = [
        ["AXButton", "AXMenuButton", "AXPopUpButton", "AXLink", "AXDisclosureTriangle", "AXImage"],
        ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"],
        ["AXCell", "AXRow", "AXStaticText", "AXOutlineRow"],
        ["AXCheckBox", "AXRadioButton", "AXSwitch", "AXToggle"],
        ["AXMenuItem", "AXMenuBarItem"],
        ["AXTab", "AXRadioButton", "AXButton"]
    ]

    public static func roleCompatibility(_ a: String, _ b: String, _ sa: String? = nil, _ sb: String? = nil) -> Double {
        if a == b { return (sa == sb || sa == nil || sb == nil) ? 1 : 0.85 }
        return roleGroups.contains { $0.contains(a) && $0.contains(b) } ? 0.6 : 0
    }

    /// Edit distance on tree paths. Same role at a different index costs less
    /// than a different role, because a new sibling shifts every index after it.
    public static func pathSimilarity(_ a: [PathStep], _ b: [PathStep]) -> Double {
        let x = Array(a.suffix(40)), y = Array(b.suffix(40))
        if x.isEmpty || y.isEmpty { return x.isEmpty && y.isEmpty ? 1 : 0 }
        var prev = (0...y.count).map(Double.init)
        var cur = [Double](repeating: 0, count: y.count + 1)
        for i in 1...x.count {
            cur[0] = Double(i)
            for j in 1...y.count {
                let sub: Double = x[i - 1] == y[j - 1] ? 0 : (x[i - 1].role == y[j - 1].role ? 0.35 : 1)
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + sub)
            }
            swap(&prev, &cur)
        }
        return max(0, 1 - prev[y.count] / Double(max(x.count, y.count)))
    }

    /// Gaussian kernel on distance from where we expect the element to be.
    /// Without an anchor based shift, try the ways windows usually reflow on
    /// resize and keep the best: pinned left, pinned right, pinned bottom,
    /// pinned bottom right, or scaled proportionally.
    public static func spatialScore(recorded: CGPoint, candidate: CGPoint, shift: CGVector?,
                                    recordedWindow: CGSize?, currentWindow: CGSize?) -> Double {
        let size = currentWindow ?? recordedWindow ?? CGSize(width: 1000, height: 700)
        let sigma = max(40, 0.06 * hypot(size.width, size.height))
        var guesses: [CGPoint] = []
        if let shift {
            guesses.append(CGPoint(x: recorded.x + shift.dx, y: recorded.y + shift.dy))
        } else {
            guesses.append(recorded)
            if let old = recordedWindow, let new = currentWindow, old != new, old.width > 0, old.height > 0 {
                let dw = new.width - old.width, dh = new.height - old.height
                guesses.append(CGPoint(x: recorded.x + dw, y: recorded.y))
                guesses.append(CGPoint(x: recorded.x, y: recorded.y + dh))
                guesses.append(CGPoint(x: recorded.x + dw, y: recorded.y + dh))
                guesses.append(CGPoint(x: recorded.x * new.width / old.width, y: recorded.y * new.height / old.height))
            }
        }
        let best = guesses.map { hypot($0.x - candidate.x, $0.y - candidate.y) }.min() ?? .infinity
        return Double(exp(-(best * best) / (2 * sigma * sigma)))
    }

    // MARK: Anchors

    /// A recorded anchor and where it is now.
    public struct AnchorFit: Equatable {
        public let anchor: Anchor
        public let now: CGPoint
        /// Movement of this anchor since recording.
        public let displacement: CGVector
    }

    /// Find each anchor's label on screen now. When a label appears more than
    /// once, take the copy closest to where the anchor used to be.
    static func locateAnchors(_ target: ElementLocator, candidates: [ElementSnapshot]) -> [AnchorFit] {
        guard let anchors = target.anchors, !anchors.isEmpty,
              let frame = target.frameInWindow else { return [] }
        let tc = CGPoint(x: frame.midX, y: frame.midY)
        var fits: [AnchorFit] = []
        for a in anchors {
            let was = CGPoint(x: tc.x + a.offset.x, y: tc.y + a.offset.y)
            var best: (CGPoint, CGFloat)?
            for c in candidates {
                guard let cc = c.center,
                      roleCompatibility(a.role, c.role) > 0,
                      (TextSimilarity.best([a.label], c.texts) ?? 0) >= 0.85 else { continue }
                let d = hypot(cc.x - was.x, cc.y - was.y)
                if d < (best?.1 ?? .infinity) { best = (cc, d) }
            }
            if let now = best?.0 {
                fits.append(AnchorFit(anchor: a, now: now, displacement: CGVector(dx: now.x - was.x, dy: now.y - was.y)))
            }
        }
        return fits
    }

    /// Robust estimate of how the neighbourhood moved: every anchor proposes
    /// its own displacement, the one most other anchors agree with (within
    /// 25 points) wins, and its supporters are averaged. One anchor whose
    /// label moved elsewhere can't drag the estimate off.
    public static func consensusShift(_ fits: [AnchorFit], tolerance: CGFloat = 25) -> CGVector? {
        guard !fits.isEmpty else { return nil }
        var bestInliers: [AnchorFit] = []
        for proposal in fits {
            let inliers = fits.filter {
                hypot($0.displacement.dx - proposal.displacement.dx, $0.displacement.dy - proposal.displacement.dy) <= tolerance
            }
            if inliers.count > bestInliers.count { bestInliers = inliers }
        }
        // A lone anchor is trusted only when it is the only one we have.
        if bestInliers.count < 2 && fits.count > 1 { return nil }
        let n = CGFloat(bestInliers.count)
        return CGVector(dx: bestInliers.map(\.displacement.dx).reduce(0, +) / n,
                        dy: bestInliers.map(\.displacement.dy).reduce(0, +) / n)
    }

    /// How well a candidate sits where each anchor says the target should be.
    static func anchorSupport(_ c: CGPoint, _ fits: [AnchorFit], sigma: CGFloat = 30) -> Double {
        guard !fits.isEmpty else { return 0 }
        var total = 0.0
        for f in fits {
            let expected = CGPoint(x: f.now.x - f.anchor.offset.x, y: f.now.y - f.anchor.offset.y)
            let d = hypot(c.x - expected.x, c.y - expected.y)
            total += exp(-Double(d * d) / Double(2 * sigma * sigma))
        }
        return total / Double(fits.count)
    }
}
