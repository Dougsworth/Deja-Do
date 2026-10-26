import AppKit
import CoreGraphics
@preconcurrency import DejaDoCore

/// Watches clicks, typing and app switches and turns them into steps.
/// Everything runs on the main thread: the event tap is attached to the main run loop.
/// Screen reads run in the background and hand their results back on the main thread.
final class Recorder: @unchecked Sendable {
    private(set) var steps: [Step] = []
    private(set) var pendingText = ""
    private(set) var isRecording = false

    /// Called on the main thread whenever the recording changes.
    var onChange: (() -> Void)?

    /// Also remember what the screen looked like around each click, for apps
    /// that don't describe their buttons. Needs Screen Recording permission.
    var visionEnabled = false
    /// Note how the screen changed after each click and key press, so runs can check it.
    var checkSteps = true

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var activationObserver: NSObjectProtocol?
    private var lastBundleID: String?
    private var inSecureField = false
    private let ownPID = ProcessInfo.processInfo.processIdentifier

    // The screen is read every half second while recording, and again shortly
    // after each action. A step's "before" is the newest read that started
    // after the previous action, so it shows the screen as it settled and never
    // the step's own effect, which a read started at the click would race with.
    private var generation = 0
    private var reads: [Int: (state: ScreenState, started: Date, finished: Date)] = [:]
    /// Window pictures from recent reads, reused for the picture around a click.
    private var pictures: [Int: (read: ScreenVision.WindowRead, frame: CGRect, pid: pid_t)] = [:]
    private var readCount = 0
    private var inFlight = 0
    private var lastActionAt = Date.distantPast
    /// A click or key step waiting for its "after" read: the read taken at the next action.
    private var pendingCheck: (stepID: UUID, before: Int)?
    private var checkPairs: [(stepID: UUID, before: Int, after: Int)] = []
    private var lastExternalPID: pid_t?
    /// Name of the field being typed into, read when typing starts.
    private var pendingFieldLabel: String?

    /// Returns false if macOS refused the event tap (missing Input Monitoring permission).
    func start() -> Bool {
        guard !isRecording else { return true }
        steps = []
        pendingText = ""
        lastBundleID = nil
        inSecureField = false
        generation += 1
        reads = [:]
        pictures = [:]
        readCount = 0
        inFlight = 0
        lastActionAt = .distantPast
        pendingCheck = nil
        checkPairs = []
        lastExternalPID = nil

        let mask: CGEventMask =
            (1 << CGEventType.leftMouseDown.rawValue) |
            (1 << CGEventType.rightMouseDown.rawValue) |
            (1 << CGEventType.keyDown.rawValue)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                          options: .listenOnly, eventsOfInterest: mask,
                                          callback: recorderTapCallback, userInfo: refcon) else { return false }
        self.tap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let self,
                  let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.processIdentifier != self.ownPID,
                  let id = app.bundleIdentifier else { return }
            // Chrome, Electron and some other apps only describe their buttons once asked.
            AX.wake(pid: app.processIdentifier, bundleID: id)
            // Only note the switch; the step is added when the user actually does something there.
            self.pendingApp = (id, app.localizedName ?? id)
        }

        if let front = NSWorkspace.shared.frontmostApplication, front.processIdentifier != ownPID {
            AX.wake(pid: front.processIdentifier, bundleID: front.bundleIdentifier ?? "")
        }
        isRecording = true
        watchScreen()
        onChange?()
        return true
    }

    /// Stops listening, waits briefly for screen reads still in flight, then
    /// hands back the steps with their visual records and expectations filled in.
    func finish(_ completion: @escaping ([Step]) -> Void) {
        guard isRecording else { completion(steps); return }
        flushText()
        stop()
        let gen = generation
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let me = self else { return }
            // The screen as it was left is the last step's "after".
            await me.readScreen(force: true)
            let deadline = Date().addingTimeInterval(4)
            while Date() < deadline {
                let busy = await MainActor.run { me.inFlight > 0 }
                if !busy { break }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            await MainActor.run {
                guard me.generation == gen else { return }
                me.closePendingCheck(at: me.latestReadSinceLastAction())
                me.applyExpectations()
                completion(me.steps)
            }
        }
    }

    /// Stops listening and returns the steps as they are. Used to discard.
    @discardableResult
    func stop() -> [Step] {
        guard isRecording else { return steps }
        flushText()
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes) }
        if let activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(activationObserver) }
        tap = nil
        runLoopSource = nil
        activationObserver = nil
        isRecording = false
        onChange?()
        return steps
    }

    // MARK: Event handling

    private var pendingApp: (id: String, name: String)?

    fileprivate func handle(type: CGEventType, event: CGEvent) {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
        // The tap's callback must return quickly: when it runs long, macOS
        // switches the tap off and the clicks made meanwhile are lost for good.
        // Reading what was clicked asks the target app over Accessibility, which
        // a freshly launched or busy app can be slow to answer. So the callback
        // only notes the event and when it happened; the work runs right after,
        // in the same order, on the main thread.
        case .leftMouseDown, .rightMouseDown, .keyDown:
            guard let copy = event.copy() else { return }
            let at = Date()
            DispatchQueue.main.async { [weak self] in
                guard let self, self.isRecording else { return }
                self.eventTime = at
                defer { self.eventTime = nil }
                switch type {
                case .leftMouseDown: self.handleClick(copy, button: .left)
                case .rightMouseDown: self.handleClick(copy, button: .right)
                default: self.handleKey(copy)
                }
            }
        default:
            break
        }
    }

    /// When the event being handled actually happened, which may be a moment before it's handled.
    private var eventTime: Date?

    private func handleClick(_ event: CGEvent, button: MouseButtonKind) {
        let point = event.location
        let clickState = Int(event.getIntegerValueField(.mouseEventClickState))
        if AX.isOwn(at: point) { return }
        // The newest read since the last action shows the screen just before this click.
        // The second half of a double click is part of the same step, so it isn't a boundary.
        let shot = clickState >= 2 ? nil : snapshot()
        let stepID = UUID()
        // The picture around the click: from that read when the window hasn't moved,
        // otherwise captured right now.
        let window = AX.windowFrame(at: point)
        let picture = visionEnabled && clickState < 2 ? cachedPicture(shot, window: window) : nil
        if visionEnabled, clickState < 2, picture == nil { recordVisual(stepID: stepID, at: point) }
        // If the app won't describe what was clicked, keep the click anyway as a
        // position inside its window rather than silently losing a step.
        guard let capture = AX.capture(at: point) ?? AX.positionCapture(at: point) else { return }
        let target = capture.locator
        flushText()
        inSecureField = capture.isSecureField

        // The second half of a double click updates the step we just added.
        if clickState >= 2, let last = steps.last,
           case .click(let t, let b, _, let m) = last.kind,
           b == button, t.role == target.role, t.label == target.label, t.bundleID == target.bundleID {
            steps[steps.count - 1].kind = .click(target: t, button: b, count: clickState, modifiers: m)
            onChange?()
            return
        }

        // That read is the previous step's result and this step's starting point.
        closePendingCheck(at: shot)

        noteApp(id: target.bundleID, name: target.appName)
        let mods = event.flags.rawValue & Input.modifierMask
        let step = Step(id: stepID, kind: .click(target: target, button: button, count: 1, modifiers: mods))
        steps.append(step)
        if !capture.isSecureField, let shot { pendingCheck = (step.id, shot) }
        if let picture, let window, !target.inMenu {
            attach(VisualTarget.make(window: picture.image, lines: picture.lines,
                                     click: CGPoint(x: point.x - window.minX, y: point.y - window.minY),
                                     windowSize: window.size), to: stepID)
        }
        if capture.isSecureField {
            // Never record passwords. Ask for it when the automation runs instead.
            steps.append(Step(kind: .type(text: "", askEachRun: true, secret: true,
                                          prompt: "Password for \(target.appName)")))
        }
        onChange?()
    }

    private func handleKey(_ event: CGEvent) {
        if NSWorkspace.shared.frontmostApplication?.processIdentifier == ownPID { return }
        let code = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        let flags = event.flags
        let commandLike = flags.contains(.maskCommand) || flags.contains(.maskControl)
        let ns = NSEvent(cgEvent: event)

        if !commandLike, !KeyNames.special.contains(code), let chars = ns?.characters, isPrintable(chars) {
            if inSecureField { return }
            // Typing starts: whatever the last click or key did is done by now.
            if pendingText.isEmpty, pendingCheck != nil { closePendingCheck(at: snapshot()) }
            if pendingText.isEmpty { pendingFieldLabel = AX.focusedField()?.label }
            noteFrontApp()
            pendingText += chars
            onChange?()
            return
        }

        if code == 51, !commandLike, !pendingText.isEmpty {
            pendingText.removeLast()
            onChange?()
            return
        }

        flushText()
        let shot = snapshot()
        closePendingCheck(at: shot)
        noteFrontApp()
        let label = KeyNames.label(code: code, flags: flags, chars: ns?.charactersIgnoringModifiers)
        let step = Step(kind: .key(code: code, modifiers: flags.rawValue & Input.modifierMask, label: label))
        steps.append(step)
        if !inSecureField, let shot { pendingCheck = (step.id, shot) }
        if code == 48 || code == 36 || code == 76 { inSecureField = false }
        onChange?()
    }

    private func isPrintable(_ s: String) -> Bool {
        guard !s.isEmpty else { return false }
        return s.unicodeScalars.allSatisfy { scalar in
            !CharacterSet.controlCharacters.contains(scalar) && !(0xF700...0xF8FF).contains(scalar.value)
        }
    }

    private func flushText() {
        guard !pendingText.isEmpty else { return }
        steps.append(Step(kind: .type(text: pendingText, askEachRun: false, secret: false, prompt: ""),
                          fieldLabel: pendingFieldLabel))
        pendingText = ""
        pendingFieldLabel = nil
    }

    // MARK: Screen reads

    /// Reads the screen every half second while recording.
    private func watchScreen() {
        guard checkSteps || visionEnabled else { return }
        let gen = generation
        Task.detached(priority: .utility) { [weak self] in
            while true {
                guard let me = self else { return }
                let go = await MainActor.run { me.isRecording && me.generation == gen }
                guard go else { return }
                await me.readScreen()
                try? await Task.sleep(nanoseconds: 450_000_000)
            }
        }
    }

    /// One read of the front window, stored when it finishes.
    private func readScreen(force: Bool = false) async {
        let ticket: (id: Int, pid: pid_t, vision: Bool, gen: Int)? = await MainActor.run {
            guard force || self.isRecording else { return nil }
            if let front = NSWorkspace.shared.frontmostApplication, front.processIdentifier != self.ownPID {
                self.lastExternalPID = front.processIdentifier
            }
            guard let pid = self.lastExternalPID else { return nil }
            let id = self.readCount
            self.readCount += 1
            self.inFlight += 1
            return (id, pid, self.visionEnabled, self.generation)
        }
        guard let ticket else { return }
        let started = Date()
        let full = await ScreenStateReader.readFull(pid: ticket.pid, ocr: ticket.vision, pixels: ticket.vision)
        let finished = Date()
        await MainActor.run {
            self.inFlight -= 1
            guard self.generation == ticket.gen else { return }
            self.reads[ticket.id] = (full.state, started, finished)
            if let picture = full.window, let frame = full.windowFrame {
                self.pictures[ticket.id] = (picture, frame, ticket.pid)
                // Pictures are big; only the last few are ever useful.
                for old in self.pictures.keys where old < ticket.id - 4 { self.pictures[old] = nil }
            }
        }
    }

    /// The newest finished read that started after the last action, if any.
    private func latestReadSinceLastAction() -> Int? {
        // Only reads that began before this action happened show the screen before it.
        let cutoff = eventTime ?? .distantFuture
        return reads.filter { $0.value.started > lastActionAt && $0.value.started < cutoff }
            .max { $0.value.finished < $1.value.finished }?.key
    }

    /// Marks an action: returns the read showing the screen just before it,
    /// and asks for a fresh read once the action has had a moment to land.
    private func snapshot() -> Int? {
        guard checkSteps || visionEnabled else { return nil }
        let before = latestReadSinceLastAction()
        lastActionAt = eventTime ?? Date()
        let gen = generation
        Task.detached(priority: .utility) { [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard let me = self else { return }
            let go = await MainActor.run { me.isRecording && me.generation == gen }
            if go { await me.readScreen() }
        }
        return before
    }

    private func closePendingCheck(at after: Int?) {
        defer { pendingCheck = nil }
        guard let p = pendingCheck, let after, after != p.before else { return }
        checkPairs.append((p.stepID, p.before, after))
    }

    /// The window picture from a read, if that read was of the window clicked in and it hasn't moved since.
    private func cachedPicture(_ id: Int?, window: CGRect?) -> ScreenVision.WindowRead? {
        guard let id, let window, let p = pictures[id],
              abs(p.frame.minX - window.minX) < 1, abs(p.frame.minY - window.minY) < 1,
              abs(p.frame.width - window.width) < 1, abs(p.frame.height - window.height) < 1 else { return nil }
        return p.read
    }

    private func attach(_ visual: VisualTarget, to stepID: UUID) {
        guard let i = steps.firstIndex(where: { $0.id == stepID }),
              case .click(var t, let b, let c, let m) = steps[i].kind, !t.inMenu else { return }
        t.visual = visual
        steps[i].kind = .click(target: t, button: b, count: c, modifiers: m)
        onChange?()
    }

    /// Captures the window around a click and reads its text, then attaches
    /// the result to the click step with that ID when it's ready.
    private func recordVisual(stepID: UUID, at point: CGPoint) {
        guard let wf = AX.windowFrame(at: point) else { return }
        let gen = generation
        inFlight += 1
        Task.detached(priority: .userInitiated) { [weak self] in
            let read = await ScreenVision.read(windowFrame: wf, ocr: true)
            let visual = read.map {
                VisualTarget.make(window: $0.image, lines: $0.lines,
                                  click: CGPoint(x: point.x - wf.minX, y: point.y - wf.minY), windowSize: wf.size)
            }
            guard let me = self else { return }
            await MainActor.run {
                me.inFlight -= 1
                // The step may not exist: the click was on Deja Do, or it joined a double click.
                guard me.generation == gen, let visual else { return }
                me.attach(visual, to: stepID)
            }
        }
    }

    /// Turns each before and after pair into the step's expectation.
    private func applyExpectations() {
        let typed: [String] = steps.compactMap {
            if case .type(let text, let ask, let secret, _) = $0.kind, !ask, !secret { return text }
            return nil
        }
        for (k, pair) in checkPairs.enumerated() {
            guard let before = reads[pair.before]?.state, let after = reads[pair.after]?.state,
                  let i = steps.firstIndex(where: { $0.id == pair.stepID }) else { continue }
            // Clicking into a field only moves focus. What it brings up (a
            // browser's autofill list, suggestions) comes and goes on its own,
            // and whether the typing then lands is checked separately.
            if case .click(let t, _, _, _) = steps[i].kind, AX.editableRoles.contains(t.role) || t.role == "AXSearchField" {
                steps[i].expect = nil
                steps[i].noEffect = nil
                continue
            }
            var e = StepExpectation.derive(before: before, after: after, typed: typed)
            // Text that had gone again by the next action was never a result to wait for.
            if k + 1 < checkPairs.count, let later = reads[checkPairs[k + 1].before]?.state, later.bundleID == after.bundleID {
                e = e.droppingTransient(goneBy: later)
            }
            // Nothing changed when recording, so there is nothing to confirm on a run.
            steps[i].expect = e.changed ? e : nil
            steps[i].noEffect = e.changed ? nil : true
        }
    }

    /// Adds a "switch to app" step whenever the user starts working in a different app.
    private func noteApp(id: String, name: String) {
        pendingApp = nil
        guard id != lastBundleID else { return }
        lastBundleID = id
        steps.append(Step(kind: .activate(bundleID: id, name: name)))
    }

    private func noteFrontApp() {
        if let p = pendingApp { noteApp(id: p.id, name: p.name); return }
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ownPID,
              let id = app.bundleIdentifier else { return }
        noteApp(id: id, name: app.localizedName ?? id)
    }
}

/// C callback for the event tap. It only forwards to the recorder.
private func recorderTapCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent,
                                 refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    if let refcon {
        Unmanaged<Recorder>.fromOpaque(refcon).takeUnretainedValue().handle(type: type, event: event)
    }
    return Unmanaged.passUnretained(event)
}
