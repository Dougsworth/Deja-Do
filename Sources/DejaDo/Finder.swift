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
        /// The window was too big or slow to scan completely.
        var truncated = false
        /// The browser is showing a different site from the one recorded.
        var wrongSite: String?

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
        chosen = pick(recorded: l.windowTitle, focused: focused, windows: windows)
        guard let window = chosen else { return nil }
        return Root(element: window, windowFrame: AX.frame(window))
    }

    /// The window a step means. The front window wins when its title is the
    /// recorded one give or take a number ("Untitled 2" for "Untitled",
    /// "Invoice 1043" for "Invoice 1042"): that's the same kind of window, and
    /// the one the person is looking at. Otherwise a window with exactly the
    /// recorded title, else the front one.
    static func pick(recorded: String?, focused: AXUIElement?, windows: [AXUIElement]) -> AXUIElement? {
        guard let recorded else { return focused ?? windows.first }
        if let f = focused, let t = AX.string(f, kAXTitleAttribute), WindowTitles.sameKind(t, recorded) { return f }
        return windows.first { AX.string($0, kAXTitleAttribute) == recorded } ?? focused ?? windows.first
    }

    /// Tries the exact recorded route first. If the element there still
    /// looks right, skip the full window scan.
    static func find(_ l: ElementLocator, engine: MatchEngine) -> Outcome? {
        guard let root = root(for: l) else { return nil }
        let origin = root.windowFrame?.origin

        // A control recorded on one website is never clicked on another, however
        // alike the pages look. A different page on the same site is fine: the
        // same button is often on several of them.
        if let recorded = l.web, let now = AX.webIdentity(inWindow: root.element), !recorded.sameSite(as: now) {
            return Outcome(root: root, elements: [], snapshots: [],
                           report: MatchReport(decision: .notFound([]), ranked: [], shift: nil, anchorsMatched: 0),
                           wrongSite: now.host)
        }

        if let el = AX.resolve(l.path, from: root.element) {
            let snap = AX.snapshot(AX.node(el), origin: origin, path: l.path, context: l.context ?? [])
            let solo = engine.match(l, among: [snap], windowSize: root.windowFrame?.size)
            if let best = solo.best, best.score >= 0.9 {
                return Outcome(root: root, elements: [el], snapshots: [snap], report: solo)
            }
        }

        let wanted = l.role
        let scan = AX.collectBounded(from: root.element, origin: origin) { role in
            role == wanted || AX.matchRoles.contains(role) || MatchEngine.roleCompatibility(wanted, role) > 0
        }
        let found = scan.found
        let snapshots = found.map(\.snapshot)
        var report = engine.match(l, among: snapshots, windowSize: root.windowFrame?.size)
        if scan.truncated { report = report.incomplete() }
        return Outcome(root: root, elements: found.map(\.element), snapshots: snapshots, report: report,
                       truncated: scan.truncated)
    }
}
