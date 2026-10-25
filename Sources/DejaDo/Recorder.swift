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

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var activationObserver: NSObjectProtocol?
    private var lastBundleID: String?
    private var inSecureField = false
    private let ownPID = ProcessInfo.processInfo.processIdentifier

    /// Returns false if macOS refused the event tap (missing Input Monitoring permission).
    func start() -> Bool {
        guard !isRecording else { return true }
        steps = []
        pendingText = ""
        lastBundleID = nil
        inSecureField = false

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
            // Only note the switch; the step is added when the user actually does something there.
            self.pendingApp = (id, app.localizedName ?? id)
        }

        isRecording = true
        onChange?()
        return true
    }

    /// Stops listening and returns the finished steps.
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
        guard let capture = AX.capture(at: point) else { return }
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

        noteApp(id: target.bundleID, name: target.appName)
        let mods = event.flags.rawValue & Input.modifierMask
        steps.append(Step(kind: .click(target: target, button: button, count: 1, modifiers: mods)))
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
        noteFrontApp()
        let label = KeyNames.label(code: code, flags: flags, chars: ns?.charactersIgnoringModifiers)
        steps.append(Step(kind: .key(code: code, modifiers: flags.rawValue & Input.modifierMask, label: label)))
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
