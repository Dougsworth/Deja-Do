import SwiftUI
import AppKit
@preconcurrency import DejaDoCore

// Built from type, whitespace and hairlines. One accent colour marks what is
// active; green and red only ever mean a run passed or failed.

extension Font {
    /// SF Pro Rounded: softer and friendlier than the default system face.
    static func rounded(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .rounded)
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
            .font(.rounded(compact ? 12 : 13, .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, compact ? 12 : 16)
            .padding(.vertical, compact ? 5 : 7)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.accentColor.opacity(configuration.isPressed ? 0.8 : 1))
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
            .font(.rounded(compact ? 12 : 13, .medium))
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
        .font(.rounded(11))
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
                .background(VisualEffect(material: .sidebar))
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
            .background(Color(nsColor: .textBackgroundColor).opacity(0.35))
        }
        .fontDesign(.rounded)
        .ignoresSafeArea(.container, edges: .top)
        .sheet(isPresented: $showSettings) {
            SettingsView().environmentObject(model)
        }
        .sheet(item: $model.pendingRun) { pending in
            VariablesSheet(pending: pending).environmentObject(model)
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
            // Room for the window controls.
            Color.clear.frame(height: 40)

            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.tertiary)
                TextField("Search tasks", text: $query)
                    .textFieldStyle(.plain)
                    .font(.rounded(13))
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 10)

            Divider().padding(.horizontal, 16)

            HStack {
                Text("Tasks")
                    .font(.rounded(11, .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(model.automations.count)")
                    .font(.rounded(11).monospacedDigit())
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
                            .font(.rounded(12))
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
                        Circle().fill(Color.red).frame(width: 7, height: 7)
                        Text(model.isRecording ? "Stop and save" : "New recording")
                            .font(.rounded(13, .medium))
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
                    .font(.rounded(13, selected ? .semibold : .regular))
                    .foregroundStyle(selected ? .primary : .secondary)
                    .lineLimit(1)
                Spacer(minLength: 6)
                Text(running ? "running" : Self.ago(automation.lastRun))
                    .font(.rounded(11).monospacedDigit())
                    .foregroundStyle(running ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.tertiary))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.primary.opacity(selected ? 0.08 : (hovering ? 0.04 : 0)))
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
        if running { return .accentColor }
        switch automation.lastSucceeded {
        case .some(true): return .green
        case .some(false): return .red
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
        HStack(spacing: 8) {
            Circle().fill(dot).frame(width: 6, height: 6)
            Text(text)
                .font(.rounded(11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 12)
            if model.runningID != nil {
                ShortcutHint(label: "Stop", keys: "Esc")
            } else if model.isRecording {
                ShortcutHint(label: "Save", keys: "⌘↩")
            }
        }
        .padding(.horizontal, Metrics.gutter)
        .frame(height: Metrics.statusHeight)
    }

    private var text: String {
        if model.isRecording { return "Recording · \(model.liveSteps.count) steps so far" }
        if let s = model.status { return s }
        if !model.permissionsReady { return "Waiting for permissions" }
        return "Ready"
    }

    private var dot: Color {
        if model.isRecording { return .red }
        if model.runningID != nil { return .accentColor }
        if let s = model.status, s != "Done." && !s.hasPrefix("Saved") { return .orange }
        return .green
    }
}

// MARK: - Automation detail

struct AutomationView: View {
    @EnvironmentObject var model: AppModel
    @Binding var automation: Automation
    /// The step whose settings are open. One at a time keeps the list calm.
    @State private var expanded: UUID?

    private var isRunning: Bool { model.runningID == automation.id }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HeaderBar {
                VStack(alignment: .leading, spacing: 3) {
                    TextField("Name", text: $automation.name)
                        .textFieldStyle(.plain)
                        .font(.rounded(17, .semibold))
                    meta
                }
            } actions: {
                if isRunning {
                    Button { model.stopRun() } label: {
                        Label("Stop", systemImage: "stop.fill").labelStyle(.titleAndIcon)
                    }
                    .buttonStyle(QuietButtonStyle(compact: true))
                } else {
                    Button { model.run(automation) } label: {
                        Label("Run", systemImage: "play.fill").labelStyle(.titleAndIcon)
                    }
                    .buttonStyle(PrimaryButtonStyle(compact: true))
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(model.runningID != nil || model.isRecording)
                }
                Menu {
                    Button("Run for each row of a spreadsheet…") { model.runForEachRow(automation) }
                    Divider()
                    Button("Duplicate") { model.duplicate(automation.id) }
                    Button("Export…") { model.export(automation.id) }
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

            List {
                ForEach($automation.steps) { $step in
                    let n = number(of: step)
                    StepRow(step: $step, number: n, state: state(for: n - 1), note: model.runNotes[step.id],
                            expanded: expanded == step.id) {
                        withAnimation(.easeOut(duration: 0.15)) { expanded = expanded == step.id ? nil : step.id }
                    }
                        .listRowSeparator(.visible)
                        .listRowInsets(EdgeInsets(top: 0, leading: Metrics.gutter - 8, bottom: 0, trailing: Metrics.gutter - 8))
                        .contextMenu {
                            Button("Add a 2 second wait after") { insertWait(after: step) }
                            Divider()
                            Button("Delete step", role: .destructive) { remove(step) }
                        }
                }
                .onMove { automation.steps.move(fromOffsets: $0, toOffset: $1) }
                .onDelete { automation.steps.remove(atOffsets: $0) }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
        }
    }

    /// One quiet line under the title: how long it is, when it last ran, what it fills in.
    private var meta: some View {
        var parts: [Text] = [Text("\(automation.steps.count) steps")]
        if let last = automation.lastRun {
            let when = last.formatted(.relative(presentation: .named))
            let took = automation.lastDuration.map { String(format: " in %.1fs", $0) } ?? ""
            if automation.lastSucceeded == false {
                parts.append(Text("failed \(when)").foregroundColor(.red))
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
                .foregroundColor(.accentColor))
        }
        let line = parts.dropFirst().reduce(parts[0]) { $0 + Text("  ·  ") + $1 }
        return line
            .font(.rounded(12))
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

    private func remove(_ step: Step) {
        automation.steps.removeAll { $0.id == step.id }
    }

    private func insertWait(after step: Step) {
        guard let i = automation.steps.firstIndex(where: { $0.id == step.id }) else { return }
        automation.steps.insert(Step(kind: .wait(seconds: 2)), at: i + 1)
    }
}

enum StepState { case idle, current, done }

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

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            ZStack {
                switch state {
                case .current:
                    ProgressView().controlSize(.mini)
                case .done:
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.green)
                case .idle:
                    Text(number.map(String.init) ?? "")
                        .font(.rounded(12, .medium).monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(width: 22, alignment: .trailing)

            VStack(alignment: .leading, spacing: 4) {
                Text(summary)
                    .font(.rounded(13, state == .current ? .semibold : .regular))
                    .foregroundStyle(dimmed || state == .done ? .secondary : .primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture { onTap?() }
                if let note {
                    Text(note)
                        .font(.rounded(11))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                editor()
            }

            if let app {
                Text(app)
                    .font(.rounded(12))
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

struct StepRow: View {
    @Binding var step: Step
    let number: Int
    let state: StepState
    var note: String? = nil
    /// Settings show only for the open step; the list itself stays one line per step.
    var expanded = false
    var toggle: () -> Void = {}

    var body: some View {
        StepLine(number: number, summary: step.summary, state: state, note: note,
                 onTap: hasSettings ? toggle : nil) {
            if expanded && hasSettings { editor }
        }
    }

    private var hasSettings: Bool {
        switch step.kind {
        case .type(_, _, let secret, _): return !secret
        case .wait: return true
        case .click, .key: return step.expect?.summary != nil
        case .activate: return false
        }
    }

    @ViewBuilder private var editor: some View {
        switch step.kind {
        case .type(_, _, let secret, _) where !secret:
            HStack(spacing: 18) {
                VStack(spacing: 3) {
                    TextField("Text to type", text: typedText)
                        .textFieldStyle(.plain)
                        .font(.rounded(12))
                        .disabled(askEachRun.wrappedValue)
                    Divider()
                }
                .frame(maxWidth: 300)
                Toggle("Ask each run", isOn: askEachRun)
                    .toggleStyle(.checkbox)
                    .font(.rounded(11))
            }
            .padding(.top, 6)
            Text("Type {{name}} anywhere to fill it in each run, or from a spreadsheet column.")
                .font(.rounded(11))
                .foregroundStyle(.tertiary)
                .padding(.bottom, 2)
        case .click, .key:
            if let line = step.expect?.summary {
                VStack(alignment: .leading, spacing: 6) {
                    Text(line)
                        .font(.rounded(12))
                        .foregroundStyle(.secondary)
                    HStack(spacing: 6) {
                        Text("If it doesn't match")
                            .font(.rounded(12))
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
        case .wait:
            Stepper(value: waitSeconds, in: 0.5...60, step: 0.5) {
                Text("\(waitSeconds.wrappedValue, specifier: "%g") seconds")
                    .font(.rounded(11))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: 200, alignment: .leading)
            .padding(.top, 2)
        default:
            EmptyView()
        }
    }

    private var typedText: Binding<String> {
        Binding(
            get: { if case .type(let t, _, _, _) = step.kind { return t }; return "" },
            set: { new in
                if case .type(_, let a, let s, let p) = step.kind {
                    step.kind = .type(text: new, askEachRun: a, secret: s, prompt: p)
                }
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
                        .fill(Color.red)
                        .frame(width: 8, height: 8)
                        .opacity(pulse ? 0.25 : 1)
                        .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: pulse)
                    Text("Recording").font(.rounded(17, .semibold))
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

            Text("Do the task the way you normally would. Every click, keystroke and app switch becomes a step. Passwords are never recorded.")
                .font(.rounded(13))
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
                            .font(.rounded(13))
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
                Text("Welcome").font(.rounded(17, .semibold))
            } actions: {
                EmptyView()
            }
            VStack(alignment: .leading, spacing: 12) {
                Text("Do it once.")
                    .font(.rounded(28, .semibold))
                Text("Record a boring task, like downloading a report, renaming it and emailing it. Deja Do saves every step and does the whole thing for you from then on. If a button moves or gets renamed, it finds it again.")
                    .font(.rounded(14))
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
                Text("Set up").font(.rounded(17, .semibold))
            } actions: {
                EmptyView()
            }
            VStack(alignment: .leading, spacing: 0) {
                Text("Two permissions first")
                    .font(.rounded(22, .semibold))
                Text("macOS has to let Deja Do press buttons in other apps, and notice your clicks and keys while you record. Nothing leaves your Mac.")
                    .font(.rounded(13))
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
                    .font(.rounded(12))
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
                .foregroundStyle(granted ? AnyShapeStyle(Color.green) : AnyShapeStyle(.tertiary))
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.rounded(13, .medium))
                Text(detail).font(.rounded(12)).foregroundStyle(.secondary)
            }
            Spacer()
            if granted {
                Text("On").font(.rounded(12)).foregroundStyle(.secondary)
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
                .font(.rounded(17, .semibold))
            Text("Fill these in for this run.")
                .font(.rounded(12))
                .foregroundStyle(.secondary)
                .padding(.top, 4)
                .padding(.bottom, 16)

            Divider()
            ForEach(pending.names, id: \.self) { key in
                VStack(alignment: .leading, spacing: 6) {
                    Text(key).font(.rounded(12, .medium)).foregroundStyle(.secondary)
                    TextField("", text: binding(key))
                        .textFieldStyle(.plain)
                        .font(.rounded(13))
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
                .font(.rounded(12))
                .foregroundStyle(Color.accentColor)
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
        .fontDesign(.rounded)
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
                .font(.rounded(17, .semibold))
                .padding(.bottom, 16)

            Divider()

            Toggle("Ask AI when a button can't be found with confidence", isOn: $model.aiEnabled)
                .font(.rounded(13))
                .padding(.vertical, 14)

            Divider()

            toggle("Check that each step worked", isOn: $model.checkSteps,
                   note: "After each click or key press, looks for what changed when you recorded it, like the name you clicked showing up in the header. Waits, tries once more if nothing happened, then stops.")

            Divider()

            toggle("Use the screen when an app doesn't describe its buttons", isOn: $model.useVision,
                   note: "For canvas apps, games and virtual machines. Keeps a small picture and the text around each click, read on your Mac and never sent anywhere.")
            if model.useVision && !model.hasScreenRecording {
                HStack {
                    Text("Needs Screen Recording permission.")
                        .font(.rounded(11))
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

            HStack {
                Text("Esc stops a running task.")
                    .font(.rounded(12))
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
        .fontDesign(.rounded)
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
                Text(title).font(.rounded(13))
                Spacer(minLength: 12)
                control().font(.rounded(13))
            }
            if let note {
                Text(note)
                    .font(.rounded(11))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 12)
    }

    private func toggle(_ title: String, isOn: Binding<Bool>, note: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle(title, isOn: isOn)
                .font(.rounded(13))
            Text(note)
                .font(.rounded(11))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 14)
    }
}
