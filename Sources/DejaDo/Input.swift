import AppKit
import CoreGraphics
import DejaDoCore

/// Posts synthetic mouse and keyboard events.
enum Input {
    static let source = CGEventSource(stateID: .hidSystemState)
    static let modifierMask: UInt64 = CGEventFlags.maskCommand.rawValue | CGEventFlags.maskControl.rawValue
        | CGEventFlags.maskAlternate.rawValue | CGEventFlags.maskShift.rawValue

    static func click(at point: CGPoint, button: MouseButtonKind, count: Int, modifiers: UInt64) {
        let flags = CGEventFlags(rawValue: modifiers & modifierMask)
        let (downType, upType, mouseButton): (CGEventType, CGEventType, CGMouseButton) =
            button == .left ? (.leftMouseDown, .leftMouseUp, .left) : (.rightMouseDown, .rightMouseUp, .right)

        CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left)?
            .post(tap: .cghidEventTap)
        usleep(80_000)

        for i in 1...max(1, count) {
            guard let down = CGEvent(mouseEventSource: source, mouseType: downType, mouseCursorPosition: point, mouseButton: mouseButton),
                  let up = CGEvent(mouseEventSource: source, mouseType: upType, mouseCursorPosition: point, mouseButton: mouseButton) else { return }
            down.setIntegerValueField(.mouseEventClickState, value: Int64(i))
            up.setIntegerValueField(.mouseEventClickState, value: Int64(i))
            down.flags = flags
            up.flags = flags
            down.post(tap: .cghidEventTap)
            usleep(40_000)
            up.post(tap: .cghidEventTap)
            usleep(70_000)
        }
    }

    static func type(_ text: String) {
        for ch in text {
            if ch == "\n" || ch == "\r" { key(36, modifiers: 0); continue }
            if ch == "\t" { key(48, modifiers: 0); continue }
            var units = Array(String(ch).utf16)
            guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
                  let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else { continue }
            down.flags = []
            up.flags = []
            down.keyboardSetUnicodeString(stringLength: units.count, unicodeString: &units)
            up.keyboardSetUnicodeString(stringLength: units.count, unicodeString: &units)
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
            usleep(12_000)
        }
    }

    static func key(_ code: UInt16, modifiers: UInt64) {
        let flags = CGEventFlags(rawValue: modifiers & modifierMask)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(code), keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(code), keyDown: false) else { return }
        down.flags = flags
        up.flags = flags
        down.post(tap: .cghidEventTap)
        usleep(30_000)
        up.post(tap: .cghidEventTap)
        usleep(30_000)
    }
}

/// Names for keys that don't print a character.
enum KeyNames {
    static let names: [UInt16: String] = [
        36: "Return", 76: "Enter", 48: "Tab", 49: "Space", 51: "Delete", 117: "Forward Delete", 53: "Esc",
        123: "←", 124: "→", 125: "↓", 126: "↑", 115: "Home", 119: "End", 116: "Page Up", 121: "Page Down",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8",
        101: "F9", 109: "F10", 103: "F11", 111: "F12"
    ]

    /// Keys that always become their own step instead of joining typed text.
    static let special: Set<UInt16> = Set(names.keys).subtracting([49])

    static func label(code: UInt16, flags: CGEventFlags, chars: String?) -> String {
        var s = ""
        if flags.contains(.maskControl) { s += "⌃" }
        if flags.contains(.maskAlternate) { s += "⌥" }
        if flags.contains(.maskShift) { s += "⇧" }
        if flags.contains(.maskCommand) { s += "⌘" }
        if let name = names[code] {
            s += s.isEmpty ? name : " \(name)"
        } else if let c = chars, !c.isEmpty {
            s += c.uppercased()
        } else {
            s += "key \(code)"
        }
        return s
    }
}
