import AppKit
import ApplicationServices
@preconcurrency import DejaDoCore

/// The self test's own clicks and key presses. Every one first makes sure the
/// app it's meant for is in front and, for a click, is what's actually under
/// the pointer. If anything else is there (a chat window, a dialog, the
/// person's own work) nothing is sent and the check that needed it fails.
enum TestInput {
    /// Brings the app forward and waits up to a second for it to be in front.
    @discardableResult
    static func front(_ bundleID: String) -> Bool {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else { return false }
        for _ in 0..<10 {
            if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == bundleID { return true }
            app.activate(options: [.activateIgnoringOtherApps])
            usleep(100_000)
        }
        return NSWorkspace.shared.frontmostApplication?.bundleIdentifier == bundleID
    }

    static func pid(_ bundleID: String) -> pid_t? {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first?.processIdentifier
    }

    /// Clicks only when the point belongs to that app.
    @discardableResult
    static func click(_ point: CGPoint, in bundleID: String, count: Int = 1) -> Bool {
        guard front(bundleID), let want = pid(bundleID) else { return false }
        guard let hit = AX.element(at: point), AX.pid(hit) == want else {
            SelfTest.Guard.shared.blocked("a click at \(Int(point.x)),\(Int(point.y)) for \(bundleID), something else was there")
            return false
        }
        Input.click(at: point, button: .left, count: count, modifiers: 0)
        return true
    }

    @discardableResult
    static func key(_ code: UInt16, modifiers: UInt64 = 0, in bundleID: String) -> Bool {
        guard front(bundleID) else {
            SelfTest.Guard.shared.blocked("a key press for \(bundleID), it wasn't in front")
            return false
        }
        Input.key(code, modifiers: modifiers)
        return true
    }

    @discardableResult
    static func type(_ text: String, in bundleID: String) -> Bool {
        guard front(bundleID) else {
            SelfTest.Guard.shared.blocked("typing for \(bundleID), it wasn't in front")
            return false
        }
        return Input.type(text) { NSWorkspace.shared.frontmostApplication?.bundleIdentifier == bundleID }
    }
}

extension SelfTest {
    /// Collects what the test held back from doing, so the log says why a check failed.
    final class Guard: @unchecked Sendable {
        static let shared = Guard()
        private let lock = NSLock()
        private var _notes: [String] = []
        func blocked(_ what: String) { lock.lock(); _notes.append(what); lock.unlock() }
        func take() -> [String] { lock.lock(); defer { _notes = []; lock.unlock() }; return _notes }
    }

    /// Seconds since the person last touched the mouse or keyboard.
    static var idleSeconds: Double {
        min(CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .mouseMoved),
            CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .keyDown),
            CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .leftMouseDown))
    }
}
