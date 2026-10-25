import Foundation

/// Decides when a window has stopped changing, so the next step runs as soon
/// as the screen is ready instead of after a fixed guess.
///
/// Feed it a fingerprint of the window's accessibility tree on every poll.
/// The window counts as settled once the fingerprint has held still for
/// `quietPeriod` and no busy indicator is showing. A spinner that never stops
/// is handled by the caller's overall timeout.
public struct SettleDetector {
    public let quietPeriod: TimeInterval
    private(set) var lastFingerprint: Int?
    private(set) var stableSince: TimeInterval?

    public init(quietPeriod: TimeInterval = 0.25) {
        self.quietPeriod = quietPeriod
    }

    /// Returns true when the window is settled as of `time`.
    public mutating func observe(fingerprint: Int, busy: Bool, at time: TimeInterval) -> Bool {
        if fingerprint != lastFingerprint {
            lastFingerprint = fingerprint
            stableSince = time
            return false
        }
        guard !busy, let since = stableSince else { return false }
        return time - since >= quietPeriod
    }

    public mutating func reset() {
        lastFingerprint = nil
        stableSince = nil
    }
}

/// Order sensitive hash of the bits of each element that change when a
/// screen loads or reflows: role, child count and frame, rounded so that
/// sub point jitter from animations doesn't look like change.
public struct TreeFingerprint {
    private var hasher = Hasher()
    public private(set) var count = 0

    public init() {}

    public mutating func add(role: String, childCount: Int, x: Double?, y: Double?, w: Double?, h: Double?) {
        hasher.combine(role)
        hasher.combine(childCount)
        for v in [x, y, w, h] { hasher.combine(v.map { Int(($0 / 4).rounded()) }) }
        count += 1
    }

    public func finalize() -> Int {
        var h = hasher
        h.combine(count)
        return h.finalize()
    }
}
