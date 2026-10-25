import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// One hop in the accessibility tree: "the 2nd AXButton under my parent".
public struct PathStep: Codable, Equatable, Hashable {
    public var role: String
    public var index: Int

    public init(role: String, index: Int) {
        self.role = role
        self.index = index
    }
}

/// A labelled element that sat near the target when it was recorded.
/// Icon buttons have no text of their own, so "the button just right of
/// the Email label" is often the only reliable way to find them again.
public struct Anchor: Codable, Equatable {
    public var label: String
    public var role: String
    /// Anchor centre minus target centre, in points.
    public var offset: CGPoint

    public init(label: String, role: String, offset: CGPoint) {
        self.label = label
        self.role = role
        self.offset = offset
    }
}

/// Everything we know about the element the user clicked, so we can find it
/// again later even if the window moved or the layout shifted.
public struct ElementLocator: Codable, Equatable {
    public var bundleID: String
    public var appName: String
    public var windowTitle: String?
    public var role: String
    public var subrole: String?
    public var title: String?
    public var desc: String?
    public var identifier: String?
    public var help: String?
    public var value: String?
    /// Best human readable name for the element.
    public var label: String?
    /// Route from the window (or the app, for menus) down to the element.
    public var path: [PathStep]
    /// Element frame relative to its window's top left corner.
    public var frameInWindow: CGRect?
    /// Where inside the element the user clicked, as a 0...1 fraction.
    public var clickOffset: CGPoint
    /// Menu bar menus and pop up menus live on the app, not a window.
    public var inMenu: Bool
    /// Nearby labelled elements. Optional so automations saved by older versions still load.
    public var anchors: [Anchor]?
    /// Titles of the groups, toolbars and panes around the element, nearest first.
    public var context: [String]?
    /// Window size when recorded, used to predict where right or bottom aligned controls moved.
    public var windowSize: CGSize?

    public init(bundleID: String, appName: String, windowTitle: String?, role: String, subrole: String?,
                title: String?, desc: String?, identifier: String?, help: String?, value: String?,
                label: String?, path: [PathStep], frameInWindow: CGRect?, clickOffset: CGPoint,
                inMenu: Bool, anchors: [Anchor]? = nil, context: [String]? = nil, windowSize: CGSize? = nil) {
        self.bundleID = bundleID
        self.appName = appName
        self.windowTitle = windowTitle
        self.role = role
        self.subrole = subrole
        self.title = title
        self.desc = desc
        self.identifier = identifier
        self.help = help
        self.value = value
        self.label = label
        self.path = path
        self.frameInWindow = frameInWindow
        self.clickOffset = clickOffset
        self.inMenu = inMenu
        self.anchors = anchors
        self.context = context
        self.windowSize = windowSize
    }

    public var hasText: Bool {
        [identifier, title, desc, label].contains { !($0 ?? "").isEmpty }
    }

    /// The recorded element as a snapshot, so it can be compared like any candidate.
    public var snapshot: ElementSnapshot {
        ElementSnapshot(role: role, subrole: subrole, title: title, desc: desc, identifier: identifier,
                        help: help, value: value, label: label, frame: frameInWindow, path: path,
                        context: context ?? [])
    }
}

public enum MouseButtonKind: String, Codable {
    case left, right
}

public struct Step: Identifiable, Codable, Equatable {
    public var id = UUID()
    public var kind: Kind

    public init(id: UUID = UUID(), kind: Kind) {
        self.id = id
        self.kind = kind
    }

    public enum Kind: Codable, Equatable {
        case activate(bundleID: String, name: String)
        case click(target: ElementLocator, button: MouseButtonKind, count: Int, modifiers: UInt64)
        case type(text: String, askEachRun: Bool, secret: Bool, prompt: String)
        case key(code: UInt16, modifiers: UInt64, label: String)
        case wait(seconds: Double)
    }
}

public struct Automation: Identifiable, Codable, Equatable {
    public var id = UUID()
    public var name: String
    public var steps: [Step]
    public var created = Date()
    public var lastRun: Date?
    public var runs = 0
    /// How many times AI found an element the recording could not.
    public var repairs = 0
    /// Whether the most recent run finished. Optional so older files still load.
    public var lastSucceeded: Bool?
    /// How long the most recent run took, in seconds.
    public var lastDuration: Double?

    public init(id: UUID = UUID(), name: String, steps: [Step], created: Date = Date(),
                lastRun: Date? = nil, runs: Int = 0, repairs: Int = 0,
                lastSucceeded: Bool? = nil, lastDuration: Double? = nil) {
        self.id = id
        self.name = name
        self.steps = steps
        self.created = created
        self.lastRun = lastRun
        self.runs = runs
        self.repairs = repairs
        self.lastSucceeded = lastSucceeded
        self.lastDuration = lastDuration
    }
}

// MARK: - Human readable descriptions

extension Step {
    public var symbol: String {
        switch kind {
        case .activate: return "macwindow"
        case .click: return "cursorarrow.click"
        case .type(_, _, let secret, _): return secret ? "lock" : "character.cursor.ibeam"
        case .key: return "command"
        case .wait: return "clock"
        }
    }

    public var summary: String {
        switch kind {
        case .activate(_, let name):
            return "Switch to \(name)"
        case .click(let t, let button, let count, _):
            let verb = count >= 2 ? "Double click" : (button == .right ? "Right click" : "Click")
            if t.role == "AXPosition", let f = t.frameInWindow {
                return "\(verb) at \(Int(f.midX)), \(Int(f.midY)) in the window"
            }
            let what = Self.friendlyRole(t.role, subrole: t.subrole)
            if let label = t.label, !label.isEmpty {
                return "\(verb) \(what) “\(label.prefix(60))”"
            }
            if let near = t.anchors?.first {
                return "\(verb) \(what) near “\(near.label.prefix(40))”"
            }
            return "\(verb) \(what)"
        case .type(let text, let ask, let secret, let prompt):
            if secret { return prompt.isEmpty ? "Type a password, asked each run" : prompt }
            if ask { return "Type text, asked each run" }
            return "Type “\(text.prefix(60))\(text.count > 60 ? "…" : "")”"
        case .key(_, _, let label):
            return "Press \(label)"
        case .wait(let s):
            return "Wait \(Self.seconds(s)) seconds"
        }
    }

    public var detail: String? {
        if case .click(let t, _, _, _) = kind {
            if let w = t.windowTitle, !w.isEmpty, w != t.appName { return "\(t.appName), \(w)" }
            return t.appName
        }
        return nil
    }

    static func seconds(_ s: Double) -> String {
        s == s.rounded() ? String(Int(s)) : String(format: "%.1f", s)
    }

    public static func friendlyRole(_ role: String, subrole: String?) -> String {
        if subrole == "AXSecureTextField" { return "password field" }
        if subrole == "AXSearchField" { return "search field" }
        switch role {
        case "AXButton": return "button"
        case "AXLink": return "link"
        case "AXTextField": return "text field"
        case "AXTextArea": return "text area"
        case "AXComboBox": return "combo box"
        case "AXCheckBox": return "checkbox"
        case "AXRadioButton": return "option"
        case "AXPopUpButton": return "pop up"
        case "AXMenuButton": return "menu button"
        case "AXMenuItem": return "menu item"
        case "AXMenuBarItem": return "menu"
        case "AXCell", "AXRow": return "row"
        case "AXStaticText": return "text"
        case "AXImage": return "image"
        case "AXTab": return "tab"
        case "AXSlider": return "slider"
        case "AXWebArea": return "page"
        default:
            return role.replacingOccurrences(of: "AX", with: "").lowercased()
        }
    }
}

// MARK: - Storage

/// Saves each automation as its own JSON file in Application Support.
public struct Persistence {
    public let dir: URL

    /// - Parameter base: override for tests. Defaults to Application Support.
    public init(base: URL? = nil) {
        let root = base ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        dir = root.appendingPathComponent("Deja Do/Automations", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        Self.migrate(from: root.appendingPathComponent("Once/Automations", isDirectory: true), to: dir)
    }

    /// Copies automations recorded while the app was still called Once. Never deletes the originals.
    static func migrate(from old: URL, to new: URL) {
        let fm = FileManager.default
        guard let oldFiles = try? fm.contentsOfDirectory(at: old, includingPropertiesForKeys: nil),
              !oldFiles.isEmpty else { return }
        for file in oldFiles where file.pathExtension == "json" {
            let target = new.appendingPathComponent(file.lastPathComponent)
            if !fm.fileExists(atPath: target.path) { try? fm.copyItem(at: file, to: target) }
        }
    }

    private func url(_ id: UUID) -> URL { dir.appendingPathComponent("\(id.uuidString).json") }

    public func loadAll() -> [Automation] {
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return files
            .filter { $0.pathExtension == "json" }
            .compactMap { try? decoder.decode(Automation.self, from: Data(contentsOf: $0)) }
            .sorted { $0.created > $1.created }
    }

    public func save(_ a: Automation) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(a) {
            try? data.write(to: url(a.id), options: .atomic)
        }
    }

    public func delete(_ id: UUID) {
        try? FileManager.default.removeItem(at: url(id))
    }
}
