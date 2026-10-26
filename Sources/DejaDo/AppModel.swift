import AppKit
import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers
@preconcurrency import DejaDoCore

/// App state shared by the menu bar and the main window. Only touched on the
/// main thread, which is why it can be marked as safe to hand across tasks.
final class AppModel: ObservableObject, @unchecked Sendable {
    /// One model for the whole app, so opening a .dejado file from Finder can reach it.
    static let shared = AppModel()

    /// A run waiting for the user to fill in its variables.
    struct PendingRun: Identifiable {
        let id = UUID()
        let automationID: UUID
        let names: [String]
    }

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
    @Published var pendingRun: PendingRun?
    /// Which spreadsheet row is running, counted from 0, when looping over a file.
    @Published var runningRow = 0
    @Published var rowCount = 1
    /// Last values typed into the variables form, per task, so the next run is prefilled.
    private(set) var lastValues: [UUID: [String: String]] = [:]

    @Published var hasAccessibility = Permissions.accessibility
    @Published var hasInputMonitoring = Permissions.inputMonitoring
    /// Optional. Lets Deja Do look at the screen for apps that don't describe their buttons.
    @Published var hasScreenRecording = ScreenVision.hasPermission
    @Published var isFinishingRecording = false

    @Published var aiEnabled: Bool { didSet { UserDefaults.standard.set(aiEnabled, forKey: "aiEnabled") } }
    /// Which AI service to ask. Switching loads that service's model and key.
    @Published var aiProvider: AIProvider {
        didSet {
            guard aiProvider != oldValue else { return }
            UserDefaults.standard.set(aiProvider.rawValue, forKey: "aiProvider")
            switchingProvider = true
            model = Self.savedModel(for: aiProvider)
            providerKey = aiProvider.keychainAccount.flatMap { Keychain.get($0) } ?? ""
            switchingProvider = false
            if aiProvider == .ollama { refreshOllamaModels() }
        }
    }
    /// The model for the current service. Each service remembers its own.
    @Published var model: String {
        didSet { UserDefaults.standard.set(model, forKey: "model.\(aiProvider.rawValue)") }
    }
    /// API key, or the access code for the Deja Do server. Kept in the keychain.
    @Published var providerKey: String {
        didSet {
            guard !switchingProvider, let account = aiProvider.keychainAccount else { return }
            Keychain.set(providerKey.trimmingCharacters(in: .whitespacesAndNewlines), for: account)
        }
    }
    @Published var serverURL: String { didSet { UserDefaults.standard.set(serverURL, forKey: "serverURL") } }
    @Published var ollamaURL: String { didSet { UserDefaults.standard.set(ollamaURL, forKey: "ollamaURL") } }
    /// Models installed in Ollama, read from the Mac.
    @Published var ollamaModels: [String] = []
    @Published var ollamaReachable = true
    private var switchingProvider = false
    /// Record and match on what the screen looks like, when Screen Recording is allowed.
    @Published var useVision: Bool { didSet { UserDefaults.standard.set(useVision, forKey: "useVision") } }
    /// Confirm each step changed the screen the way it did when recorded.
    @Published var checkSteps: Bool { didSet { UserDefaults.standard.set(checkSteps, forKey: "checkSteps") } }
    /// Ask before every step that sends, saves or deletes.
    @Published var askBeforeRisky: Bool { didSet { UserDefaults.standard.set(askBeforeRisky, forKey: "askBeforeRisky") } }
    /// Let other apps and agents run tasks through dejado:// links without asking each time.
    @Published var allowOtherApps: Bool { didSet { UserDefaults.standard.set(allowOtherApps, forKey: "allowOtherApps") } }
    /// Let tools on this Mac (n8n, scripts, Shortcuts) start tasks over a local web address.
    @Published var webhooksEnabled: Bool {
        didSet {
            UserDefaults.standard.set(webhooksEnabled, forKey: "webhooksEnabled")
            updateWebhooks()
        }
    }
    @Published var webhookToken: String = ""
    /// What the last run read off the screen. Shown, never saved.
    @Published var lastRead: [String: String] = [:]
    /// The task whose schedule is being edited.
    @Published var scheduleFor: UUID?
    private var scheduleTimer: Timer?
    @Published var webhookStatus: String = ""
    let webhooks = WebhookServer()

    var webhookURL: String { "http://127.0.0.1:\(webhooks.port == 0 ? WebhookServer.defaultPort : webhooks.port)" }

    /// A spreadsheet run that stopped part way, ready to carry on.
    struct Resume {
        let automationID: UUID
        let rows: [[String: String]]
        /// Row to start from, counted from 0.
        let from: Int
        /// Whether the row it stopped on may already have sent or saved something.
        let mayRepeat: Bool
    }
    @Published var resume: Resume?
    /// Where the last run stopped, so a popup in the way can be taught.
    @Published var lastStop: (automationID: UUID, step: Int)?
    @Published var isTeachingPopup = false
    @Published var isChecking = false
    /// Suggestions the person said "not now" to, per step.
    @Published var dismissedSuggestions: Set<UUID> = []
    /// The step as it was before an AI repair, so the repair can be undone. Kept until quit.
    @Published var beforeRepair: [UUID: ElementLocator] = [:]
    /// Run history sheet.
    @Published var historyFor: UUID?
    let history = RunHistory()
    /// Where finding a step wasn't straightforward, kept for tuning the matcher.
    let corpus = RepairCorpus()

    private let persistence = Persistence()
    private let weightStore = WeightStore()
    private var weights: [String: MatchWeights] = [:]
    private let recorder = Recorder()
    private let replayer = Replayer()
    private var permissionTimer: Timer?
    private var runStarted: Date?
    private var escapeMonitor: Any?

    /// The Deja Do server built into this copy of the app, from Info.plist.
    static let bundledServer = (Bundle.main.object(forInfoDictionaryKey: "DejaDoServerURL") as? String)?
        .trimmingCharacters(in: .whitespaces) ?? ""

    static func savedModel(for p: AIProvider) -> String {
        let saved = UserDefaults.standard.string(forKey: "model.\(p.rawValue)")?.trimmingCharacters(in: .whitespaces) ?? ""
        return saved.isEmpty ? AICatalog.defaultModel(for: p) : saved
    }

    var aiConfig: AIConfig {
        AIConfig(provider: aiProvider, model: model, key: providerKey,
                 baseURL: aiProvider == .dejaDo ? serverURL : (aiProvider == .ollama ? ollamaURL : nil))
    }

    init() {
        let defaults = UserDefaults.standard
        aiEnabled = defaults.object(forKey: "aiEnabled") as? Bool ?? true
        serverURL = defaults.string(forKey: "serverURL") ?? Self.bundledServer
        ollamaURL = defaults.string(forKey: "ollamaURL") ?? AIRequest.ollamaDefault

        // Versions before provider choice had one model setting and an Anthropic key.
        if defaults.string(forKey: "aiProvider") == nil, let old = defaults.string(forKey: "model"), !old.isEmpty,
           defaults.string(forKey: "model.anthropic") == nil {
            defaults.set(old, forKey: "model.anthropic")
        }
        let hasAnthropicKey = !(Keychain.get("anthropic") ?? "").isEmpty
        let provider = defaults.string(forKey: "aiProvider").flatMap(AIProvider.init(rawValue:))
            ?? (hasAnthropicKey || Self.bundledServer.isEmpty ? .anthropic : .dejaDo)
        aiProvider = provider
        model = Self.savedModel(for: provider)
        providerKey = provider.keychainAccount.flatMap { Keychain.get($0) } ?? ""
        useVision = defaults.object(forKey: "useVision") as? Bool ?? true
        checkSteps = defaults.object(forKey: "checkSteps") as? Bool ?? true
        askBeforeRisky = defaults.object(forKey: "askBeforeRisky") as? Bool ?? false
        allowOtherApps = defaults.object(forKey: "allowOtherApps") as? Bool ?? false
        webhooksEnabled = defaults.object(forKey: "webhooksEnabled") as? Bool ?? false
        let scan = persistence.scan()
        automations = scan.automations
        if !scan.problems.isEmpty { status = scan.problems.joined(separator: " ") }
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
        updateWebhooks()
        scheduleTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            self?.checkSchedules()
        }
    }

    // MARK: Schedules

    var isBusy: Bool { runningID != nil || isRecording || isChecking || isTeachingPopup || pendingRun != nil }

    /// Runs whatever task is due. Called every half minute, and after the Mac wakes.
    func checkSchedules(now: Date = Date()) {
        for a in automations {
            guard let sched = a.schedule, sched.on else { continue }
            switch sched.due(at: now, calendar: .current, since: a.created) {
            case .none:
                continue
            case .missed(let slots):
                update(a.id) { $0.schedule?.lastSlot = slots.last }
                let when = slots.map { Self.timeFormatter.string(from: $0) }.joined(separator: ", ")
                history.add(RunRecord(started: slots.last ?? now, duration: 0,
                                      outcome: "Missed the scheduled run at \(when): the Mac was asleep or Deja Do wasn't open.",
                                      succeeded: false, steps: [])
                            .with(trigger: "schedule"), to: a.id)
            case .run(let slot):
                // Busy or locked: try again next check, while still within the hour.
                guard !isBusy, !Self.screenLocked else { continue }
                update(a.id) { $0.schedule?.lastSlot = slot }
                if let problem = Schedule.problem(for: a, values: sched.values) {
                    history.add(RunRecord(started: now, duration: 0, outcome: "Didn't run on schedule. \(problem)",
                                          succeeded: false, steps: []).with(trigger: "schedule"), to: a.id)
                    status = "“\(a.name)” didn't run on schedule. \(problem)"
                    continue
                }
                status = "Running “\(a.name)” on schedule…"
                start(a, rows: [sched.values], trigger: "schedule")
                return   // one at a time
            }
        }
    }

    func setSchedule(_ id: UUID, _ schedule: Schedule?) {
        update(id) { a in
            var s = schedule
            // A new or changed schedule starts counting from now, so it doesn't fire for times already gone.
            if s != nil, s?.lastSlot == nil || a.schedule?.repeats != s?.repeats || a.schedule?.hour != s?.hour || a.schedule?.minute != s?.minute {
                s?.lastSlot = Date()
            }
            a.schedule = s
        }
        if schedule?.on == true, !openAtLogin { status = "Turn on “Open Deja Do when you log in” in Settings so scheduled tasks run after a restart." }
    }

    func nextRun(_ a: Automation) -> Date? { a.schedule?.next(after: Date(), calendar: .current) }

    static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .short
        return f
    }()

    /// Nothing can be clicked or typed while the screen is locked.
    static var screenLocked: Bool {
        guard let d = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return (d["CGSSessionScreenIsLocked"] as? Bool) == true || (d["CGSSessionScreenIsLocked"] as? Int) == 1
    }

    /// Opening at login, so schedules survive a restart.
    var openAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                status = "Couldn't change opening at login: \(error.localizedDescription)"
            }
            objectWillChange.send()
        }
    }

    // MARK: Webhooks

    /// Starts or stops the local web address to match the setting.
    func updateWebhooks() {
        guard webhooksEnabled else {
            webhooks.stop()
            webhookStatus = ""
            return
        }
        if webhookToken.isEmpty {
            webhookToken = Keychain.get("webhookToken") ?? ""
            if webhookToken.isEmpty {
                webhookToken = WebhookAPI.newToken()
                Keychain.set(webhookToken, for: "webhookToken")
            }
        }
        let hooks = WebhookServer.Hooks(
            tasks: { [weak self] in
                (self?.automations ?? []).map { WebhookAPI.TaskInfo(id: $0.id, name: $0.name, variables: $0.variableNames) }
            },
            busy: { [weak self] in
                guard let self else { return true }
                return self.runningID != nil || self.isRecording || self.isChecking || self.isTeachingPopup
            },
            start: { [weak self] request, _, done in
                guard let self, let a = self.automations.first(where: { $0.id == request.task.id }) else { return false }
                self.status = "Another tool started “\(a.name)”."
                return self.start(a, rows: [request.values], trigger: "another tool", onFinish: done)
            })
        if webhooks.start(port: WebhookServer.defaultPort, token: webhookToken, hooks: hooks) {
            webhookStatus = "Listening at \(webhookURL), on this Mac only."
        } else {
            webhookStatus = "Couldn't listen on port \(WebhookServer.defaultPort): \(webhooks.lastError ?? "it may be in use")."
        }
    }

    /// A new token; tools using the old one stop working.
    func newWebhookToken() {
        webhookToken = WebhookAPI.newToken()
        Keychain.set(webhookToken, for: "webhookToken")
        updateWebhooks()
    }

    func copyWebhookDetails() {
        let text = """
        curl -X POST \(webhookURL)/run \\
          -H "Authorization: Bearer \(webhookToken)" \\
          -H "Content-Type: application/json" \\
          -d '{"task": "TASK NAME", "values": {}, "wait": true}'
        """
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        status = "Copied an example request with the token."
    }

    var permissionsReady: Bool { hasAccessibility && hasInputMonitoring }

    /// Asks Ollama which models are installed.
    func refreshOllamaModels() {
        let base = ollamaURL
        Task { [weak self] in
            var found: [String] = []
            var reachable = false
            if let url = URL(string: (base.hasSuffix("/") ? String(base.dropLast()) : base) + "/api/tags") {
                var request = URLRequest(url: url)
                request.timeoutInterval = 3
                if let reply = try? await URLSession.shared.data(for: request),
                   (reply.1 as? HTTPURLResponse)?.statusCode == 200 {
                    reachable = true
                    found = AIRequest.ollamaModels(from: reply.0)
                }
            }
            let models = found, ok = reachable
            guard let me = self else { return }
            await MainActor.run {
                me.ollamaModels = models
                me.ollamaReachable = ok
                if me.aiProvider == .ollama, me.model.isEmpty, let first = models.first { me.model = first }
            }
        }
    }

    func refreshPermissions() {
        let a = Permissions.accessibility, i = Permissions.inputMonitoring, s = ScreenVision.hasPermission
        if a != hasAccessibility { hasAccessibility = a }
        if i != hasInputMonitoring { hasInputMonitoring = i }
        if s != hasScreenRecording { hasScreenRecording = s }
    }

    // MARK: Recording

    /// Returns false when permissions are missing, so the caller can show the window.
    @discardableResult
    func startRecording() -> Bool {
        refreshPermissions()
        guard permissionsReady, runningID == nil, !isFinishingRecording else {
            if !hasAccessibility { Permissions.requestAccessibility() }
            if !hasInputMonitoring { Permissions.requestInputMonitoring() }
            return false
        }
        recorder.visionEnabled = visionActive
        recorder.checkSteps = checkSteps
        guard recorder.start() else {
            status = "macOS blocked recording. Check Input Monitoring in System Settings."
            return false
        }
        status = nil
        isRecording = true
        return true
    }

    /// Vision is on and macOS allows it.
    var visionActive: Bool { useVision && hasScreenRecording }

    func stopRecording() {
        guard !isFinishingRecording else { return }
        isRecording = false
        isFinishingRecording = true
        status = "Saving…"
        recorder.finish { [weak self] steps in
            self?.isFinishingRecording = false
            self?.saveRecording(steps)
        }
    }

    private func saveRecording(_ steps: [Step]) {
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

    /// Runs a task. If it uses {{variables}}, asks for them first and returns
    /// true so the caller can bring the window forward.
    @discardableResult
    func run(_ automation: Automation) -> Bool {
        guard runningID == nil, !isRecording else { return false }
        let names = automation.variableNames
        if !names.isEmpty {
            pendingRun = PendingRun(automationID: automation.id, names: names)
            return true
        }
        start(automation, rows: [[:]])
        return false
    }

    /// Called by the variables form.
    func runPending(values: [String: String]) {
        guard let p = pendingRun, let a = automations.first(where: { $0.id == p.automationID }) else { return }
        pendingRun = nil
        lastValues[a.id] = values
        start(a, rows: [values])
    }

    /// Asks for a CSV and runs the task once per row, filling variables from its columns.
    func runForEachRow(_ automation: Automation) {
        guard runningID == nil, !isRecording else { return }
        let panel = NSOpenPanel()
        panel.title = "Run “\(automation.name)” for each row"
        panel.message = "Pick a CSV saved from Excel, Numbers or Google Sheets. Column names fill the matching {{variables}}."
        panel.allowedContentTypes = [.commaSeparatedText, .tabSeparatedText, .plainText]
        panel.allowsMultipleSelection = false
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let text = (try? String(contentsOf: url, encoding: .utf8)) ?? (try? String(contentsOf: url, encoding: .isoLatin1)) else {
            status = "Couldn't read \(url.lastPathComponent)."
            return
        }
        let (headers, rows) = CSV.records(text)
        guard !rows.isEmpty else { status = "\(url.lastPathComponent) has no rows under its header."; return }
        let missing = Variables.missing(automation.variableNames, in: headers)
        guard missing.isEmpty else {
            status = "\(url.lastPathComponent) has no column for " + missing.map { "{{\($0)}}" }.joined(separator: ", ") + "."
            return
        }
        start(automation, rows: rows)
    }

    @discardableResult
    private func start(_ automation: Automation, rows: [[String: String]], from startRow: Int = 0,
                       trigger: String? = nil,
                       onFinish: ((RunRecord, RunOutcome, [String: String]) -> Void)? = nil) -> Bool {
        guard runningID == nil, !isRecording else { return false }
        refreshPermissions()
        guard hasAccessibility else {
            Permissions.requestAccessibility()
            status = "Allow Accessibility for Deja Do, then run it again."
            return false
        }
        runningRow = 0
        rowCount = max(1, rows.count)
        runningID = automation.id
        runningStep = 0
        runStarted = Date()
        runNotes = [:]
        let stepIDs = automation.steps.map(\.id)
        status = "Running \(automation.name)…"
        startEscapeMonitor()

        refreshPermissions()
        resume = nil
        lastStop = nil
        let settings = Replayer.Settings(ai: aiConfig, aiEnabled: aiEnabled, weights: weights,
                                         visionEnabled: visionActive, checkSteps: checkSteps,
                                         askBeforeRisky: askBeforeRisky)
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
            },
            confirm: { question, detail in
                await withCheckedContinuation { cont in
                    DispatchQueue.main.async { cont.resume(returning: Prompt.confirm(question, detail: detail)) }
                }
            },
            record: { [corpus] r in corpus.add(r) }
        )
        let replayer = self.replayer
        let total = rows.count
        let history = self.history
        let firstRow = startRow
        Task.detached {
            var failure: String?
            var lastRecord: RunRecord?
            var lastOutcome: RunOutcome = .finished
            var lastRead: [String: String] = [:]
            for r in firstRow..<rows.count {
                let values = rows[r]
                DispatchQueue.main.async { [weak self] in
                    self?.runningRow = r
                    if total > 1 { self?.status = "Row \(r + 1) of \(total)…" }
                }
                let started = Date()
                var stop: ReplayStop?
                do {
                    try await replayer.run(automation, settings: settings, callbacks: callbacks, values: values)
                } catch let s as ReplayStop {
                    stop = s
                } catch {
                    stop = ReplayStop(message: error.localizedDescription, step: 0, outcome: .stoppedBeforeChanges(atStep: 0))
                }
                // Keep a record of the run: step summaries and notes, never typed text.
                let notes = replayer.notes
                let record = RunRecord(
                    started: started, duration: Date().timeIntervalSince(started),
                    outcome: stop.map { "\($0.message) \($0.outcome.advice)" } ?? "Done.",
                    succeeded: stop == nil, row: total > 1 ? r + 1 : nil, rows: total > 1 ? total : nil,
                    steps: automation.steps.enumerated().map { i, step in
                        RunRecord.StepRun(index: i, summary: step.safeSummary,
                                          note: notes[i]?.joined(separator: " · "),
                                          ran: stop.map { i <= $0.step } ?? true)
                    })
                var kept = record
                kept.trigger = trigger
                history.add(kept, to: id)
                lastRecord = kept
                lastOutcome = stop?.outcome ?? .finished
                lastRead = replayer.readValues

                if let stop {
                    let where_ = total > 1 ? "Stopped at row \(r + 1) of \(total): " : ""
                    let cancelled: Bool
                    if case .cancelled = stop.outcome { cancelled = true } else { cancelled = false }
                    failure = cancelled ? "Stopped. \(stop.outcome.advice)" : "\(where_)\(stop.message) \(stop.outcome.advice)"
                    let mayRepeat = stop.outcome.mayRepeatChanges
                    DispatchQueue.main.async { [weak self] in
                        self?.lastStop = (id, stop.step)
                        if total > 1 {
                            // Carry on from the row it stopped on, or the next one if that row may have gone through.
                            let next = mayRepeat ? r + 1 : r
                            if next < total { self?.resume = Resume(automationID: id, rows: rows, from: next, mayRepeat: mayRepeat) }
                        }
                    }
                    break
                }
            }
            let done = failure
            let finalRecord = lastRecord
            let finalOutcome = lastOutcome
            let finalRead = lastRead
            DispatchQueue.main.async { [weak self] in
                self?.finishRun(id: id, failure: done, rows: total, read: finalRead)
                if let onFinish, let finalRecord { onFinish(finalRecord, finalOutcome, finalRead) }
            }
        }
        return true
    }

    /// Carries on a spreadsheet run that stopped.
    func continueRows() {
        guard let r = resume, let a = automations.first(where: { $0.id == r.automationID }) else { return }
        resume = nil
        start(a, rows: r.rows, from: r.from)
    }

    func stopRun() { replayer.cancel() }

    private func finishRun(id: UUID, failure: String?, rows: Int = 1, read: [String: String] = [:]) {
        stopEscapeMonitor()
        runningID = nil
        lastRead = read
        if let failure {
            status = failure
            NSSound.beep()
        } else {
            var done = rows > 1 ? "Done. Ran all \(rows) rows." : "Done."
            if !read.isEmpty, rows == 1 {
                let pairs = read.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value.prefix(60))" }
                done += " Read " + pairs.joined(separator: ", ") + "."
            }
            status = done
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
            guard stepIndex < a.steps.count, case .click(let old, let b, let c, let m) = a.steps[stepIndex].kind else { return }
            if byAI { beforeRepair[a.steps[stepIndex].id] = old }
            a.steps[stepIndex].kind = .click(target: locator, button: b, count: c, modifiers: m)
            if byAI { a.repairs += 1 }
        }
    }

    /// Puts a step back the way it was before AI changed it.
    func undoRepair(automation id: UUID, step stepID: UUID) {
        guard let old = beforeRepair[stepID] else { return }
        update(id) { a in
            guard let i = a.steps.firstIndex(where: { $0.id == stepID }),
                  case .click(_, let b, let c, let m) = a.steps[i].kind else { return }
            a.steps[i].kind = .click(target: old, button: b, count: c, modifiers: m)
        }
        beforeRepair[stepID] = nil
        status = "Put the step back the way it was recorded."
    }

    // MARK: Check

    /// Looks for every click step on the screen as it is now, without clicking
    /// or typing anything. Apps have to be open for their steps to be checked.
    /// (MacTape's Dry Run, adapted.)
    func check(_ automation: Automation) {
        guard runningID == nil, !isRecording, !isChecking else { return }
        guard Permissions.accessibility else { Permissions.requestAccessibility(); return }
        isChecking = true
        runNotes = [:]
        status = "Checking \(automation.name)…"
        let vision = visionActive
        let engineWeights = weights
        Task.detached { [weak self] in
            var found = 0, total = 0
            var notes: [UUID: String] = [:]
            for step in automation.steps where step.isEnabled {
                guard case .click(let t, _, _, _) = step.kind else { continue }
                total += 1
                guard ElementFinder.runningApp(t.bundleID) != nil else {
                    notes[step.id] = "Check: \(t.appName) isn't open, so this wasn't checked"
                    continue
                }
                let engine = MatchEngine(weights: engineWeights[t.bundleID] ?? MatchWeights())
                if t.prefersVisual || t.role == AX.positionRole {
                    if vision, let visual = t.visual, let root = ElementFinder.root(for: t), let wf = root.windowFrame,
                       let read = await ScreenVision.read(windowFrame: wf, ocr: true),
                       case .confident(let best) = VisualMatcher().match(visual, window: read.image, lines: read.lines, windowSize: wf.size).decision {
                        found += 1
                        notes[step.id] = "Check: found on screen · \(Int((best.score * 100).rounded()))%"
                    } else {
                        notes[step.id] = "Check: not visible right now (it may appear after earlier steps run)"
                    }
                    continue
                }
                guard let o = ElementFinder.find(t, engine: engine) else {
                    notes[step.id] = "Check: couldn't read the \(t.appName) window"
                    continue
                }
                switch o.report.decision {
                case .confident(let best):
                    found += 1
                    notes[step.id] = "Check: found \(Replayer.describe(o.snapshot(for: best))) · \(Int((best.score * 100).rounded()))%"
                case .ambiguous(let list):
                    let names = list.prefix(2).map { Replayer.describe(o.snapshot(for: $0)) }.joined(separator: " or ")
                    notes[step.id] = "Check: not sure, could be \(names)"
                case .notFound:
                    notes[step.id] = "Check: not on screen right now (it may appear after earlier steps run)"
                }
            }
            let summary = total == 0 ? "Nothing to check: this task has no clicks."
                : "Check: found \(found) of \(total) clicks on screen now. Nothing was clicked or typed."
            let finalNotes = notes
            DispatchQueue.main.async {
                guard let self else { return }
                self.runNotes = finalNotes
                self.status = summary
                self.isChecking = false
            }
        }
    }

    // MARK: Popups

    /// Learns how to close a dialog that got in the way: remembers its text,
    /// then watches for the one click or key press that closes it.
    func teachPopup() {
        guard let stop = lastStop, !isRecording, runningID == nil,
              let a = automations.first(where: { $0.id == stop.automationID }) else { return }
        guard Permissions.inputMonitoring else { Permissions.requestInputMonitoring(); return }
        isTeachingPopup = true
        status = "Close the thing in the way, the way you normally would. Deja Do is watching for one click or key press."
        let normal: ScreenState? = nil
        Task.detached { [weak self] in
            let now = await ScreenStateReader.read(pid: nil, ocr: false, pixels: false)
            let signature = PopupRule.signature(now: now, normal: normal)
            await MainActor.run {
                guard let self else { return }
                guard !signature.isEmpty else {
                    self.isTeachingPopup = false
                    self.status = "Couldn't see anything to recognise it by. Make sure the popup is showing, then try again."
                    return
                }
                let watcher = Recorder()
                watcher.checkSteps = false
                watcher.onChange = { [weak self, weak watcher] in
                    guard let self, let watcher,
                          let step = watcher.steps.first(where: {
                              if case .click = $0.kind { return true }
                              if case .key = $0.kind { return true }
                              return false
                          }) else { return }
                    watcher.stop()
                    self.saveTeachWatcher = nil
                    let dismiss: PopupDismiss
                    switch step.kind {
                    case .click(let t, _, _, _): dismiss = .click(target: t)
                    case .key(let c, let m, let l): dismiss = .key(code: c, modifiers: m, label: l)
                    default: return
                    }
                    let rule = PopupRule(name: signature[0], bundleID: now.bundleID, detect: signature, dismiss: dismiss)
                    self.update(a.id) { $0.popups = ($0.popups ?? []) + [rule] }
                    self.isTeachingPopup = false
                    self.status = "Got it. When “\(rule.name)” shows up, Deja Do will \(dismiss.summary) and carry on."
                }
                self.saveTeachWatcher = watcher
                if !watcher.start() {
                    self.isTeachingPopup = false
                    self.status = "macOS blocked watching for the click. Check Input Monitoring in System Settings."
                }
            }
        }
    }
    private var saveTeachWatcher: Recorder?

    func removePopup(_ rule: PopupRule, from id: UUID) {
        update(id) { a in a.popups?.removeAll { $0.id == rule.id } }
    }

    // MARK: Suggestions

    func applyVariable(_ s: VariableSuggestion, in id: UUID) {
        update(id) { a in VariableSuggester.apply(s, to: &a) }
        var values = lastValues[id] ?? [:]
        values[s.name] = s.text
        lastValues[id] = values
    }

    func dismissSuggestion(_ stepID: UUID) { dismissedSuggestions.insert(stepID) }

    func removeStep(_ stepID: UUID, from id: UUID) {
        update(id) { a in a.steps.removeAll { $0.id == stepID } }
    }

    // MARK: Agent skills

    /// Writes the task as a SKILL.md for Claude Code and Codex, in each one's
    /// skills folder that exists on this Mac, so an agent can run it through Deja Do.
    func installSkill(_ id: UUID) {
        guard let a = automations.first(where: { $0.id == id }) else { return }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let slug = SkillExport.slug(a.name)
        let md = SkillExport.markdown(a)
        var written: [String] = []
        for (app, folder) in [("Claude Code", ".claude"), ("Codex", ".codex")] {
            let base = home.appendingPathComponent(folder, isDirectory: true)
            let exists = FileManager.default.fileExists(atPath: base.path)
            guard exists || folder == ".claude" else { continue }
            let dir = base.appendingPathComponent("skills/\(slug)", isDirectory: true)
            do {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                try md.write(to: dir.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
                written.append(app)
            } catch {
                status = "Couldn't write the skill for \(app): \(error.localizedDescription)"
                return
            }
        }
        status = "Added “\(a.name)” as a skill for \(written.joined(separator: " and ")). Agents run it through Deja Do\(allowOtherApps ? "" : ", and you'll be asked each time")."
    }

    /// Saves the SKILL.md wherever the person picks.
    func exportSkill(_ id: UUID) {
        guard let a = automations.first(where: { $0.id == id }) else { return }
        let panel = NSSavePanel()
        panel.title = "Save “\(a.name)” as an agent skill"
        panel.nameFieldStringValue = "SKILL.md"
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try SkillExport.markdown(a).write(to: url, atomically: true, encoding: .utf8)
            status = "Saved \(url.lastPathComponent)."
        } catch {
            status = "Couldn't save: \(error.localizedDescription)"
        }
    }

    /// Saves the repair records somewhere the person chooses, as JSON lines.
    func exportRepairs() {
        let panel = NSSavePanel()
        panel.title = "Save repair records"
        panel.nameFieldStringValue = "dejado-repairs.jsonl"
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
            try FileManager.default.copyItem(at: corpus.url, to: url)
            status = "Saved \(url.lastPathComponent)."
        } catch {
            status = "Nothing to save yet."
        }
    }

    /// Runs a task asked for by a dejado://run?task=…&name=value link.
    /// Asks first unless other apps are allowed to run tasks.
    func handle(url: URL) {
        guard url.scheme == "dejado", url.host == "run",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              let key = items.first(where: { $0.name == "task" })?.value else { return }
        guard let a = automations.first(where: { $0.id.uuidString.lowercased() == key.lowercased() })
                ?? automations.first(where: { $0.name.lowercased() == key.lowercased() }) else {
            status = "Another app asked to run “\(key)”, but there's no task by that name."
            return
        }
        var values: [String: String] = [:]
        for item in items where item.name != "task" { values[item.name] = item.value ?? "" }
        if !allowOtherApps {
            NSApp.activate(ignoringOtherApps: true)
            guard Prompt.confirm("Run “\(a.name)”?", detail: "Another app or an AI agent asked Deja Do to run this task. Only say yes if you expected it.") else {
                status = "Didn't run “\(a.name)”."
                return
            }
        }
        let missing = Variables.missing(a.variableNames, in: Array(values.keys))
        if missing.isEmpty {
            start(a, rows: [values])
        } else {
            lastValues[a.id] = (lastValues[a.id] ?? [:]).merging(values) { $1 }
            pendingRun = PendingRun(automationID: a.id, names: a.variableNames)
            NSApp.activate(ignoringOtherApps: true)
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

    // MARK: Sharing

    static let taskType = UTType(filenameExtension: TaskFile.fileExtension, conformingTo: .json) ?? .json

    /// Saves a task to a .dejado file for another Mac or person.
    func export(_ id: UUID) {
        guard let a = automations.first(where: { $0.id == id }) else { return }
        let panel = NSSavePanel()
        panel.title = "Export “\(a.name)”"
        panel.message = "Run history and anything typed into password or ask each run steps are left out."
        panel.nameFieldStringValue = Self.fileName(a.name) + "." + TaskFile.fileExtension
        panel.allowedContentTypes = [Self.taskType]
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try TaskFile.encode(a).write(to: url, options: .atomic)
            status = "Exported to \(url.lastPathComponent)."
        } catch {
            status = "Couldn't export: \(error.localizedDescription)"
        }
    }

    func importTasks() {
        let panel = NSOpenPanel()
        panel.title = "Import tasks"
        panel.allowedContentTypes = [Self.taskType, .json]
        panel.allowsMultipleSelection = true
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK else { return }
        importFiles(panel.urls)
    }

    /// Adds tasks from .dejado files. Also used when a file is opened from Finder.
    func importFiles(_ urls: [URL]) {
        var added: [Automation] = []
        var problems: [String] = []
        for url in urls {
            do {
                let a = try TaskFile.decode(Data(contentsOf: url))
                added.append(a)
            } catch {
                problems.append("\(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
        for a in added {
            automations.insert(a, at: 0)
            persistence.save(a)
        }
        if let first = added.first { selection = first.id }
        if !problems.isEmpty {
            status = problems.joined(separator: " ")
        } else if added.count == 1 {
            status = "Imported “\(added[0].name)”. Check its steps before you run it."
        } else if added.count > 1 {
            status = "Imported \(added.count) tasks. Check their steps before you run them."
        }
    }

    private static func fileName(_ name: String) -> String {
        let bad = CharacterSet(charactersIn: "/\\:?%*|\"<>")
        let cleaned = name.components(separatedBy: bad).joined(separator: " ").trimmingCharacters(in: .whitespaces)
        return cleaned.isEmpty ? "Task" : cleaned
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
        history.delete(id)
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
