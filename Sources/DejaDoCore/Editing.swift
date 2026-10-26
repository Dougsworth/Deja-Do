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
    /// Every text that said the old name says the new one. What tied it to
    /// the old button in particular is dropped, so the name decides. The new
    /// name becomes what repairs are held to, because the person chose it.
    public func renamed(to newName: String) -> ElementLocator {
        let new = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !new.isEmpty, let old = editableName, old != new else { return self }
        func same(_ s: String?) -> Bool {
            guard let s = s?.trimmingCharacters(in: .whitespacesAndNewlines) else { return false }
            return s.compare(old, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
        }
        var l = self
        if same(l.title) { l.title = new }
        if same(l.desc) { l.desc = new }
        if same(l.value) { l.value = new }
        if same(l.help) { l.help = new }
        l.label = new
        // The id, the place in the tree, the labels that sat beside it and the
        // picture all describe the old one, and would pull the match back to it.
        l.identifier = nil
        l.path = []
        l.anchors = nil
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
        if let e = s.expect { s.expect = e.replacing(old, with: new) }
        return s
    }
}

extension StepExpectation {
    /// The same check with one piece of text swapped for another, wherever it shows up.
    public func replacing(_ old: String, with new: String) -> StepExpectation {
        guard !old.isEmpty, old != new else { return self }
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        func swap(_ text: String) -> String {
            // A short name like “8” is only swapped where it's the whole text, not inside “18:05”.
            if old.count < 3 {
                return text.trimmingCharacters(in: .whitespaces).compare(old, options: options) == .orderedSame ? new : text
            }
            return text.replacingOccurrences(of: old, with: new, options: options)
        }
        var e = self
        e.appeared = e.appeared.map { var x = $0; x.text = swap(x.text); return x }
        e.vanished = e.vanished.map(swap)
        e.windowTitle = e.windowTitle.map(swap)
        return e
    }
}

extension Automation {
    /// Call after the person changes, adds, removes or moves a step by hand.
    ///
    /// Steps from `index` on may have expected what the old version produced.
    /// Where the change is a piece of text (a new name to click, new words to
    /// type), their checks follow it. Anything that can't be traced, like a
    /// total that now comes out different, is learned again on the next run
    /// rather than stopping it.
    public mutating func noteEdit(at index: Int, replacing old: String? = nil, with new: String? = nil) {
        guard index < steps.count else { return }
        for j in max(0, index)..<steps.count {
            guard var e = steps[j].expect else { continue }
            if let old, let new { e = e.replacing(old, with: new) }
            steps[j].expect = e
            steps[j].recheck = true
        }
    }
}
