import Foundation

#if !canImport(CoreGraphics)
/// Foundation on Linux has CGPoint, CGSize and CGRect but no CGVector.
/// This stand in lets the engine and its tests build there too, so the
/// core logic can be checked without a Mac. On macOS the real type is used.
public struct CGVector: Equatable, Hashable, Codable {
    public var dx: CGFloat
    public var dy: CGFloat
    public init(dx: CGFloat, dy: CGFloat) { self.dx = dx; self.dy = dy }
    public static let zero = CGVector(dx: 0, dy: 0)
}
#endif
