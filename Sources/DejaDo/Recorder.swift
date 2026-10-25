import AppKit
import CoreGraphics
import DejaDoCore

/// Watches clicks, typing and app switches and turns them into steps.
/// Everything runs on the main thread: the event tap is attached to the main run loop.
final class Recorder {
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

    // Screen reads happen off the main thread and land here later.
    private let work = DispatchGroup()
    private var generation = 0
    private var snapshots: [Int: ScreenState] = [:]
    private var snapshotCount = 0
    /// A click or key step waiting for its "after" read: the read taken at the next action.
    private var pendingCheck: (stepID: UUID, before: Int)?
    private var checkPairs: [(stepID: UUID, before: Int, after: Int)] = []
    private var lastExternalPID: pid_t?

    /// Returns false if macOS refused the event tap (missing Input Monitoring permission).
    func start() -> Bool {
        guard !isRecording else { return true }
        steps = []
        pendingText = ""
        lastBundleID = nil
        inSecureField = false
        generation += 1
        snapshots = [:]
        snapshotCount = 0
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
        onChange?()
        return true
    }

    /// Stops listening, waits briefly for screen reads still in flight, then
    /// hands back the steps with their visual records and expectations filled in.
    func finish(_ completion: @escaping ([Step]) -> Void) {
        guard isRecording else { completion(steps); return }
        flushText()
        // The screen as it was left is the last step's "after".
        closePendingCheck(at: snapshot())
        stop()
        let group = work, gen = generation
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            _ = group.wait(timeout: .now() + 4)
            DispatchQueue.main.async {
                guard let self, self.generation == gen else { return }
                self.applyExpectations()
                completion(self.steps)
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
        case .leftMouseDown:
            handleClick(event, button: .left)
        case .rightMouseDown:
            handleClick(event, button: .right)
        case .keyDown:
            handleKey(event)
        default:
            break
        }
    }

    private func handleClick(_ event: CGEvent, button: MouseButtonKind) {
        let point = event.location
        let clickState = Int(event.getIntegerValueField(.mouseEventClickState))
        if AX.isOwn(at: point) { return }
        // Start reading the screen before anything else, while it still shows
        // the previous step's result: most apps react when the button comes back up.
        // The second half of a double click is part of the same step, so it isn't a boundary.
        let shot = clickState >= 2 ? nil : snapshot()
        let stepID = UUID()
        if visionEnabled, clickState < 2 { recordVisual(stepID: stepID, at: point) }
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
        steps.append(Step(kind: .type(text: pendingText, askEachRun: false, secret: false, prompt: "")))
        pendingText = ""
    }

    // MARK: Screen reads

    /// Starts reading the front window in the background and returns the
    /// read's number. Returns nil when step checking is off.
    private func snapshot() -> Int? {
        guard checkSteps else { return nil }
        if let front = NSWorkspace.shared.frontmostApplication, front.processIdentifier != ownPID {
            lastExternalPID = front.processIdentifier
        }
        guard let pid = lastExternalPID else { return nil }
        let index = snapshotCount
        snapshotCount += 1
        let vision = visionEnabled, gen = generation
        work.enter()
        Task.detached(priority: .userInitiated) { [weak self] in
            let state = await ScreenStateReader.read(pid: pid, ocr: vision, pixels: vision)
            DispatchQueue.main.async {
                if let self, self.generation == gen { self.snapshots[index] = state }
                self?.work.leave()
            }
        }
        return index
    }

    private func closePendingCheck(at after: Int?) {
        defer { pendingCheck = nil }
        guard let p = pendingCheck, let after else { return }
        checkPairs.append((p.stepID, p.before, after))
    }

    /// Captures the window around a click and reads its text, then attaches
    /// the result to the click step with that ID when it's ready.
    private func recordVisual(stepID: UUID, at point: CGPoint) {
        guard let wf = AX.windowFrame(at: point) else { return }
        let gen = generation
        work.enter()
        Task.detached(priority: .userInitiated) { [weak self] in
            let read = await ScreenVision.read(windowFrame: wf, ocr: true)
            let visual = read.map {
                VisualTarget.make(window: $0.image, lines: $0.lines,
                                  click: CGPoint(x: point.x - wf.minX, y: point.y - wf.minY), windowSize: wf.size)
            }
            DispatchQueue.main.async {
                defer { self?.work.leave() }
                // The step may not exist: the click was on Deja Do, or it joined a double click.
                guard let self, self.generation == gen, let visual,
                      let i = self.steps.firstIndex(where: { $0.id == stepID }),
                      case .click(var t, let b, let c, let m) = self.steps[i].kind, !t.inMenu else { return }
                t.visual = visual
                self.steps[i].kind = .click(target: t, button: b, count: c, modifiers: m)
                self.onChange?()
            }
        }
    }

    /// Turns each before and after pair into the step's expectation.
    private func applyExpectations() {
        let typed: [String] = steps.compactMap {
            if case .type(let text, let ask, let secret, _) = $0.kind, !ask, !secret { return text }
            return nil
        }
        for pair in checkPairs {
            guard let before = snapshots[pair.before], let after = snapshots[pair.after],
                  let i = steps.firstIndex(where: { $0.id == pair.stepID }) else { continue }
            let e = StepExpectation.derive(before: before, after: after, typed: typed)
            // Nothing changed when recording, so there is nothing to confirm on a run.
            steps[i].expect = e.changed ? e : nil
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
