import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// Working out which displays a window is on, in the global space
/// Accessibility uses: points, origin at the top left of the main display,
/// y growing downwards. Displays to the left of or above the main one have
/// negative coordinates.
public enum ScreenGeometry {
    public struct Piece: Equatable {
        /// Index into the displays given.
        public let display: Int
        /// The part of the window on that display, in global points.
        public let rect: CGRect
    }

    /// Every display the rectangle overlaps, biggest overlap first. A window
    /// whose centre falls in the gap between two differently sized displays
    /// still finds both; one sitting across two displays gets both halves.
    public static func pieces(of rect: CGRect, on displays: [CGRect]) -> [Piece] {
        displays.enumerated().compactMap { i, d -> Piece? in
            let r = rect.intersection(d)
            guard !r.isNull, r.width >= 1, r.height >= 1 else { return nil }
            return Piece(display: i, rect: r)
        }
        .sorted { $0.rect.width * $0.rect.height > $1.rect.width * $1.rect.height }
    }

    /// The display a rectangle is mostly on, or nil when it's on none.
    public static func mainDisplay(for rect: CGRect, on displays: [CGRect]) -> Int? {
        pieces(of: rect, on: displays).first?.display
    }

    /// The bounding box of what can be seen of the rectangle.
    public static func visible(_ rect: CGRect, on displays: [CGRect]) -> CGRect? {
        let parts = pieces(of: rect, on: displays)
        guard let first = parts.first else { return nil }
        return parts.dropFirst().reduce(first.rect) { $0.union($1.rect) }
    }

    /// Converts a point from AppKit's space (origin bottom left of the main
    /// display, y up) to the Accessibility space, or back: the same flip both ways.
    public static func flip(_ p: CGPoint, mainDisplayHeight h: CGFloat) -> CGPoint {
        CGPoint(x: p.x, y: h - p.y)
    }
}
