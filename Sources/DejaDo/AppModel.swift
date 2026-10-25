import AppKit
import SwiftUI
import DejaDoCore

/// App state shared by the menu bar and the main window. Only touched on the
/// main thread, which is why it can be marked as safe to hand across tasks.
final class AppModel: ObservableObject, @unchecked Sendable {
    @Published var automations: [Automation] = []
    @Published var selection: UUID?

    @Published var isRecording = false
    @Published var liveSteps: [Step] = []
    @Published var pendingText = ""

    @Published var runningID: UUID?
    @Published var runningStep = 0
    @Published var status: String?
    /// What each step did on the most recent run, keyed by step ID. Not saved.
    @Published var runNotes: [UUID: String] = [:]

    @Published var hasAccessibility = Permissions.accessibility
    @Published var hasInputMonitoring = Permissions.inputMonitoring

    @Published var aiEnabled: Bool { didSet { UserDefaults.standard.set(aiEnabled, forKey: "aiEnabled") } }
    @Published var model: String { didSet { UserDefaults.standard.set(model, forKey: "model") } }
    @Published var apiKey: String { didSet { Keychain.set(apiKey, for: "anthropic") } }

    private let persistence = Persistence()
    private let weightStore = WeightStore()
    private var weights: [String: MatchWeights] = [:]
    private let recorder = Recorder()
    private let replayer = Replayer()
    private var permissionTimer: Timer?
    private var runStarted: Date?
    private var escapeMonitor: Any?

    static let defaultModel = "claude-sonnet-5-5"

    init() {
        let defaults = UserDefaults.standard
        aiEnabled = defaults.object(forKey: "aiEnabled") as? Bool ?? true
        model = defaults.string(forKey: "model") ?? Self.defaultModel
        apiKey = Keychain.get("anthropic") ?? ""
        automations = persistence.loadAll()
        weights = weightStore.load()
        selection = automations.first?.id

        recorder.onChange = { [weak self] in
            guard let self else { return }
            self.liveSteps = self.recorder.steps
            self.pendingText = self.recorder.pendingText
        }
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            self?.refreshPermissions()
        }
    }

    var permissionsReady: Bool { hasAccessibility && hasInputMonitoring }

    func refreshPermissions() {
        let a = Permissions.accessibility, i = Permissions.inputMonitoring
        if a != hasAccessibility { hasAccessibility = a }
        if i != hasInputMonitoring { hasInputMonitoring = i }
    }

    // MARK: Recording

    /// Returns false when permissions are missing, so the caller can show the window.
    @discardableResult
    func startRecording() -> Bool {
        refreshPermissions()
        guard permissionsReady, runningID == nil else {
            if !hasAccessibility { Permissions.requestAccessibility() }
            if !hasInputMonitoring { Permissions.requestInputMonitoring() }
            return false
        }
        guard recorder.start() else {
            status = "macOS blocked recording. Check Input Monitoring in System Settings."
            return false
        }
        status = nil
        isRecording = true
        return true
    }

    func stopRecording() {
        let steps = recorder.stop()
        isRecording = false
        guard !steps.isEmpty else { status = "Nothing was recorded."; return }
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d, h:mm a"
        let a = Automation(name: "Task from \(formatter.string(from: Date()))", steps: steps)
        automations.insert(a, at: 0)
        persistence.save(a)
        selection = a.id
        status = "Saved \(steps.count) steps."
    }

    func discardRecording() {
        recorder.stop()
        isRecording = false
        liveSteps = []
        status = nil
    }

    // MARK: Running

    func run(_ automation: Automation) {
        guard runningID == nil, !isRecording else { return }
        refreshPermissions()
        guard hasAccessibility else {
            Permissions.requestAccessibility()
            status = "Allow Accessibility for Deja Do, then run it again."
            return
        }
        runningID = automation.id
        runningStep = 0
        runStarted = Date()
        runNotes = [:]
        let stepIDs = automation.steps.map(\.id)
        status = "Running \(automation.name)…"
        startEscapeMonitor()

        let settings = Replayer.Settings(apiKey: apiKey, model: model.isEmpty ? Self.defaultModel : model,
                                         aiEnabled: aiEnabled, weights: weights)
        let id = automation.id
        let callbacks = Replayer.Callbacks(
            progress: { [weak self] i in DispatchQueue.main.async { self?.runningStep = i } },
            askText: { prompt, secret in
                await withCheckedContinuation { cont in
                    DispatchQueue.main.async { cont.resume(returning: Prompt.text(prompt, secret: secret)) }
                }
            },
            learned: { [weak self] index, locator, byAI in
                DispatchQueue.main.async { self?.applyRepair(id: id, stepIndex: index, locator: locator, byAI: byAI) }
            },
            note: { [weak self] index, text in
                DispatchQueue.main.async {
                    guard index < stepIDs.count else { return }
                    self?.runNotes[stepIDs[index]] = text
                }
            },
            tuned: { [weak self] bundleID, w in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.weights[bundleID] = w
                    self.weightStore.save(self.weights)
                }
            }
        )
        let replayer = self.replayer
        Task.detached {
            var failure: String?
            do {
                try await replayer.run(automation, settings: settings, callbacks: callbacks)
            } catch {
                failure = error.localizedDescription
            }
            DispatchQueue.main.async { [weak self] in self?.finishRun(id: id, failure: failure) }
        }
    }

    func stopRun() { replayer.cancel() }

    private func finishRun(id: UUID, failure: String?) {
        stopEscapeMonitor()
        runningID = nil
        if let failure {
            status = failure
            NSSound.beep()
        } else {
            status = "Done."
        }
        let duration = runStarted.map { Date().timeIntervalSince($0) }
        update(id) { a in
            a.runs += failure == nil ? 1 : 0
            a.lastRun = Date()
            a.lastSucceeded = failure == nil
            a.lastDuration = duration
        }
    }

    private func applyRepair(id: UUID, stepIndex: Int, locator: ElementLocator, byAI: Bool) {
        update(id) { a in
            guard stepIndex < a.steps.count, case .click(_, let b, let c, let m) = a.steps[stepIndex].kind else { return }
            a.steps[stepIndex].kind = .click(target: locator, button: b, count: c, modifiers: m)
            if byAI { a.repairs += 1 }
        }
    }

    /// Esc stops a run. Keys Deja Do posts itself are ignored, so a recorded Esc step doesn't stop it.
    private func startEscapeMonitor() {
        let ownPID = Int64(ProcessInfo.processInfo.processIdentifier)
        escapeMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return }
            if event.cgEvent?.getIntegerValueField(.eventSourceUnixProcessID) == ownPID { return }
            self?.replayer.cancel()
        }
    }

    private func stopEscapeMonitor() {
        if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor) }
        escapeMonitor = nil
    }

    // MARK: Editing

    func update(_ id: UUID, _ change: (inout Automation) -> Void) {
        guard let i = automations.firstIndex(where: { $0.id == id }) else { return }
        change(&automations[i])
        persistence.save(automations[i])
    }

    func binding(for id: UUID) -> Binding<Automation>? {
        guard let a = automations.first(where: { $0.id == id }) else { return nil }
        return Binding(
            get: { [weak self] in self?.automations.first(where: { $0.id == id }) ?? a },
            set: { [weak self] new in self?.update(id) { $0 = new } }
        )
    }

    func delete(_ id: UUID) {
        automations.removeAll { $0.id == id }
        persistence.delete(id)
        if selection == id { selection = automations.first?.id }
    }

    func duplicate(_ id: UUID) {
        guard let a = automations.first(where: { $0.id == id }) else { return }
        var copy = a
        copy.id = UUID()
        copy.name = a.name + " copy"
        copy.created = Date()
        copy.runs = 0
        copy.repairs = 0
        copy.lastRun = nil
        automations.insert(copy, at: 0)
        persistence.save(copy)
        selection = copy.id
    }
}
