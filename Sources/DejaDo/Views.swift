import SwiftUI
import AppKit
@preconcurrency import DejaDoCore

// Built from type, whitespace and hairlines. Cobalt marks what is active or
// primary; state colours (see Brand) only ever mean a state, and always come
// with a word.

extension Font {
    /// SF Pro, the Mac's own face, so Deja Do reads as part of macOS.
    static func ui(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight)
    }

    /// SF Mono, for shortcuts and step details only.
    static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
}

enum Metrics {
    static let sidebarWidth: CGFloat = 252
    static let gutter: CGFloat = 28
    static let headerHeight: CGFloat = 52
    static let statusHeight: CGFloat = 30
}

/// The native translucent sidebar material.
struct VisualEffect: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .sidebar

    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = material
        v.blendingMode = .behindWindow
        v.state = .followsWindowActiveState
        return v
    }

    func updateNSView(_ v: NSVisualEffectView, context: Context) { v.material = material }
}

// MARK: - Buttons

/// The main call to action: solid accent, soft corners, a small press.
struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    var compact = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.ui(compact ? 12 : 13, .semibold))
            .foregroundStyle(Brand.onCobalt)
            .padding(.horizontal, compact ? 12 : 16)
            .padding(.vertical, compact ? 5 : 7)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(configuration.isPressed ? Brand.deepBlue : Brand.cobalt)
            )
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .opacity(isEnabled ? 1 : 0.45)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
            .contentShape(Rectangle())
    }
}

/// Secondary action: a hairline outline, same shape as the primary.
struct QuietButtonStyle: ButtonStyle {
    var compact = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.ui(compact ? 12 : 13, .medium))
            .foregroundStyle(.primary)
            .padding(.horizontal, compact ? 12 : 16)
            .padding(.vertical, compact ? 5 : 7)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(Color.primary.opacity(configuration.isPressed ? 0.35 : 0.16), lineWidth: 1)
            )
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
            .contentShape(Rectangle())
    }
}

/// A keyboard shortcut shown as quiet text, like "Run ⌘↩".
struct ShortcutHint: View {
    let label: String
    let keys: String

    var body: some View {
        HStack(spacing: 5) {
            Text(label).foregroundStyle(.secondary)
            Text(keys).foregroundStyle(.tertiary)
        }
        .font(.ui(11))
    }
}

// MARK: - Window

struct MainView: View {
    @EnvironmentObject var model: AppModel
    @State private var showSettings = false

    var body: some View {
        HStack(spacing: 0) {
            Sidebar(showSettings: $showSettings)
                .frame(width: Metrics.sidebarWidth)
                .background(Brand.sidebar)
            Divider()
            VStack(spacing: 0) {
                Group {
                    if !model.permissionsReady {
                        PermissionsView()
                    } else if model.isRecording {
                        RecordingView()
                    } else if let id = model.selection, let binding = model.binding(for: id) {
                        AutomationView(automation: binding).id(id)
                    } else {
                        EmptyStateView()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                if showsStatus {
                    Divider()
                    StatusBar()
                }
            }
            .background(Brand.canvas)
        }
        .fontDesign(.default)
        .tint(Brand.cobalt)
        .ignoresSafeArea(.container, edges: .top)
        .sheet(isPresented: $showSettings) {
            SettingsView().environmentObject(model)
        }
        .sheet(item: $model.pendingRun) { pending in
            VariablesSheet(pending: pending).environmentObject(model)
        }
        .sheet(isPresented: Binding(get: { model.historyFor != nil }, set: { if !$0 { model.historyFor = nil } })) {
            if let id = model.historyFor { HistoryView(automationID: id).environmentObject(model) }
        }
        .sheet(isPresented: Binding(get: { model.scheduleFor != nil }, set: { if !$0 { model.scheduleFor = nil } })) {
            if let id = model.scheduleFor, let a = model.automations.first(where: { $0.id == id }) {
                ScheduleView(automation: a).environmentObject(model)
            }
        }
    }

    /// The status bar only appears when there is something to say.
    private var showsStatus: Bool {
        model.isRecording || model.runningID != nil || model.status != nil || !model.permissionsReady
    }
}

// MARK: - Sidebar

struct Sidebar: View {
    @EnvironmentObject var model: AppModel
    @Binding var showSettings: Bool
    @State private var query = ""

    private var filtered: [Automation] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return model.automations }
        return model.automations.filter { $0.name.lowercased().contains(q) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Room for the window controls, with the name on the other side.
            HStack(spacing: 6) {
                Spacer()
                BrandMark().frame(height: 11)
                Text("Deja Do").font(.ui(12, .semibold)).foregroundStyle(Brand.ink)
            }
            .padding(.horizontal, 16)
            .frame(height: 40)

            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.tertiary)
                TextField("Search tasks", text: $query)
                    .textFieldStyle(.plain)
                    .font(.ui(13))
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 10)

            Divider().padding(.horizontal, 16)

            HStack {
                Text("Tasks")
                    .font(.ui(11, .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(model.automations.count)")
                    .font(.ui(11).monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 6)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(filtered) { a in
                        SidebarRow(automation: a)
                    }
                    if filtered.isEmpty {
                        Text(model.automations.isEmpty ? "Recorded tasks show up here." : "No tasks match.")
                            .font(.ui(12))
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 6)
                    }
                }
                .padding(.horizontal, 8)
            }

            Divider()

            HStack(spacing: 0) {
                Button {
                    if model.isRecording { model.stopRecording() } else { model.startRecording() }
                } label: {
                    HStack(spacing: 8) {
                        Circle().fill(Brand.red).frame(width: 7, height: 7)
                        Text(model.isRecording ? "Stop and save" : "New recording")
                            .font(.ui(13, .medium))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(model.runningID != nil)
                .keyboardShortcut("r", modifiers: .command)

                Spacer()

                Button {
                    model.importTasks()
                } label: {
                    Image(systemName: "square.and.arrow.down")
                        .font(.system(size: 13))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Import a task")
                .padding(.trailing, 14)

                Button {
                    showSettings = true
                } label: {
                    Image(systemName: "gearshape")
                        .font(.system(size: 13))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Settings")
            }
            .padding(.horizontal, 16)
            .frame(height: 44)
        }
    }
}

struct SidebarRow: View {
    @EnvironmentObject var model: AppModel
    let automation: Automation
    @State private var hovering = false

    private var selected: Bool { model.selection == automation.id && !model.isRecording }
    private var running: Bool { model.runningID == automation.id }

    var body: some View {
        Button {
            model.selection = automation.id
        } label: {
            HStack(spacing: 10) {
                RunDot(automation: automation, running: running)
                Text(automation.name)
                    .font(.ui(13, selected ? .semibold : .regular))
                    .foregroundStyle(selected ? .primary : .secondary)
                    .lineLimit(1)
                Spacer(minLength: 6)
                Text(running ? "running" : Self.ago(automation.lastRun))
                    .font(.ui(11).monospacedDigit())
                    .foregroundStyle(running ? AnyShapeStyle(Brand.cobalt) : AnyShapeStyle(.tertiary))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(selected ? AnyShapeStyle(Brand.selected) : AnyShapeStyle(Color.primary.opacity(hovering ? 0.04 : 0)))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Run") { model.run(automation) }
            Button("Run for each row of a spreadsheet…") { model.runForEachRow(automation) }
            Divider()
            Button("Duplicate") { model.duplicate(automation.id) }
            Button("Export…") { model.export(automation.id) }
            Divider()
            Button("Delete", role: .destructive) { model.delete(automation.id) }
        }
    }

    /// "now", "5m", "3h", "2d", "Oct 2".
    static func ago(_ date: Date?) -> String {
        guard let date else { return "" }
        let s = Date().timeIntervalSince(date)
        if s < 60 { return "now" }
        if s < 3600 { return "\(Int(s / 60))m" }
        if s < 86_400 { return "\(Int(s / 3600))h" }
        if s < 7 * 86_400 { return "\(Int(s / 86_400))d" }
        return date.formatted(.dateTime.month(.abbreviated).day())
    }
}

/// Last run at a glance: grey never run, green passed, red failed, accent running.
struct RunDot: View {
    let automation: Automation
    var running = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 6, height: 6)
            .overlay(Circle().strokeBorder(Color.primary.opacity(automation.lastSucceeded == nil && !running ? 0.3 : 0), lineWidth: 1))
    }

    private var color: Color {
        if running { return Brand.cobalt }
        switch automation.lastSucceeded {
        case .some(true): return Brand.forest
        case .some(false): return Brand.red
        case .none: return .clear
        }
    }
}

// MARK: - Header and status bar

/// The bar across the top of the content area: title left, actions right.
struct HeaderBar<Title: View, Actions: View>: View {
    @ViewBuilder var title: () -> Title
    @ViewBuilder var actions: () -> Actions

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                title()
                Spacer(minLength: 12)
                actions()
            }
            .padding(.horizontal, Metrics.gutter)
            .frame(height: Metrics.headerHeight)
            .padding(.top, 8)
            Divider()
        }
    }
}

struct StatusBar: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            if let p = progress {
                // How far through the task the run is: a hairline that fills with cobalt.
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Rectangle().fill(Brand.mist)
                        Rectangle().fill(Brand.cobalt).frame(width: g.size.width * p)
                    }
                }
                .frame(height: 2)
                .animation(.easeOut(duration: 0.25), value: p)
            }
            HStack(spacing: 7) {
                Image(systemName: state.symbol)
                    .font(.ui(11, .semibold))
                    .foregroundStyle(state.color)
                Text(state.word)
                    .font(.ui(11, .semibold))
                    .foregroundStyle(Brand.ink)
                if !detail.isEmpty {
                    Text(detail)
                        .font(.ui(11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Spacer(minLength: 12)
                actions
            }
            .padding(.horizontal, Metrics.gutter)
            .frame(height: Metrics.statusHeight)
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var actions: some View {
        if model.runningID != nil {
            ShortcutHint(label: "Stop", keys: "Esc")
        } else if model.isRecording {
            ShortcutHint(label: "Read the text under the pointer", keys: "⌃⌥R")
            ShortcutHint(label: "Save", keys: "⌘↩")
        } else {
            if model.lastStop != nil && !model.isTeachingPopup {
                Button("Something in the way?") { model.teachPopup() }
                    .buttonStyle(.plain)
                    .font(.ui(11, .medium))
                    .foregroundStyle(Brand.cobalt)
                    .help("Show Deja Do how to close a popup that blocked the run, so it handles it next time")
            }
            if let r = model.resume {
                Button("Continue from row \(r.from + 1)") { model.continueRows() }
                    .buttonStyle(.plain)
                    .font(.ui(11, .medium))
                    .foregroundStyle(Brand.cobalt)
            }
        }
    }

    private var running: Automation? {
        model.runningID.flatMap { id in model.automations.first { $0.id == id } }
    }

    private var progress: Double? {
        guard let a = running, !a.steps.isEmpty else { return nil }
        let perRow = Double(min(model.runningStep + 1, a.steps.count)) / Double(a.steps.count)
        guard model.rowCount > 1 else { return perRow }
        return (Double(model.runningRow) + perRow) / Double(model.rowCount)
    }

    private var state: RunState {
        if model.isRecording { return .recording }
        if model.runningID != nil { return .running }
        if !model.permissionsReady || model.isTeachingPopup || model.pendingRun != nil || model.resume != nil { return .needsAttention }
        switch model.lastResult?.ending {
        case .completed: return .completed
        case .failed: return .failed
        case .stopped: return .needsAttention
        case nil: return .ready
        }
    }

    private var detail: String {
        if model.isRecording {
            let n = model.liveSteps.count
            return "\(n) step\(n == 1 ? "" : "s") so far"
        }
        if let a = running {
            var parts = [a.name]
            if model.rowCount > 1 { parts.append("Row \(model.runningRow + 1) of \(model.rowCount)") }
            parts.append("Step \(min(model.runningStep + 1, a.steps.count)) of \(a.steps.count)")
            if a.steps.indices.contains(model.runningStep) { parts.append(a.steps[model.runningStep].safeSummary) }
            return parts.joined(separator: " · ")
        }
        if !model.permissionsReady { return "Deja Do needs a couple of permissions first" }
        if let r = model.lastResult, model.lastResult?.ending == .completed, !(model.status ?? "").hasPrefix("Saved") {
            var parts = [r.name]
            parts.append(r.rows > 1 ? "\(r.rows) rows" : "\(r.steps) step\(r.steps == 1 ? "" : "s")")
            if let t = r.seconds { parts.append(t < 60 ? String(format: "%.1f s", t) : "\(Int(t) / 60) min \(Int(t) % 60) s") }
            if !model.lastRead.isEmpty, r.rows == 1 {
                parts.append(model.lastRead.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value.prefix(40))" }.joined(separator: ", "))
            }
            return parts.joined(separator: " · ")
        }
        return model.status ?? ""
    }
}

// MARK: - Automation detail

struct AutomationView: View {
    @EnvironmentObject var model: AppModel
    @Binding var automation: Automation

    /// Finishes any edit still in a field, so a run uses what's on screen.
    private func afterEditing(_ action: @escaping (Automation) -> Void) {
        NSApp.keyWindow?.makeFirstResponder(nil)
        let id = automation.id
        let model = model
        Task { @MainActor in
            // The field saves when it loses focus, on the next pass of the run loop.
            try? await Task.sleep(nanoseconds: 100_000_000)
            if let latest = model.automations.first(where: { $0.id == id }) { action(latest) }
        }
    }

    /// Why the last run of this task failed, from this session or its saved history.
    @State private var savedReason: String?

    private var failureReason: String? {
        guard !isRunning, automation.lastSucceeded == false else { return nil }
        if let r = model.lastResult, r.automationID == automation.id {
            return r.ending == .completed || r.message.isEmpty ? nil : r.message
        }
        return savedReason
    }

    /// The step the last run stopped on, counted from 1.
    private var stoppedStep: Int? {
        guard let s = model.lastStop, s.automationID == automation.id else { return nil }
        return s.step + 1
    }

    /// The step whose settings are open. One at a time keeps the list calm.
    @State private var expanded: UUID?

    private var isRunning: Bool { model.runningID == automation.id }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HeaderBar {
                VStack(alignment: .leading, spacing: 3) {
                    TextField("Name", text: $automation.name)
                        .textFieldStyle(.plain)
                        .font(.ui(17, .semibold))
                    meta
                }
            } actions: {
                if !isRunning {
                    Button(model.isChecking ? "Checking…" : "Check") { afterEditing { model.check($0) } }
                        .buttonStyle(QuietButtonStyle(compact: true))
                        .disabled(model.runningID != nil || model.isRecording || model.isChecking)
                        .help("Look for every button on screen now, without clicking or typing anything")
                }
                if isRunning {
                    Button { model.stopRun() } label: {
                        Label("Stop", systemImage: "stop.fill").labelStyle(.titleAndIcon)
                    }
                    .buttonStyle(QuietButtonStyle(compact: true))
                } else {
                    Button { afterEditing { _ = model.run($0) } } label: {
                        Label("Run", systemImage: "play.fill").labelStyle(.titleAndIcon)
                    }
                    .buttonStyle(PrimaryButtonStyle(compact: true))
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(model.runningID != nil || model.isRecording)
                }
                Menu {
                    Button("Run for each row of a spreadsheet…") { afterEditing { model.runForEachRow($0) } }
                    Button(automation.schedule?.on == true ? "Change schedule…" : "Run on a schedule…") { model.scheduleFor = automation.id }
                    Button("Run history…") { model.historyFor = automation.id }
                    Divider()
                    Button("Duplicate") { model.duplicate(automation.id) }
                    Button("Export…") { model.export(automation.id) }
                    Button("Add as a skill for Claude Code and Codex") { model.installSkill(automation.id) }
                    Button("Save as a skill file…") { model.exportSkill(automation.id) }
                    Divider()
                    Button("Delete", role: .destructive) { model.delete(automation.id) }
                } label: {
                    Image(systemName: "ellipsis")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .foregroundStyle(.secondary)
            }

            HStack(spacing: 6) {
                TextField("What this task is for (helps AI and agents)", text: goal)
                    .textFieldStyle(.plain)
                    .font(.ui(12))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, Metrics.gutter)
            .padding(.vertical, 9)
            Divider()

            // A plain stack rather than a List: the Mac's list takes the clicks
            // meant for text fields inside its rows, so a step's name or text
            // couldn't be clicked into and changed.
            if let reason = failureReason {
                StopReason(reason: reason, stoppedAt: stoppedStep) { model.historyFor = automation.id }
                Divider()
            }

            // Worked out once per update, not once per step.
            let trims = trimReasons
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(variableSuggestions) { s in
                        SuggestionLine(text: "Fill in “\(s.text.prefix(40))” each run as {{\(s.name)}}?",
                                       accept: "Make it a variable") {
                            model.applyVariable(s, in: automation.id)
                        } dismiss: {
                            model.dismissSuggestion(s.stepID)
                        }
                        .padding(.horizontal, Metrics.gutter)
                        Divider().padding(.leading, Metrics.gutter)
                    }
                    ForEach($automation.steps) { $step in
                        let n = number(of: step)
                        StepRow(step: $step, number: n, state: state(for: n - 1), note: model.runNotes[step.id],
                                expanded: expanded == step.id, risk: automation.risk(at: n - 1),
                                trimReason: trims[step.id], onRemove: { remove(step) },
                                onKeep: { model.dismissSuggestion(step.id) },
                                onEdited: { old, new in edited(step.id, old, new) }) {
                            withAnimation(.easeOut(duration: 0.15)) { expanded = expanded == step.id ? nil : step.id }
                        }
                        .padding(.horizontal, Metrics.gutter - 8)
                        .contentShape(Rectangle())
                        .contextMenu { stepMenu(step, number: n) }
                        Divider().padding(.leading, Metrics.gutter - 8)
                    }
                    if !automation.steps.isEmpty && model.runningID == nil {
                        Text("Click a step to change it. Right click to move, skip, delete or add a step.")
                            .font(.ui(11))
                            .foregroundStyle(.tertiary)
                            .padding(.vertical, 12)
                            .padding(.leading, Metrics.gutter + 26)
                    }
                    ForEach(automation.popups ?? []) { rule in
                        SuggestionLine(text: "When “\(rule.name)” shows up, \(rule.dismiss.summary) and carry on.",
                                       accept: nil, accepted: {}) {
                            model.removePopup(rule, from: automation.id)
                        }
                        .padding(.horizontal, Metrics.gutter)
                        Divider().padding(.leading, Metrics.gutter)
                    }
                }
                .padding(.bottom, 24)
            }
        }
        .task(id: automation.lastRun) {
            let id = automation.id, history = model.history
            savedReason = await Task.detached { history.load(id).first?.outcome }.value
        }
    }

    /// One quiet line under the title: how long it is, when it last ran, what it fills in.
    private var meta: some View {
        var parts: [Text] = [Text("\(automation.steps.count) steps")]
        if let last = automation.lastRun {
            let when = last.formatted(.relative(presentation: .named))
            let took = automation.lastDuration.map { String(format: " in %.1fs", $0) } ?? ""
            if automation.lastSucceeded == false {
                parts.append(Text("failed \(when)").foregroundColor(Brand.red))
            } else {
                parts.append(Text("last ran \(when)\(took)"))
            }
        } else {
            parts.append(Text("never run"))
        }
        if automation.repairs > 0 {
            parts.append(Text("\(automation.repairs) AI \(automation.repairs == 1 ? "fix" : "fixes")"))
        }
        if !automation.variableNames.isEmpty {
            parts.append(Text(automation.variableNames.map { "{{\($0)}}" }.joined(separator: " "))
                .foregroundColor(Brand.cobalt))
        }
        if let next = model.nextRun(automation) {
            parts.append(Text("next run \(next.formatted(.relative(presentation: .named)))"))
        }
        let line = parts.dropFirst().reduce(parts[0]) { $0 + Text("  ·  ") + $1 }
        return line
            .font(.ui(12))
            .foregroundStyle(.secondary)
            .lineLimit(1)
    }

    private func state(for index: Int) -> StepState {
        guard isRunning else { return .idle }
        if index < model.runningStep { return .done }
        if index == model.runningStep { return .current }
        return .idle
    }

    private func number(of step: Step) -> Int {
        (automation.steps.firstIndex { $0.id == step.id } ?? 0) + 1
    }

    private var goal: Binding<String> {
        Binding(get: { automation.goal ?? "" },
                set: { automation.goal = $0.isEmpty ? nil : $0 })
    }

    private var variableSuggestions: [VariableSuggestion] {
        VariableSuggester.suggestions(for: automation).filter { !model.dismissedSuggestions.contains($0.stepID) }
    }

    private var trimReasons: [UUID: String] {
        var out: [UUID: String] = [:]
        for s in StepTrim.suggestions(for: automation) where !model.dismissedSuggestions.contains(s.stepID) {
            out[s.stepID] = s.reason
        }
        return out
    }

    static func canBeRisky(_ step: Step) -> Bool {
        switch step.kind {
        case .click, .key: return true
        default: return false
        }
    }

    private func setStep(_ id: UUID, _ change: (inout Step) -> Void) {
        guard let i = automation.steps.firstIndex(where: { $0.id == id }) else { return }
        change(&automation.steps[i])
    }

    @ViewBuilder private func stepMenu(_ step: Step, number n: Int) -> some View {
        Button(step.isEnabled ? "Skip this step" : "Don't skip this step") {
            setStep(step.id) { $0.disabled = $0.isEnabled ? true : nil }
            edited(step.id, nil, nil)
        }
        if Self.canBeRisky(step) {
            let risky = automation.risk(at: n - 1).risk == .risky
            Button(risky ? "This doesn't send, save or delete" : "This sends, saves or deletes") {
                setStep(step.id) { $0.risk = risky ? .normal : .risky }
            }
        }
        if model.beforeRepair[step.id] != nil {
            Button("Undo the AI fix") { model.undoRepair(automation: automation.id, step: step.id) }
        }
        Divider()
        Button("Move up") { move(step, by: -1) }
            .disabled(automation.steps.first?.id == step.id)
        Button("Move down") { move(step, by: 1) }
            .disabled(automation.steps.last?.id == step.id)
        Divider()
        Button("Add text to type after") { insertText(after: step) }
        Button("Add a 2 second wait after") { insertWait(after: step) }
        Divider()
        Button("Delete step", role: .destructive) { remove(step) }
    }

    private func move(_ step: Step, by offset: Int) {
        guard let i = automation.steps.firstIndex(where: { $0.id == step.id }) else { return }
        let j = i + offset
        guard automation.steps.indices.contains(j) else { return }
        automation.steps.swapAt(i, j)
        automation.noteEdit(at: min(i, j))
    }

    private func remove(_ step: Step) {
        guard let i = automation.steps.firstIndex(where: { $0.id == step.id }) else { return }
        automation.steps.remove(at: i)
        automation.noteEdit(at: i)
    }

    /// Later checks follow a hand edit, or are learned again on the next run.
    private func edited(_ id: UUID, _ old: String?, _ new: String?) {
        guard let i = automation.steps.firstIndex(where: { $0.id == id }) else { return }
        automation.noteEdit(at: i, replacing: old, with: new)
    }

    private func insertWait(after step: Step) {
        guard let i = automation.steps.firstIndex(where: { $0.id == step.id }) else { return }
        let wait = Step(kind: .wait(seconds: 2))
        automation.steps.insert(wait, at: i + 1)
        expanded = wait.id
    }

    private func insertText(after step: Step) {
        guard let i = automation.steps.firstIndex(where: { $0.id == step.id }) else { return }
        let text = Step(kind: .type(text: "", askEachRun: false, secret: false, prompt: ""))
        automation.steps.insert(text, at: i + 1)
        automation.noteEdit(at: i + 1)
        expanded = text.id
    }
}

enum StepState { case idle, current, done }

/// Why the last run stopped, in full, under the task's title. Stays until the
/// next run, so it's there when you come back to the task.
struct StopReason: View {
    let reason: String
    var stoppedAt: Int?
    var openHistory: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: RunState.failed.symbol)
                .font(.ui(12, .semibold))
                .foregroundStyle(RunState.failed.color)
            VStack(alignment: .leading, spacing: 3) {
                Text(stoppedAt.map { "Stopped at step \($0)" } ?? "Why it stopped")
                    .font(.ui(12, .semibold))
                    .foregroundStyle(Brand.ink)
                Text(reason)
                    .font(.ui(12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 12)
            Button("Run history", action: openHistory)
                .buttonStyle(.plain)
                .font(.ui(12, .medium))
                .foregroundStyle(Brand.cobalt)
        }
        .padding(.horizontal, Metrics.gutter)
        .padding(.vertical, 12)
    }
}

/// One numbered row in a step table. Used for saved and live steps alike.
struct StepLine<Editor: View>: View {
    let number: Int?
    let summary: String
    var app: String? = nil
    var state: StepState = .idle
    var dimmed = false
    /// What this step did on the last run.
    var note: String? = nil
    /// Opens or closes the step's settings, for steps that have any.
    var onTap: (() -> Void)? = nil
    @ViewBuilder var editor: () -> Editor
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            ZStack {
                switch state {
                case .current:
                    ProgressView().controlSize(.mini)
                case .done:
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Brand.forest)
                case .idle:
                    Text(number.map(String.init) ?? "")
                        .font(.ui(12, .medium).monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(width: 22, alignment: .trailing)
            .contentShape(Rectangle())
            .onTapGesture { onTap?() }

            VStack(alignment: .leading, spacing: 4) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(summary)
                        .font(.ui(13, state == .current ? .semibold : .regular))
                        .foregroundStyle(hovering ? AnyShapeStyle(Brand.cobalt)
                                         : AnyShapeStyle(dimmed || state == .done ? HierarchicalShapeStyle.secondary : HierarchicalShapeStyle.primary))
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if let note {
                        Text(note)
                            .font(.ui(11))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture { onTap?() }
                .onHover { inside in
                    guard onTap != nil else { return }
                    hovering = inside
                    if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
                }
                editor()
            }

            if let app {
                Text(app)
                    .font(.ui(12))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 11)
    }
}

extension Step {
    /// The app a step belongs to, for the table's App column.
    var appName: String? {
        switch kind {
        case .activate(_, let name): return name
        case .click(let t, _, _, _): return t.appName
        default: return nil
        }
    }
}

/// A text field inside the step list that keeps what you type to itself
/// until you press Return or click away. Writing every keystroke straight
/// into the task makes the list reload its rows, which takes the cursor out
/// of the field after one letter.
struct DraftField: View {
    let placeholder: String
    @Binding var text: String
    var font: Font = .ui(12)
    @State private var draft: String
    @FocusState private var focused: Bool

    init(placeholder: String, text: Binding<String>, font: Font = .ui(12)) {
        self.placeholder = placeholder
        self._text = text
        self.font = font
        // Filled in from the start, so the field never shows empty while it loads.
        self._draft = State(initialValue: text.wrappedValue)
    }

    var body: some View {
        TextField(placeholder, text: $draft)
            .textFieldStyle(.plain)
            .font(font)
            .focused($focused)
            .onChange(of: text) { new in if !focused { draft = new } }
            .onChange(of: focused) { now in if !now { commit() } }
            .onSubmit { commit() }
            .onDisappear { commit() }
    }

    private func commit() {
        if draft != text { text = draft }
    }
}

/// Shows a key press and changes it to the next keys pressed after a click.
struct KeyCatcher: View {
    let label: String
    let code: UInt16
    let modifiers: UInt64
    let onChange: (UInt16, UInt64, String) -> Void
    @State private var listening = false
    @State private var monitor: Any?

    var body: some View {
        Button(listening ? "Press the new keys…" : label) {
            listening ? stop() : start()
        }
        .buttonStyle(.plain)
        .font(.mono(12, .medium))
        .foregroundStyle(listening ? AnyShapeStyle(Brand.cobalt) : AnyShapeStyle(HierarchicalShapeStyle.primary))
        .help("Click, then press the keys this step should press instead. Esc cancels.")
        .onDisappear { stop() }
    }

    private func start() {
        listening = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            defer { stop() }
            if event.keyCode == 53 && event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty { return nil }
            var flags = CGEventFlags()
            let m = event.modifierFlags
            if m.contains(.command) { flags.insert(.maskCommand) }
            if m.contains(.control) { flags.insert(.maskControl) }
            if m.contains(.option) { flags.insert(.maskAlternate) }
            if m.contains(.shift) { flags.insert(.maskShift) }
            let label = KeyNames.label(code: event.keyCode, flags: flags,
                                       chars: event.charactersIgnoringModifiers)
            onChange(event.keyCode, flags.rawValue, label)
            return nil
        }
    }

    private func stop() {
        listening = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}

struct StepRow: View {
    @Binding var step: Step
    let number: Int
    let state: StepState
    var note: String? = nil
    /// Settings show only for the open step; the list itself stays one line per step.
    var expanded = false
    var risk = RiskGuess(risk: .normal, reason: nil)
    /// Why this step looks like it did nothing, when it does.
    var trimReason: String? = nil
    var onRemove: () -> Void = {}
    var onKeep: () -> Void = {}
    /// The step was changed by hand; old and new are the text that changed, if any.
    var onEdited: (_ old: String?, _ new: String?) -> Void = { _, _ in }
    var toggle: () -> Void = {}

    var body: some View {
        StepLine(number: number, summary: step.summary, state: state, dimmed: !step.isEnabled,
                 note: note ?? (step.isEnabled ? nil : "Skipped when the task runs"),
                 onTap: hasSettings ? toggle : nil) {
            if risk.risk == .risky && step.isEnabled {
                Text("Sends, saves or deletes, so it runs once and is never retried")
                    .font(.ui(11))
                    .foregroundStyle(.secondary)
                    .help(risk.reason ?? "")
            }
            if let trimReason {
                HStack(spacing: 10) {
                    Text("\(trimReason).").font(.ui(11)).foregroundStyle(.secondary)
                    Button("Remove", action: onRemove).buttonStyle(.plain).font(.ui(11, .medium))
                        .foregroundStyle(Brand.cobalt)
                    Button("Keep", action: onKeep).buttonStyle(.plain).font(.ui(11, .medium))
                        .foregroundStyle(.secondary)
                }
            }
            if expanded && hasSettings { editor }
        }
    }

    /// Every step opens, so clicking any of them does something.
    private var hasSettings: Bool { true }

    @ViewBuilder private var editor: some View {
        switch step.kind {
        case .type(_, _, let secret, _) where !secret:
            HStack(spacing: 18) {
                VStack(spacing: 3) {
                    DraftField(placeholder: "Text to type", text: typedText)
                        .disabled(askEachRun.wrappedValue)
                    Divider()
                }
                .frame(maxWidth: 300)
                Toggle("Ask each run", isOn: askEachRun)
                    .toggleStyle(.checkbox)
                    .font(.ui(11))
            }
            .padding(.top, 6)
            Text("Type {{name}} anywhere to fill it in each run, or from a spreadsheet column.")
                .font(.ui(11))
                .foregroundStyle(.tertiary)
                .padding(.bottom, 2)
        case .type:
            Text("A password, asked for each run and never saved.")
                .font(.ui(11))
                .foregroundStyle(.secondary)
                .padding(.top, 4)
        case .activate(_, let name):
            Text("Brings \(name) to the front. Right click to skip or delete it.")
                .font(.ui(11))
                .foregroundStyle(.secondary)
                .padding(.top, 4)
        case .click, .key:
            if case .click = step.kind, step.targetName != nil {
                HStack(spacing: 8) {
                    Text("Looks for").font(.ui(12)).foregroundStyle(.secondary)
                    VStack(spacing: 3) {
                        DraftField(placeholder: "name", text: targetName)
                        Divider()
                    }
                    .frame(maxWidth: 220)
                }
                .padding(.top, 6)
                Text("Change the name to click a different button or chat, like another person in the list.")
                    .font(.ui(11))
                    .foregroundStyle(.tertiary)
            } else if case .click = step.kind {
                Text("Clicks a spot found by what's around it. Record it again to change it.")
                    .font(.ui(11))
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
            }
            if case .key(let code, let mods, let label) = step.kind {
                HStack(spacing: 8) {
                    Text("Keys").font(.ui(12)).foregroundStyle(.secondary)
                    KeyCatcher(label: label, code: code, modifiers: mods) { c, m, l in
                        guard c != code || m != mods else { return }
                        step.kind = .key(code: c, modifiers: m, label: l)
                        onEdited(nil, nil)
                    }
                }
                .padding(.top, 6)
            }
            if let line = step.expect?.summary {
                VStack(alignment: .leading, spacing: 6) {
                    Text(line)
                        .font(.ui(12))
                        .foregroundStyle(.secondary)
                    HStack(spacing: 6) {
                        Text("If it doesn't match")
                            .font(.ui(12))
                            .foregroundStyle(.secondary)
                        Picker("If it doesn't match", selection: mismatch) {
                            ForEach(MismatchPolicy.allCases, id: \.self) { Text($0.label).tag($0) }
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                        .controlSize(.small)
                        .fixedSize()
                    }
                }
                .padding(.top, 6)
                .padding(.bottom, 2)
            }
        case .read:
            HStack(spacing: 8) {
                Text("Keep it as").font(.ui(12)).foregroundStyle(.secondary)
                VStack(spacing: 3) {
                    DraftField(placeholder: "name", text: readName)
                    Divider()
                }
                .frame(maxWidth: 180)
            }
            .padding(.top, 6)
            Text("Later steps can type {{\(readName.wrappedValue)}}, and tools that start this task get it back.")
                .font(.ui(11))
                .foregroundStyle(.tertiary)
                .padding(.bottom, 2)
        case .wait:
            Stepper(value: waitSeconds, in: 0.5...60, step: 0.5) {
                Text("\(waitSeconds.wrappedValue, specifier: "%g") seconds")
                    .font(.ui(11))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: 200, alignment: .leading)
            .padding(.top, 2)
        }
    }

    private var typedText: Binding<String> {
        Binding(
            get: { if case .type(let t, _, _, _) = step.kind { return t }; return "" },
            set: { new in
                if case .type(let old, let a, let s, let p) = step.kind, old != new {
                    step.kind = .type(text: new, askEachRun: a, secret: s, prompt: p)
                    onEdited(old, new)
                }
            }
        )
    }

    private var targetName: Binding<String> {
        Binding(
            get: { step.targetName ?? "" },
            set: { new in
                let old = step.targetName
                let renamed = step.renamingTarget(to: new)
                guard renamed != step else { return }
                step = renamed
                onEdited(old, renamed.targetName)
            }
        )
    }

    private var askEachRun: Binding<Bool> {
        Binding(
            get: { if case .type(_, let a, _, _) = step.kind { return a }; return false },
            set: { new in
                if case .type(let t, _, let s, let p) = step.kind {
                    step.kind = .type(text: t, askEachRun: new, secret: s, prompt: p)
                }
            }
        )
    }

    private var mismatch: Binding<MismatchPolicy> {
        Binding(
            get: { step.onMismatch ?? .default },
            set: { step.onMismatch = $0 == .default ? nil : $0 }
        )
    }

    private var readName: Binding<String> {
        Binding(
            get: { if case .read(_, let n) = step.kind { return n }; return "" },
            set: { new in
                if case .read(let t, _) = step.kind {
                    let clean = new.replacingOccurrences(of: "{", with: "").replacingOccurrences(of: "}", with: "")
                    step.kind = .read(target: t, name: clean.isEmpty ? "value" : clean)
                }
            }
        )
    }

    private var waitSeconds: Binding<Double> {
        Binding(
            get: { if case .wait(let s) = step.kind { return s }; return 1 },
            set: { step.kind = .wait(seconds: $0) }
        )
    }
}

// MARK: - Recording

struct RecordingView: View {
    @EnvironmentObject var model: AppModel
    @State private var pulse = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HeaderBar {
                HStack(spacing: 9) {
                    Circle()
                        .fill(Brand.red)
                        .frame(width: 8, height: 8)
                        .opacity(pulse ? 0.25 : 1)
                        .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: pulse)
                    Text("Recording").font(.ui(17, .semibold))
                }
                .onAppear { pulse = true }
            } actions: {
                Button("Discard") { model.discardRecording() }
                    .buttonStyle(QuietButtonStyle(compact: true))
                Button { model.stopRecording() } label: {
                    Label("Stop and save", systemImage: "stop.fill").labelStyle(.titleAndIcon)
                }
                .buttonStyle(PrimaryButtonStyle(compact: true))
                .keyboardShortcut(.return, modifiers: .command)
            }

            Text("Do the task the way you normally would. Every click, keystroke and app switch becomes a step. Passwords are never recorded. To keep a value from the screen, like a total or an order number, point at it and press ⌃⌥R.")
                .font(.ui(13))
                .foregroundStyle(.secondary)
                .frame(maxWidth: 560, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, Metrics.gutter)
                .padding(.vertical, 16)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(model.liveSteps.enumerated()), id: \.element.id) { i, step in
                        StepLine(number: i + 1, summary: step.summary) { EmptyView() }
                        Divider()
                    }
                    if !model.pendingText.isEmpty {
                        StepLine(number: nil, summary: "Typing “\(model.pendingText)”", dimmed: true) { EmptyView() }
                    }
                    if model.liveSteps.isEmpty && model.pendingText.isEmpty {
                        Text("Waiting for your first click…")
                            .font(.ui(13))
                            .foregroundStyle(.tertiary)
                            .padding(.vertical, 14)
                    }
                }
                .padding(.horizontal, Metrics.gutter - 8)
            }
        }
    }
}

// MARK: - Empty state and permissions

struct EmptyStateView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HeaderBar {
                Text("Welcome").font(.ui(17, .semibold))
            } actions: {
                EmptyView()
            }
            VStack(alignment: .leading, spacing: 12) {
                BrandMark().frame(height: 34).padding(.bottom, 10)
                Text("Do it once.")
                    .font(.ui(28, .semibold))
                    .foregroundStyle(Brand.ink)
                Text("Record a boring task, like downloading a report, renaming it and emailing it. Deja Do saves every step and does the whole thing for you from then on. If a button moves or gets renamed, it finds it again.")
                    .font(.ui(14))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 480, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                Button { model.startRecording() } label: {
                    Label("Record a task", systemImage: "record.circle").labelStyle(.titleAndIcon)
                }
                .buttonStyle(PrimaryButtonStyle())
                .padding(.top, 10)
            }
            .padding(Metrics.gutter)
        }
    }
}

struct PermissionsView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HeaderBar {
                Text("Set up").font(.ui(17, .semibold))
            } actions: {
                EmptyView()
            }
            VStack(alignment: .leading, spacing: 0) {
                Text("Two permissions first")
                    .font(.ui(22, .semibold))
                Text("macOS has to let Deja Do press buttons in other apps, and notice your clicks and keys while you record. Nothing leaves your Mac.")
                    .font(.ui(13))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 520, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 8)
                    .padding(.bottom, 22)

                Divider()
                row("Accessibility", detail: "Find and press buttons when a task runs", granted: model.hasAccessibility) {
                    Permissions.requestAccessibility()
                    Permissions.openAccessibilitySettings()
                }
                Divider()
                row("Input Monitoring", detail: "Notice clicks and typing while you record", granted: model.hasInputMonitoring) {
                    Permissions.requestInputMonitoring()
                    Permissions.openInputMonitoringSettings()
                }
                Divider()

                Text("Switch both on in System Settings, then quit and reopen Deja Do. This page updates by itself.")
                    .font(.ui(12))
                    .foregroundStyle(.tertiary)
                    .padding(.top, 16)
            }
            .frame(maxWidth: 560, alignment: .leading)
            .padding(Metrics.gutter)
        }
    }

    private func row(_ title: String, detail: String, granted: Bool, action: @escaping () -> Void) -> some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: granted ? "checkmark" : "circle")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(granted ? AnyShapeStyle(Brand.forest) : AnyShapeStyle(.tertiary))
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.ui(13, .medium))
                Text(detail).font(.ui(12)).foregroundStyle(.secondary)
            }
            Spacer()
            if granted {
                Text("On").font(.ui(12)).foregroundStyle(.secondary)
            } else {
                Button("Open Settings", action: action)
                    .buttonStyle(QuietButtonStyle(compact: true))
            }
        }
        .padding(.vertical, 14)
    }
}

// MARK: - Variables

/// Asks once for every {{variable}} a task uses, then runs it.
struct VariablesSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let pending: AppModel.PendingRun
    @State private var values: [String: String] = [:]

    private var name: String {
        model.automations.first { $0.id == pending.automationID }?.name ?? "Task"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Run “\(name)”")
                .font(.ui(17, .semibold))
            Text("Fill these in for this run.")
                .font(.ui(12))
                .foregroundStyle(.secondary)
                .padding(.top, 4)
                .padding(.bottom, 16)

            Divider()
            ForEach(pending.names, id: \.self) { key in
                VStack(alignment: .leading, spacing: 6) {
                    Text(key).font(.ui(12, .medium)).foregroundStyle(.secondary)
                    TextField("", text: binding(key))
                        .textFieldStyle(.plain)
                        .font(.ui(13))
                }
                .padding(.vertical, 12)
                Divider()
            }

            HStack {
                Button("Use a spreadsheet instead…") {
                    let id = pending.automationID
                    dismiss()
                    if let a = model.automations.first(where: { $0.id == id }) {
                        DispatchQueue.main.async { model.runForEachRow(a) }
                    }
                }
                .buttonStyle(.plain)
                .font(.ui(12))
                .foregroundStyle(Brand.cobalt)
                Spacer()
                Button("Cancel") { model.pendingRun = nil }
                    .buttonStyle(QuietButtonStyle(compact: true))
                    .keyboardShortcut(.cancelAction)
                Button {
                    model.runPending(values: values)
                } label: {
                    Label("Run", systemImage: "play.fill").labelStyle(.titleAndIcon)
                }
                .buttonStyle(PrimaryButtonStyle(compact: true))
                .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 18)
        }
        .padding(26)
        .frame(width: 440)
        .fontDesign(.default)
        .onAppear { values = model.lastValues[pending.automationID] ?? [:] }
    }

    private func binding(_ key: String) -> Binding<String> {
        Binding(get: { values[key] ?? "" }, set: { values[key] = $0 })
    }
}

// MARK: - Settings

struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Settings")
                .font(.ui(17, .semibold))
                .padding(.bottom, 16)

            Divider()

            Toggle("Ask AI when a button can't be found with confidence", isOn: $model.aiEnabled)
                .font(.ui(13))
                .padding(.vertical, 14)

            Divider()

            toggle("Check that each step worked", isOn: $model.checkSteps,
                   note: "After each click or key press, looks for what changed when you recorded it, like the name you clicked showing up in the header. Waits, tries once more if nothing happened, then stops.")

            Divider()

            toggle("Ask before steps that send, save or delete", isOn: $model.askBeforeRisky,
                   note: "Deja Do always stops instead of retrying those steps, and asks before letting AI pick one. Turn this on to be asked before every one of them, every run.")

            Divider()

            toggle("Let other apps and AI agents run tasks", isOn: $model.allowOtherApps,
                   note: "Tasks added as skills run through dejado:// links. When this is off, you're asked each time.")

            Divider()

            toggle("Open Deja Do when you log in", isOn: Binding(get: { model.openAtLogin }, set: { model.openAtLogin = $0 }),
                   note: "So scheduled tasks still run after the Mac restarts. Deja Do sits in the menu bar.")

            Divider()

            toggle("Let tools on this Mac start tasks", isOn: $model.webhooksEnabled,
                   note: "For n8n, Node-RED, scripts and Shortcuts running on this Mac. They send a request with a token to a local address, and can get the result back. Nothing on the network can reach it.")
            if model.webhooksEnabled {
                VStack(alignment: .leading, spacing: 8) {
                    Text(model.webhookStatus)
                        .font(.ui(11))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    HStack(spacing: 10) {
                        Button("Copy example request") { model.copyWebhookDetails() }
                            .buttonStyle(QuietButtonStyle(compact: true))
                        Button("New token") { model.newWebhookToken() }
                            .buttonStyle(QuietButtonStyle(compact: true))
                            .help("Tools using the old token stop working")
                        Spacer()
                    }
                }
                .padding(.bottom, 14)
            }

            Divider()

            toggle("Use the screen when an app doesn't describe its buttons", isOn: $model.useVision,
                   note: "For canvas apps, games and virtual machines. Keeps a small picture and the text around each click, read on your Mac and never sent anywhere.")
            if model.useVision && !model.hasScreenRecording {
                HStack {
                    Text("Needs Screen Recording permission.")
                        .font(.ui(11))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Open Settings") {
                        ScreenVision.requestPermission()
                        ScreenVision.openSettings()
                    }
                    .buttonStyle(QuietButtonStyle(compact: true))
                }
                .padding(.bottom, 14)
            }

            Divider()

            VStack(alignment: .leading, spacing: 0) {
                aiSection
            }
            .disabled(!model.aiEnabled)
            .opacity(model.aiEnabled ? 1 : 0.5)

            Divider()

            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Repair records")
                        .font(.ui(13))
                    Text(model.corpus.summary() + " How controls were described when a step had to be healed, picked by AI, found from the screen or wasn't found. No typed text. Stays on this Mac unless you save it somewhere.")
                        .font(.ui(11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 16)
                Button("Save…") { model.exportRepairs() }
                    .buttonStyle(QuietButtonStyle(compact: true))
                    .disabled(model.corpus.count == 0)
            }
            .padding(.vertical, 14)

            Divider()

            HStack {
                Text("Esc stops a running task.")
                    .font(.ui(12))
                    .foregroundStyle(.tertiary)
                Spacer()
                Button("Done") { dismiss() }
                    .buttonStyle(PrimaryButtonStyle(compact: true))
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 16)
        }
        .padding(26)
        .frame(width: 480)
        .fontDesign(.default)
        .onAppear { if model.aiProvider == .ollama { model.refreshOllamaModels() } }
    }

    // MARK: AI

    @ViewBuilder private var aiSection: some View {
        row("AI service", note: providerNote) {
            Picker("AI service", selection: $model.aiProvider) {
                ForEach(AIProvider.allCases, id: \.self) { Text($0.name).tag($0) }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .fixedSize()
        }

        switch model.aiProvider {
        case .dejaDo:
            Divider()
            row("Server", note: nil) {
                TextField("https://ai.example.com", text: $model.serverURL)
                    .textFieldStyle(.plain)
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: 240)
            }
            Divider()
            keyRow
        case .anthropic, .openai, .gemini:
            Divider()
            keyRow
        case .ollama:
            Divider()
            row("Address", note: nil) {
                TextField(AIRequest.ollamaDefault, text: $model.ollamaURL)
                    .textFieldStyle(.plain)
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: 240)
                    .onSubmit { model.refreshOllamaModels() }
            }
        }

        Divider()
        row("Model", note: modelNote) { modelPicker }
    }

    private var keyRow: some View {
        row(model.aiProvider.keyLabel, note: nil) {
            SecureField(model.aiProvider.keyPlaceholder, text: $model.providerKey)
                .textFieldStyle(.plain)
                .multilineTextAlignment(.trailing)
                .frame(maxWidth: 240)
        }
    }

    @ViewBuilder private var modelPicker: some View {
        if model.aiProvider == .ollama && model.ollamaModels.isEmpty {
            Button("Look again") { model.refreshOllamaModels() }
                .buttonStyle(QuietButtonStyle(compact: true))
        } else {
            Picker("Model", selection: $model.model) {
                ForEach(modelChoices, id: \.id) { m in Text(m.name).tag(m.id) }
                // Keeps a model chosen earlier selectable even if it's no longer listed.
                if !model.model.isEmpty && !modelChoices.contains(where: { $0.id == model.model }) {
                    Text(model.model).tag(model.model)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .fixedSize()
        }
    }

    private var modelChoices: [AIModel] {
        if model.aiProvider == .ollama { return model.ollamaModels.map { AIModel($0, $0, "") } }
        return AICatalog.models(for: model.aiProvider)
    }

    private var providerNote: String {
        switch model.aiProvider {
        case .dejaDo:
            return "Goes through the Deja Do server, which holds the API keys. You only need the access code you were given."
        case .anthropic, .openai, .gemini:
            return "Uses your own \(model.aiProvider.name) key, kept in your keychain. Only a text list of the window's buttons and labels is sent, never your screen or what you typed."
        case .ollama:
            return "Runs a model on this Mac, so nothing leaves it and it's free. Needs Ollama installed and a model pulled, for example ollama pull qwen3:8b."
        }
    }

    private var modelNote: String? {
        if model.aiProvider == .ollama {
            if !model.ollamaReachable { return "Couldn't reach Ollama. Open it, then look again." }
            if model.ollamaModels.isEmpty { return "No models installed yet." }
            return nil
        }
        let note = modelChoices.first { $0.id == model.model }?.note
        if model.aiProvider == .dejaDo, let note {
            return note + " Runs on " + AICatalog.vendor(ofModel: model.model).name + "."
        }
        return note
    }

    /// A label on the left, its control on the right, an optional note under both.
    private func row<C: View>(_ title: String, note: String?, @ViewBuilder control: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 12) {
                Text(title).font(.ui(13))
                Spacer(minLength: 12)
                control().font(.ui(13))
            }
            if let note {
                Text(note)
                    .font(.ui(11))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 12)
    }

    private func toggle(_ title: String, isOn: Binding<Bool>, note: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle(title, isOn: isOn)
                .font(.ui(13))
            Text(note)
                .font(.ui(11))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 14)
    }
}


// MARK: - Suggestions

/// One quiet line offering something, with a link to accept and one to dismiss.
struct SuggestionLine: View {
    let text: String
    var accept: String?
    var accepted: () -> Void
    var dismiss: () -> Void

    init(text: String, accept: String?, accepted: @escaping () -> Void, dismiss: @escaping () -> Void) {
        self.text = text
        self.accept = accept
        self.accepted = accepted
        self.dismiss = dismiss
    }

    var body: some View {
        HStack(spacing: 12) {
            Text(text)
                .font(.ui(12))
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Spacer(minLength: 8)
            if let accept {
                Button(accept, action: accepted).buttonStyle(.plain).font(.ui(12, .medium))
                    .foregroundStyle(Brand.cobalt)
                Button("Not now", action: dismiss).buttonStyle(.plain).font(.ui(12))
                    .foregroundStyle(.secondary)
            } else {
                Button("Remove", action: dismiss).buttonStyle(.plain).font(.ui(12))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 10)
    }
}

// MARK: - Run history

struct HistoryView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let automationID: UUID
    @State private var records: [RunRecord] = []
    @State private var open: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Run history").font(.ui(17, .semibold))
                Spacer()
                Button("Done") { dismiss() }
                    .buttonStyle(PrimaryButtonStyle(compact: true))
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.bottom, 14)
            Divider()
            if records.isEmpty {
                Text("No runs yet.")
                    .font(.ui(13))
                    .foregroundStyle(.tertiary)
                    .padding(.vertical, 18)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(records) { r in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 10) {
                                Circle().fill(r.succeeded ? Brand.forest : Brand.red).frame(width: 6, height: 6)
                                Text(r.started.formatted(date: .abbreviated, time: .shortened)).font(.ui(13))
                                if let row = r.row, let rows = r.rows {
                                    Text("row \(row) of \(rows)").font(.ui(12)).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text(String(format: "%.1fs", r.duration)).font(.ui(12).monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                            Text(r.outcome).font(.ui(12)).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            if open == r.id {
                                ForEach(r.steps, id: \.index) { st in
                                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                                        Text("\(st.index + 1)").font(.ui(11).monospacedDigit())
                                            .foregroundStyle(.tertiary).frame(width: 20, alignment: .trailing)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(st.summary).font(.ui(12))
                                                .foregroundStyle(st.ran ? .primary : .tertiary)
                                            if let n = st.note {
                                                Text(n).font(.ui(11)).foregroundStyle(.secondary)
                                            }
                                        }
                                    }
                                    .padding(.leading, 16)
                                }
                                .padding(.top, 4)
                            }
                        }
                        .padding(.vertical, 10)
                        .contentShape(Rectangle())
                        .onTapGesture { open = open == r.id ? nil : r.id }
                        Divider()
                    }
                }
            }
        }
        .padding(26)
        .frame(width: 560, height: 520)
        .fontDesign(.default)
        .onAppear { records = model.history.load(automationID) }
    }
}

// MARK: - Schedule

struct ScheduleView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let automation: Automation
    @State private var schedule: Schedule
    @State private var time: Date

    init(automation: Automation) {
        self.automation = automation
        let s = automation.schedule ?? Schedule(on: true)
        _schedule = State(initialValue: s)
        _time = State(initialValue: Calendar.current.date(bySettingHour: s.hour, minute: s.minute, second: 0, of: Date()) ?? Date())
    }

    private var problem: String? { Schedule.problem(for: automation, values: schedule.values) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Run “\(automation.name)” on a schedule")
                .font(.ui(17, .semibold))
                .padding(.bottom, 16)
            Divider()

            Toggle("Run by itself", isOn: $schedule.on)
                .font(.ui(13))
                .padding(.vertical, 14)
            Divider()

            row("Repeat") {
                Picker("Repeat", selection: $schedule.repeats) {
                    ForEach(Schedule.Repeat.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .fixedSize()
            }
            Divider()
            row(schedule.repeats == .hourly ? "Starting at" : "At") {
                DatePicker("Time", selection: $time, displayedComponents: .hourAndMinute)
                    .labelsHidden()
                    .fixedSize()
            }
            if schedule.repeats == .hourly {
                Divider()
                row("Every") {
                    Stepper("\(schedule.everyHours) hour\(schedule.everyHours == 1 ? "" : "s")", value: $schedule.everyHours, in: 1...12)
                        .font(.ui(13))
                        .fixedSize()
                }
                Divider()
                row("Until") {
                    Stepper("\(schedule.untilHour):00", value: $schedule.untilHour, in: 0...23)
                        .font(.ui(13))
                        .fixedSize()
                }
            }

            if !automation.variableNames.isEmpty {
                Divider()
                Text("Nobody will be there to fill these in, so they're kept with the schedule.")
                    .font(.ui(11))
                    .foregroundStyle(.tertiary)
                    .padding(.top, 14)
                ForEach(automation.variableNames, id: \.self) { name in
                    row("{{\(name)}}") {
                        VStack(spacing: 3) {
                            TextField("value", text: Binding(
                                get: { schedule.values[name] ?? "" },
                                set: { schedule.values[name] = $0 }))
                                .textFieldStyle(.plain)
                                .multilineTextAlignment(.trailing)
                                .font(.ui(13))
                            Divider()
                        }
                        .frame(width: 200)
                    }
                }
            }

            Divider()
            VStack(alignment: .leading, spacing: 4) {
                if let problem, schedule.on {
                    Text(problem).foregroundStyle(Brand.amber)
                } else if schedule.on, let next = preview.next(after: Date(), calendar: .current) {
                    Text("Next run \(next.formatted(date: .abbreviated, time: .shortened)).")
                }
                Text("Runs while Deja Do is open and the screen is unlocked. A run missed while the Mac was asleep starts within the hour, or is noted in the run history.")
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(.ui(11))
            .padding(.vertical, 14)

            HStack {
                if automation.schedule != nil {
                    Button("Remove schedule") {
                        model.setSchedule(automation.id, nil)
                        dismiss()
                    }
                    .buttonStyle(QuietButtonStyle(compact: true))
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(QuietButtonStyle(compact: true))
                Button("Save") {
                    model.setSchedule(automation.id, preview)
                    dismiss()
                }
                .buttonStyle(PrimaryButtonStyle(compact: true))
                .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 6)
        }
        .padding(26)
        .frame(width: 460)
        .fontDesign(.default)
    }

    private var preview: Schedule {
        var s = schedule
        let c = Calendar.current.dateComponents([.hour, .minute], from: time)
        s.hour = c.hour ?? 9
        s.minute = c.minute ?? 0
        s.untilHour = max(s.untilHour, s.hour)
        return s
    }

    @ViewBuilder private func row<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        HStack {
            Text(title).font(.ui(13))
            Spacer()
            content()
        }
        .padding(.vertical, 10)
    }
}
