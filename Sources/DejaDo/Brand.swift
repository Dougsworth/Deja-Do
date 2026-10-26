import SwiftUI
import AppKit

/// Deja Do's brand: Quiet Confidence. Mostly neutrals, one cobalt accent for
/// what's active or primary, and a separate set of colours that only ever
/// mean a state. A state is always named in words too, never shown by colour alone.
enum Brand {
    private static func dynamic(_ light: UInt32, _ dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .vibrantDark, .accessibilityHighContrastDarkAqua]) != nil
            return NSColor(hex: isDark ? dark : light)
        })
    }

    // Foundations
    /// Logo, headings, primary text.
    static let ink = dynamic(0x17191C, 0xECEDEE)
    /// The main background.
    static let canvas = dynamic(0xF7F7F4, 0x141618)
    /// Raised surfaces: sheets, fields.
    static let surface = dynamic(0xFFFFFF, 0x1C1F23)
    /// Hairlines, selected rows, secondary surfaces.
    static let mist = dynamic(0xE9EDF3, 0x2A2F36)
    /// Secondary text.
    static let slate = dynamic(0x6B717A, 0x9AA1AA)
    /// Brand and primary actions. Lighter on dark so it keeps its contrast.
    static let cobalt = dynamic(0x3459C8, 0x7B97F2)
    /// Text on a cobalt button: white on light, deep navy on dark, for 4.5:1 either way.
    static let onCobalt = dynamic(0xFFFFFF, 0x0D1530)

    // States, separate from the brand colour
    static let forest = dynamic(0x237A57, 0x4FB487)
    static let amber = dynamic(0x965C0C, 0xE3A84A)
    static let red = dynamic(0xC2362C, 0xF0695E)
}

extension NSColor {
    convenience init(hex: UInt32) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}

/// What Deja Do is doing, as the status line and menu bar say it.
enum RunState: Equatable {
    case ready, recording, running, completed, needsAttention, failed

    var word: String {
        switch self {
        case .ready: return "Ready"
        case .recording: return "Recording"
        case .running: return "Running"
        case .completed: return "Completed"
        case .needsAttention: return "Needs attention"
        case .failed: return "Failed"
        }
    }

    var color: Color {
        switch self {
        case .ready: return Brand.slate
        case .recording, .failed: return Brand.red
        case .running: return Brand.cobalt
        case .completed: return Brand.forest
        case .needsAttention: return Brand.amber
        }
    }

    /// A flat single-colour symbol to go with the word.
    var symbol: String {
        switch self {
        case .ready: return "circle"
        case .recording: return "record.circle"
        case .running: return "play.circle"
        case .completed: return "checkmark.circle"
        case .needsAttention: return "exclamationmark.circle"
        case .failed: return "xmark.circle"
        }
    }
}

/// The mark: an outline D running into a solid D. What you show it, then
/// what it repeats. Drawn here so it stays sharp at any size.
struct BrandMark: View {
    var ink: Color = Brand.ink
    var accent: Color = Brand.cobalt

    var body: some View {
        Canvas { ctx, size in
            // Drawn on a 110 × 80 grid.
            let s = min(size.width / 110, size.height / 80)
            let ox = (size.width - 110 * s) / 2, oy = (size.height - 80 * s) / 2
            func d(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> Path {
                let r = h / 2
                var p = Path()
                p.move(to: CGPoint(x: ox + x * s, y: oy + y * s))
                p.addLine(to: CGPoint(x: ox + (x + w - r) * s, y: oy + y * s))
                p.addArc(center: CGPoint(x: ox + (x + w - r) * s, y: oy + (y + r) * s), radius: r * s,
                         startAngle: .degrees(-90), endAngle: .degrees(90), clockwise: false)
                p.addLine(to: CGPoint(x: ox + x * s, y: oy + (y + h) * s))
                p.closeSubpath()
                return p
            }
            ctx.stroke(d(5, 5, 50, 70), with: .color(ink), lineWidth: 10 * s)
            ctx.fill(d(50, 0, 60, 80), with: .color(accent))
        }
        .aspectRatio(110 / 80, contentMode: .fit)
        .accessibilityLabel("Deja Do")
    }
}
