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

    // The three signature colours are Deja Blue, Obsidian and Cloud White.
    // Everything else supports them. Light value first, dark second.

    /// Text: Obsidian on light, Cloud White on dark.
    static let ink = dynamic(0x17191C, 0xF8F9FA)
    /// The main background: Cloud White.
    static let canvas = dynamic(0xF8F9FA, 0x121417)
    /// The sidebar.
    static let sidebar = dynamic(0xF1F3F6, 0x1A1D22)
    /// Cards, panels and sheets: Pure White.
    static let surface = dynamic(0xFFFFFF, 0x22262C)
    /// Borders and dividers: Mist.
    static let mist = dynamic(0xE9EDF3, 0x343A43)
    /// Selected navigation and subtle highlights: Soft Blue.
    static let selected = dynamic(0xEEF2FF, 0x28365B)
    /// Secondary text and the Idle state: Slate.
    static let slate = dynamic(0x667085, 0xA4ACB9)
    /// Deja Blue: the logo, primary buttons, active states, the Running state.
    static let cobalt = dynamic(0x3659C9, 0x6D8CF0)
    /// Deep Blue: a pressed or hovered primary button.
    static let deepBlue = dynamic(0x2846A5, 0x7895F2)
    /// Text on Deja Blue: white on light (6.1:1); Obsidian on dark, where white would only reach 3.2:1.
    static let onCobalt = dynamic(0xFFFFFF, 0x17191C)

    // Functional colours: they mean a state, never the brand. In light mode
    // they pass 3:1 for symbols but not 4.5:1 for small text, so a state's
    // word is set in ink and its symbol carries the colour.
    /// Signal Red: Recording, and Failed.
    static let red = dynamic(0xD64545, 0xEF6B63)
    /// Success Green: Completed.
    static let forest = dynamic(0x23845B, 0x4FB487)
    /// Amber: Needs attention.
    static let amber = dynamic(0xC47B22, 0xE3A84A)
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
