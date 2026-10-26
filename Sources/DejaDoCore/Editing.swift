import Foundation

extension ElementLocator {
    /// The name a person sees on the thing this step clicks, or nil when it has none
    /// (a spot in the window, or something only found by what's near it).
    public var editableName: String? {
        guard role != "AXPosition" else { return nil }
        for t in [label, title, desc] {
            if let t = t?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty { return t }
        }
        return nil
    }

    /// The same target, looked for by a different name: the “Kris” chat
    /// becomes the “Mum” chat, with everything else about it kept.
    ///
    /// Every text that said the old name says the new one. The recorded
    /// picture and any id that carries the old name are dropped, since both
    /// would lead back to the old button. The new name becomes what repairs
    /// are held to, because the person chose it.
    public func renamed(to newName: String) -> ElementLocator {
        let new = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !new.isEmpty, let old = editableName, old != new else { return self }
        func same(_ s: String?) -> Bool {
            guard let s = s?.trimmingCharacters(in: .whitespacesAndNewlines) else { return false }
            return s.compare(old, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
        }
        var l = self
        if same(l.label) { l.label = new }
        if same(l.title) { l.title = new }
        if same(l.desc) { l.desc = new }
        if same(l.value) { l.value = new }
        if same(l.help) { l.help = new }
        l.label = new
        if let id = l.identifier, id.range(of: old, options: [.caseInsensitive, .diacriticInsensitive]) != nil {
            l.identifier = nil
        }
        l.visual = nil
        l.original = nil
        return l
    }
}

extension Step {
    /// The name on what this click or read step looks for, when it can be changed.
    public var targetName: String? {
        switch kind {
        case .click(let t, _, _, _): return t.editableName
        default: return nil
        }
    }

    /// This click, aimed at a differently named button, chat or link.
    /// What it expects to see afterwards follows the new name too: clicking
    /// the “Mum” chat should show “Mum” in the header, not “Kris”.
    public func renamingTarget(to newName: String) -> Step {
        guard case .click(let t, let button, let count, let mods) = kind, let old = t.editableName else { return self }
        let new = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !new.isEmpty, new != old else { return self }
        var s = self
        s.kind = .click(target: t.renamed(to: new), button: button, count: count, modifiers: mods)
        func swap(_ text: String) -> String {
            text.replacingOccurrences(of: old, with: new, options: [.caseInsensitive, .diacriticInsensitive])
        }
        if var e = s.expect {
            e.appeared = e.appeared.map { var x = $0; x.text = swap(x.text); return x }
            e.vanished = e.vanished.map(swap)
            e.windowTitle = e.windowTitle.map(swap)
            s.expect = e
        }
        return s
    }
}
