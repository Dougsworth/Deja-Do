import AppKit
import ApplicationServices
import DejaDoCore

/// A lightweight copy of the attributes we care about for one element.
struct AXNode {
    let element: AXUIElement
    let role: String
    let subrole: String?
    let title: String?
    let desc: String?
    let identifier: String?
    let help: String?
    let value: String?
    let label: String?
    let frame: CGRect?
}

/// Thin, forgiving wrappers around the C accessibility API.
enum AX {
    static let editableRoles: Set<String> = ["AXTextField", "AXTextArea", "AXComboBox"]
    static let actionableRoles: Set<String> = [
        "AXButton", "AXLink", "AXMenuItem", "AXMenuBarItem", "AXCheckBox", "AXRadioButton",
        "AXPopUpButton", "AXMenuButton", "AXTextField", "AXTextArea", "AXComboBox", "AXCell",
        "AXRow", "AXTab", "AXSlider", "AXDisclosureTriangle", "AXIncrementor", "AXColorWell"
    ]
    /// Elements worth reading when matching: things you can act on, plus the
    /// text and images that serve as anchors.
    static let matchRoles: Set<String> = actionableRoles.union(["AXStaticText", "AXImage", "AXHeading"])
    /// Named containers that describe where an element lives ("Toolbar", "Sidebar").
    static let containerRoles: Set<String> = [
        "AXGroup", "AXToolbar", "AXTabGroup", "AXSplitGroup", "AXScrollArea", "AXList", "AXOutline",
        "AXTable", "AXSheet", "AXDrawer", "AXPopover", "AXRadioGroup", "AXLayoutArea", "AXBrowser", "AXGrid"
    ]
    static let chromiumBrowsers: Set<String> = [
        "com.google.Chrome", "com.microsoft.edgemac", "com.brave.Browser", "com.vivaldi.Vivaldi", "company.thebrowser.Browser"
    ]

    // MARK: Attributes

    static func raw(_ el: AXUIElement, _ attr: String) -> CFTypeRef? {
        var v: CFTypeRef?
        return AXUIElementCopyAttributeValue(el, attr as CFString, &v) == .success ? v : nil
    }

    /// Reads several attributes in one round trip to the target app. Each
    /// attribute read is a separate IPC call otherwise, which is what makes
    /// walking a big window slow.
    static func fetch(_ el: AXUIElement, _ attrs: [String]) -> [String: CFTypeRef] {
        var values: CFArray?
        let err = AXUIElementCopyMultipleAttributeValues(el, attrs as CFArray, AXCopyMultipleAttributeOptions(rawValue: 0), &values)
        guard err == .success, let array = values as? [AnyObject] else { return [:] }
        var out: [String: CFTypeRef] = [:]
        for (i, v) in array.enumerated() where i < attrs.count {
            let ref = v as CFTypeRef
            if CFGetTypeID(ref) == AXValueGetTypeID(), AXValueGetType(ref as! AXValue) == .axError { continue }
            out[attrs[i]] = ref
        }
        return out
    }

    static func string(_ v: CFTypeRef?) -> String? {
        guard let v, CFGetTypeID(v) == CFStringGetTypeID() else { return nil }
        let s = (v as! String).trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty ? nil : s
    }

    static func string(_ el: AXUIElement, _ attr: String) -> String? { string(raw(el, attr)) }

    static func element(_ el: AXUIElement, _ attr: String) -> AXUIElement? {
        guard let v = raw(el, attr), CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        return (v as! AXUIElement)
    }

    static func elements(_ v: CFTypeRef?) -> [AXUIElement] {
        guard let v, CFGetTypeID(v) == CFArrayGetTypeID() else { return [] }
        return (v as? [AXUIElement]) ?? []
    }

    static func children(_ el: AXUIElement) -> [AXUIElement] { elements(raw(el, kAXChildrenAttribute)) }

    static func role(_ el: AXUIElement) -> String { string(el, kAXRoleAttribute) ?? "AXUnknown" }

    static func frame(position p: CFTypeRef?, size s: CFTypeRef?) -> CGRect? {
        guard let p, let s, CFGetTypeID(p) == AXValueGetTypeID(), CFGetTypeID(s) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        var size = CGSize.zero
        AXValueGetValue(p as! AXValue, .cgPoint, &point)
        AXValueGetValue(s as! AXValue, .cgSize, &size)
        return CGRect(origin: point, size: size)
    }

    static func frame(_ el: AXUIElement) -> CGRect? {
        let a = fetch(el, [kAXPositionAttribute, kAXSizeAttribute])
        return frame(position: a[kAXPositionAttribute], size: a[kAXSizeAttribute])
    }

    static func actions(_ el: AXUIElement) -> [String] {
        var names: CFArray?
        guard AXUIElementCopyActionNames(el, &names) == .success, let list = names as? [String] else { return [] }
        return list
    }

    static func pid(_ el: AXUIElement) -> pid_t {
        var p: pid_t = 0
        AXUIElementGetPid(el, &p)
        return p
    }

    @discardableResult
    static func perform(_ el: AXUIElement, _ action: String) -> Bool {
        AXUIElementPerformAction(el, action as CFString) == .success
    }

    static func element(at point: CGPoint) -> AXUIElement? {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 1.0)
        var el: AXUIElement?
        guard AXUIElementCopyElementAtPosition(system, Float(point.x), Float(point.y), &el) == .success else { return nil }
        return el
    }

    /// Chrome and Electron apps only build their accessibility tree when asked.
    static func wake(app el: AXUIElement, bundleID: String) {
        AXUIElementSetAttributeValue(el, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        if chromiumBrowsers.contains(bundleID) {
            AXUIElementSetAttributeValue(el, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
        }
    }

    static func wake(pid: pid_t, bundleID: String) {
        let el = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(el, 0.5)
        wake(app: el, bundleID: bundleID)
    }

    /// True when the point is over one of Deja Do's own windows or menus.
    static func isOwn(at point: CGPoint) -> Bool {
        let me = ProcessInfo.processInfo.processIdentifier
        if let hit = element(at: point) { return pid(hit) == me }
        let height = NSScreen.screens.first?.frame.height ?? 0
        let flipped = NSPoint(x: point.x, y: height - point.y)
        return NSApp.windows.contains { $0.isVisible && $0.frame.contains(flipped) }
    }

    /// Frame of the window under a screen point, or else of the front app's focused window.
    static func windowFrame(at point: CGPoint) -> CGRect? {
        if let hit = element(at: point), let w = element(hit, kAXWindowAttribute), let f = frame(w) { return f }
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return nil }
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(appElement, 0.5)
        return element(appElement, kAXFocusedWindowAttribute).flatMap { frame($0) }
    }

    /// Role used for clicks recorded only by where they landed in the window.
    static let positionRole = "AXPosition"

    /// A click the app couldn't describe: remember where in the frontmost
    /// window it landed, so replay can click the same spot.
    static func positionCapture(at point: CGPoint) -> Capture? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return nil }
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(appElement, 0.5)
        let window = element(appElement, kAXFocusedWindowAttribute)
        let wf = window.flatMap { frame($0) }
        let origin = wf?.origin ?? .zero
        let spot = CGRect(x: point.x - origin.x - 4, y: point.y - origin.y - 4, width: 8, height: 8)
        let bundleID = app.bundleIdentifier ?? app.localizedName ?? "unknown"
        let locator = ElementLocator(
            bundleID: bundleID, appName: app.localizedName ?? bundleID,
            windowTitle: window.flatMap { string($0, kAXTitleAttribute) },
            role: positionRole, subrole: nil, title: nil, desc: nil, identifier: nil, help: nil,
            value: nil, label: nil, path: [], frameInWindow: spot,
            clickOffset: CGPoint(x: 0.5, y: 0.5), inMenu: false, anchors: nil, context: nil,
            windowSize: wf?.size)
        return Capture(locator: locator, isSecureField: false)
    }

    // MARK: Nodes

    static let nodeAttrs: [String] = [
        kAXRoleAttribute, kAXSubroleAttribute, kAXTitleAttribute, kAXDescriptionAttribute,
        kAXIdentifierAttribute, kAXHelpAttribute, kAXValueAttribute, kAXPositionAttribute,
        kAXSizeAttribute, kAXChildrenAttribute
    ]

    static func node(_ el: AXUIElement) -> AXNode { node(el, attrs: fetch(el, nodeAttrs)) }

    static func node(_ el: AXUIElement, attrs a: [String: CFTypeRef]) -> AXNode {
        let r = string(a[kAXRoleAttribute]) ?? "AXUnknown"
        let title = string(a[kAXTitleAttribute]), desc = string(a[kAXDescriptionAttribute])
        let rawValue = editableRoles.contains(r) ? nil : string(a[kAXValueAttribute])
        let value = (rawValue?.count ?? 0) <= 80 ? rawValue : nil
        return AXNode(
            element: el,
            role: r,
            subrole: string(a[kAXSubroleAttribute]),
            title: title,
            desc: desc,
            identifier: string(a[kAXIdentifierAttribute]),
            help: string(a[kAXHelpAttribute]),
            value: value,
            label: title ?? desc ?? value ?? fallbackLabel(el, role: r, children: elements(a[kAXChildrenAttribute])),
            frame: frame(position: a[kAXPositionAttribute], size: a[kAXSizeAttribute])
        )
    }

    /// The name a person would use when title, description and value are empty.
    private static func fallbackLabel(_ el: AXUIElement, role: String, children: [AXUIElement]) -> String? {
        if let p = string(el, "AXPlaceholderValue") { return p }
        if let t = element(el, kAXTitleUIElementAttribute),
           let s = string(t, kAXValueAttribute) ?? string(t, kAXTitleAttribute) { return s }
        guard role != "AXStaticText" else { return nil }
        return textInChildren(children, depth: 2)
    }

    private static func textInChildren(_ kids: [AXUIElement], depth: Int) -> String? {
        guard depth > 0 else { return nil }
        for child in kids.prefix(12) {
            let a = fetch(child, [kAXRoleAttribute, kAXValueAttribute, kAXChildrenAttribute])
            if string(a[kAXRoleAttribute]) == "AXStaticText", let v = string(a[kAXValueAttribute]), v.count <= 80 { return v }
            if let found = textInChildren(elements(a[kAXChildrenAttribute]), depth: depth - 1) { return found }
        }
        return nil
    }

    static func snapshot(_ n: AXNode, origin: CGPoint?, path: [PathStep], context: [String]) -> ElementSnapshot {
        var rel = n.frame
        if let f = n.frame, let o = origin { rel = f.offsetBy(dx: -o.x, dy: -o.y) }
        return ElementSnapshot(role: n.role, subrole: n.subrole, title: n.title, desc: n.desc,
                               identifier: n.identifier, help: n.help, value: n.value, label: n.label,
                               frame: rel, path: path, context: context)
    }

    // MARK: Walking

    /// Counts same-role siblings as breadth first search visits them in order,
    /// so every element's path comes for free without extra parent lookups.
    private final class SiblingCounter {
        var counts: [String: Int] = [:]
        func next(_ role: String) -> Int {
            let i = counts[role, default: 0]
            counts[role] = i + 1
            return i
        }
    }

    struct Found {
        let element: AXUIElement
        let node: AXNode
        let snapshot: ElementSnapshot
    }

    /// Breadth first walk that returns snapshots, with tree paths and container
    /// context, for elements whose role passes `include`. Capped so huge web
    /// pages can't hang a replay.
    static func collect(from root: AXUIElement, origin: CGPoint?, limit: Int = 4000,
                        include: (String) -> Bool) -> [Found] {
        struct Item { let el: AXUIElement; let path: [PathStep]; let context: [String]; let siblings: SiblingCounter? }
        var queue = [Item(el: root, path: [], context: [], siblings: nil)]
        var head = 0
        var out: [Found] = []
        while head < queue.count && head < limit {
            let item = queue[head]
            head += 1
            let a = fetch(item.el, nodeAttrs)
            let r = string(a[kAXRoleAttribute]) ?? "AXUnknown"
            let path = item.siblings.map { item.path + [PathStep(role: r, index: $0.next(r))] } ?? item.path

            var context = item.context
            if containerRoles.contains(r), let name = string(a[kAXTitleAttribute]) ?? string(a[kAXDescriptionAttribute]) {
                context = Array(([name] + context).prefix(4))
            }
            if item.siblings != nil, include(r) {
                let n = node(item.el, attrs: a)
                out.append(Found(element: item.el, node: n, snapshot: snapshot(n, origin: origin, path: path, context: item.context)))
            }
            let counter = SiblingCounter()
            for child in elements(a[kAXChildrenAttribute]) {
                queue.append(Item(el: child, path: path, context: context, siblings: counter))
            }
        }
        return out
    }

    /// A cheap summary of what a window looks like right now, for settle detection.
    static func fingerprint(_ root: AXUIElement, limit: Int = 400) -> (hash: Int, busy: Bool) {
        var fp = TreeFingerprint()
        var busy = false
        var queue = [root]
        var head = 0
        let attrs = [kAXRoleAttribute, kAXChildrenAttribute, kAXPositionAttribute, kAXSizeAttribute]
        while head < queue.count && head < limit {
            let a = fetch(queue[head], attrs)
            head += 1
            let r = string(a[kAXRoleAttribute]) ?? "AXUnknown"
            if r == "AXBusyIndicator" { busy = true }
            let kids = elements(a[kAXChildrenAttribute])
            let f = frame(position: a[kAXPositionAttribute], size: a[kAXSizeAttribute])
            fp.add(role: r, childCount: kids.count,
                   x: f.map { Double($0.minX) }, y: f.map { Double($0.minY) },
                   w: f.map { Double($0.width) }, h: f.map { Double($0.height) })
            queue.append(contentsOf: kids)
        }
        return (fp.finalize(), busy)
    }

    // MARK: Paths

    static func path(from el: AXUIElement, to root: AXUIElement) -> [PathStep] {
        var steps: [PathStep] = []
        var current = el
        for _ in 0..<80 {
            if CFEqual(current, root) { break }
            guard let parent = element(current, kAXParentAttribute) else { break }
            let r = role(current)
            let siblings = children(parent).filter { role($0) == r }
            let index = siblings.firstIndex { CFEqual($0, current) } ?? 0
            steps.append(PathStep(role: r, index: index))
            current = parent
        }
        return steps.reversed()
    }

    static func resolve(_ path: [PathStep], from root: AXUIElement) -> AXUIElement? {
        var current = root
        for step in path {
            let siblings = children(current).filter { role($0) == step.role }
            guard step.index < siblings.count else { return nil }
            current = siblings[step.index]
        }
        return current
    }

    /// Titles of named containers above the element, nearest first.
    static func context(of el: AXUIElement, stopAt root: AXUIElement) -> [String] {
        var out: [String] = []
        var current = element(el, kAXParentAttribute)
        for _ in 0..<12 {
            guard let c = current, !CFEqual(c, root), out.count < 4 else { break }
            let a = fetch(c, [kAXRoleAttribute, kAXTitleAttribute, kAXDescriptionAttribute, kAXParentAttribute])
            if containerRoles.contains(string(a[kAXRoleAttribute]) ?? ""),
               let name = string(a[kAXTitleAttribute]) ?? string(a[kAXDescriptionAttribute]) {
                out.append(name)
            }
            current = a[kAXParentAttribute].flatMap { CFGetTypeID($0) == AXUIElementGetTypeID() ? ($0 as! AXUIElement) : nil }
        }
        return out
    }

    /// Up to four labelled elements close to the target, found by walking a
    /// few levels up and searching that neighbourhood.
    static func anchors(around el: AXUIElement, frame: CGRect?, label: String?, root: AXUIElement) -> [Anchor] {
        guard let frame else { return [] }
        var hood = el
        for _ in 0..<3 {
            guard let p = element(hood, kAXParentAttribute), !CFEqual(p, root) else { break }
            hood = p
        }
        let center = CGPoint(x: frame.midX, y: frame.midY)
        let own = label.map(TextSimilarity.normalize)
        let found = collect(from: hood, origin: nil, limit: 500) { matchRoles.contains($0) }

        var picks: [(Anchor, CGFloat)] = []
        var seen = Set<String>()
        for f in found {
            guard let text = f.node.label, text.count <= 60, let fr = f.node.frame, fr.width > 0, fr.height > 0 else { continue }
            let key = TextSimilarity.normalize(text)
            guard !key.isEmpty, key != own, !seen.contains(key) else { continue }
            // Skip the target's own pieces: anything sitting inside its frame.
            if frame.contains(CGPoint(x: fr.midX, y: fr.midY)) { continue }
            let offset = CGPoint(x: fr.midX - center.x, y: fr.midY - center.y)
            let d = hypot(offset.x, offset.y)
            guard d <= 320 else { continue }
            seen.insert(key)
            picks.append((Anchor(label: text, role: f.node.role, offset: offset), d))
        }
        return picks.sorted { $0.1 < $1.1 }.prefix(4).map { $0.0 }
    }

    // MARK: Building a locator

    struct Capture {
        let locator: ElementLocator
        let isSecureField: Bool
    }

    /// Looks at what is under the mouse right now and describes it.
    /// Returns nil for our own windows, so we never record ourselves.
    static func capture(at point: CGPoint) -> Capture? {
        guard let hit = element(at: point) else { return nil }
        let ownerPID = Self.pid(hit)
        if ownerPID == ProcessInfo.processInfo.processIdentifier { return nil }

        // Clicks often land on a label inside a button. Climb to the thing that acts.
        var target = hit
        var probe: AXUIElement? = hit
        for _ in 0..<4 {
            guard let p = probe else { break }
            if actionableRoles.contains(role(p)) || actions(p).contains(kAXPressAction) { target = p; break }
            probe = element(p, kAXParentAttribute)
        }
        guard let locator = makeLocator(for: target, pid: ownerPID, clickPoint: point) else { return nil }
        return Capture(locator: locator, isSecureField: locator.subrole == "AXSecureTextField")
    }

    static func makeLocator(for el: AXUIElement, pid: pid_t, clickPoint: CGPoint?) -> ElementLocator? {
        guard let app = NSRunningApplication(processIdentifier: pid) else { return nil }
        let bundleID = app.bundleIdentifier ?? app.localizedName ?? "unknown"
        let n = Self.node(el)
        let window = Self.element(el, kAXWindowAttribute)
        let inMenu = window == nil || n.role.hasPrefix("AXMenu")
        let appElement = AXUIElementCreateApplication(pid)
        let root = (inMenu ? nil : window) ?? appElement
        let windowFrame = window.flatMap { Self.frame($0) }

        var relFrame: CGRect?
        if let f = n.frame, let wf = windowFrame {
            relFrame = f.offsetBy(dx: -wf.minX, dy: -wf.minY)
        }
        var offset = CGPoint(x: 0.5, y: 0.5)
        if let p = clickPoint, let f = n.frame, f.width > 0, f.height > 0 {
            offset = CGPoint(x: min(max((p.x - f.minX) / f.width, 0), 1),
                             y: min(max((p.y - f.minY) / f.height, 0), 1))
        }

        return ElementLocator(
            bundleID: bundleID,
            appName: app.localizedName ?? bundleID,
            windowTitle: window.flatMap { Self.string($0, kAXTitleAttribute) },
            role: n.role,
            subrole: n.subrole,
            title: n.title,
            desc: n.desc,
            identifier: n.identifier,
            help: n.help,
            value: n.value,
            label: n.label,
            path: Self.path(from: el, to: root),
            frameInWindow: relFrame,
            clickOffset: offset,
            inMenu: inMenu,
            anchors: inMenu ? nil : Self.anchors(around: el, frame: n.frame, label: n.label, root: root),
            context: Self.context(of: el, stopAt: root),
            windowSize: windowFrame?.size
        )
    }
}
