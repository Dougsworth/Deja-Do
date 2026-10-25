import AppKit
import ApplicationServices
import DejaDoCore

/// Finds a recorded element again in the live accessibility tree.
enum ElementFinder {
    struct Root {
        let element: AXUIElement
        let windowFrame: CGRect?
    }

    struct Match {
        let element: AXUIElement
        let windowFrame: CGRect?
    }

    /// Everything matchable in the window, plus the engine's verdict.
    struct Outcome {
        let root: Root
        let elements: [AXUIElement]
        let snapshots: [ElementSnapshot]
        let report: MatchReport

        func element(for c: RankedCandidate) -> AXUIElement { elements[c.index] }
        func snapshot(for c: RankedCandidate) -> ElementSnapshot { snapshots[c.index] }
    }

    static func runningApp(_ bundleID: String) -> NSRunningApplication? {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first
    }

    /// The window to search in, or the whole app for menus.
    static func root(for l: ElementLocator) -> Root? {
        guard let app = runningApp(l.bundleID) else { return nil }
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(appElement, 2.0)
        AX.wake(app: appElement, bundleID: l.bundleID)
        if l.inMenu { return Root(element: appElement, windowFrame: nil) }

        let windows = AX.elements(AX.raw(appElement, kAXWindowsAttribute))
        let focused = AX.element(appElement, kAXFocusedWindowAttribute)
        var chosen: AXUIElement?
        if let title = l.windowTitle {
            chosen = windows.first { AX.string($0, kAXTitleAttribute) == title }
        }
        chosen = chosen ?? focused ?? windows.first
        guard let window = chosen else { return nil }
        return Root(element: window, windowFrame: AX.frame(window))
    }

    /// Tries the exact recorded route first. If the element there still
    /// looks right, skip the full window scan.
    static func find(_ l: ElementLocator, engine: MatchEngine) -> Outcome? {
        guard let root = root(for: l) else { return nil }
        let origin = root.windowFrame?.origin

        if let el = AX.resolve(l.path, from: root.element) {
            let snap = AX.snapshot(AX.node(el), origin: origin, path: l.path, context: l.context ?? [])
            let solo = engine.match(l, among: [snap], windowSize: root.windowFrame?.size)
            if let best = solo.best, best.score >= 0.9 {
                return Outcome(root: root, elements: [el], snapshots: [snap], report: solo)
            }
        }

        let wanted = l.role
        let found = AX.collect(from: root.element, origin: origin) { role in
            role == wanted || AX.matchRoles.contains(role) || MatchEngine.roleCompatibility(wanted, role) > 0
        }
        let snapshots = found.map(\.snapshot)
        let report = engine.match(l, among: snapshots, windowSize: root.windowFrame?.size)
        return Outcome(root: root, elements: found.map(\.element), snapshots: snapshots, report: report)
    }
}
