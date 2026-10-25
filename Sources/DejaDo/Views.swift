import SwiftUI
import AppKit
import DejaDoCore

// Layout is built from type, whitespace and hairlines: no tinted cards,
// no badges, no boxed icons. One accent colour marks what is active.

enum Metrics {
    static let sidebarWidth: CGFloat = 248
    static let gutter: CGFloat = 40
    static let titleTop: CGFloat = 46
}

struct MainView: View {
    @EnvironmentObject var model: AppModel
    @State private var showSettings = false

    var body: some View {
        HStack(spacing: 0) {
            Sidebar(showSettings: $showSettings)
                .frame(width: Metrics.sidebarWidth)
            Divider()
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
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .ignoresSafeArea(.container, edges: .top)
        .sheet(isPresented: $showSettings) {
            SettingsView().environmentObject(model)
        }
    }
}

// MARK: - Sidebar

struct Sidebar: View {
    @EnvironmentObject var model: AppModel
    @Binding var showSettings: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Deja Do")
                .font(.system(size: 13, weight: .semibold))
                .padding(.horizontal, 20)
                .padding(.top, Metrics.titleTop)
                .padding(.bottom, 16)

            if model.automations.isEmpty {
                Text("Your recorded tasks will show up here.")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 20)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(model.automations) { a in
                        SidebarRow(automation: a)
                    }
                }
            }

            Divider()

            HStack(spacing: 0) {
                Button {
                    if model.isRecording { model.stopRecording() } else { model.startRecording() }
                } label: {
                    HStack(spacing: 8) {
                        Circle()
                            .fill(Color.red)
                            .frame(width: 7, height: 7)
                        Text(model.isRecording ? "Stop and save" : "Record a task")
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(model.runningID != nil)
                .keyboardShortcut("r", modifiers: .command)

                Spacer()

                Button {
                    showSettings = true
                } label: {
                    Image(systemName: "gearshape")
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Settings")
            }
            .font(.system(size: 13))
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
    }
}

struct SidebarRow: View {
    @EnvironmentObject var model: AppModel
    let automation: Automation

    private var selected: Bool { model.selection == automation.id && !model.isRecording }
    private var running: Bool { model.runningID == automation.id }

    var body: some View {
        Button {
            model.selection = automation.id
        } label: {
            HStack(spacing: 0) {
                Rectangle()
                    .fill(selected ? Color.accentColor : .clear)
                    .frame(width: 2)
                VStack(alignment: .leading, spacing: 3) {
                    Text(automation.name)
                        .font(.system(size: 13, weight: selected ? .semibold : .regular))
                        .foregroundStyle(selected ? .primary : .secondary)
                        .lineLimit(1)
                    Text(running ? "Running step \(model.runningStep + 1)" : "\(automation.steps.count) steps")
                        .font(.system(size: 11))
                        .foregroundStyle(running ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.tertiary))
                }
                .padding(.leading, 18)
                .padding(.vertical, 8)
                Spacer(minLength: 8)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Run") { model.run(automation) }
            Button("Duplicate") { model.duplicate(automation.id) }
            Divider()
            Button("Delete", role: .destructive) { model.delete(automation.id) }
        }
    }
}

// MARK: - Automation detail

struct AutomationView: View {
    @EnvironmentObject var model: AppModel
    @Binding var automation: Automation

    private var isRunning: Bool { model.runningID == automation.id }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                TextField("Name", text: $automation.name)
                    .textFieldStyle(.plain)
                    .font(.system(size: 26, weight: .semibold))

                Text(meta)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)

                HStack(spacing: 14) {
                    if isRunning {
                        Button("Stop") { model.stopRun() }
                            .controlSize(.large)
                        Text("Step \(model.runningStep + 1) of \(automation.steps.count). Esc also stops it.")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    } else {
                        Button("Run") { model.run(automation) }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.large)
                            .keyboardShortcut(.return, modifiers: .command)
                            .disabled(model.runningID != nil || model.isRecording)
                        Text("⌘↩")
                            .font(.system(size: 12))
                            .foregroundStyle(.tertiary)
                    }
                }
                .padding(.top, 10)

                if let status = model.status, isRunning || model.runningID == nil {
                    Text(status)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                        .padding(.top, 2)
                }
            }
            .padding(.horizontal, Metrics.gutter)
            .padding(.top, Metrics.titleTop)
            .padding(.bottom, 22)

            Divider()

            List {
                ForEach($automation.steps) { $step in
                    let n = number(of: step)
                    StepRow(step: $step, number: n, isCurrent: isRunning && model.runningStep == n - 1)
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

    private var meta: String {
        var parts = ["\(automation.steps.count) steps"]
        parts.append(automation.runs == 0 ? "not run yet" : (automation.runs == 1 ? "ran once" : "ran \(automation.runs) times"))
        if automation.repairs > 0 {
            parts.append("AI fixed \(automation.repairs) step\(automation.repairs == 1 ? "" : "s")")
        }
        if let last = automation.lastRun {
            parts.append("last run \(last.formatted(.relative(presentation: .named)))")
        }
        return parts.joined(separator: "  ·  ")
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

/// One numbered line in a step list. Used for saved and live steps alike.
struct StepLine<Editor: View>: View {
    let number: Int?
    let symbol: String
    let summary: String
    let detail: String?
    var isCurrent = false
    var dimmed = false
    @ViewBuilder var editor: () -> Editor

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            Text(number.map(String.init) ?? "")
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(isCurrent ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.tertiary))
                .frame(width: 22, alignment: .trailing)
            Image(systemName: symbol)
                .font(.system(size: 11))
                .foregroundStyle(isCurrent ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.tertiary))
                .frame(width: 14)
            VStack(alignment: .leading, spacing: 4) {
                Text(summary)
                    .font(.system(size: 13, weight: isCurrent ? .semibold : .regular))
                    .foregroundStyle(dimmed ? .secondary : .primary)
                if let detail {
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                editor()
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 11)
    }
}

struct StepRow: View {
    @Binding var step: Step
    let number: Int
    let isCurrent: Bool

    var body: some View {
        StepLine(number: number, symbol: step.symbol, summary: step.summary, detail: step.detail,
                 isCurrent: isCurrent) { editor }
    }

    @ViewBuilder private var editor: some View {
        switch step.kind {
        case .type(_, _, let secret, _) where !secret:
            HStack(spacing: 18) {
                VStack(spacing: 3) {
                    TextField("Text to type", text: typedText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                        .disabled(askEachRun.wrappedValue)
                    Divider()
                }
                .frame(maxWidth: 320)
                Toggle("Ask each run", isOn: askEachRun)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 11))
            }
            .padding(.top, 4)
        case .wait:
            Stepper(value: waitSeconds, in: 0.5...60, step: 0.5) {
                Text("\(waitSeconds.wrappedValue, specifier: "%g") seconds")
                    .font(.system(size: 11))
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
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    Circle()
                        .fill(Color.red)
                        .frame(width: 9, height: 9)
                        .opacity(pulse ? 0.25 : 1)
                        .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: pulse)
                    Text("Recording")
                        .font(.system(size: 26, weight: .semibold))
                }
                Text("Do the task the way you normally would. Every click, keystroke and app switch becomes a step. Passwords are never recorded.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 520, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 18) {
                    Button("Stop and Save") { model.stopRecording() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .keyboardShortcut(.return, modifiers: .command)
                    Button("Discard") { model.discardRecording() }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 10)
            }
            .padding(.horizontal, Metrics.gutter)
            .padding(.top, Metrics.titleTop)
            .padding(.bottom, 22)
            .onAppear { pulse = true }

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(model.liveSteps.enumerated()), id: \.element.id) { i, step in
                        StepLine(number: i + 1, symbol: step.symbol, summary: step.summary, detail: step.detail) { EmptyView() }
                        Divider()
                    }
                    if !model.pendingText.isEmpty {
                        StepLine(number: nil, symbol: "character.cursor.ibeam",
                                 summary: "Typing “\(model.pendingText)”", detail: nil, dimmed: true) { EmptyView() }
                    }
                    if model.liveSteps.isEmpty && model.pendingText.isEmpty {
                        Text("Waiting for your first click…")
                            .font(.system(size: 13))
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
        VStack(alignment: .leading, spacing: 12) {
            Text("Do it once.")
                .font(.system(size: 30, weight: .semibold))
            Text("Record a boring task, like downloading a report, renaming it and emailing it. Deja Do saves every step and does the whole thing for you from then on. If a button moves or gets renamed, it finds it again.")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .frame(maxWidth: 480, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 14) {
                Button("Record a task") { model.startRecording() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                Text("⌘R")
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
            }
            .padding(.top, 10)
        }
        .padding(.horizontal, Metrics.gutter)
        .padding(.top, Metrics.titleTop)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

struct PermissionsView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Two permissions first")
                .font(.system(size: 26, weight: .semibold))
            Text("macOS has to let Deja Do press buttons in other apps, and notice your clicks and keys while you record. Nothing leaves your Mac.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .frame(maxWidth: 520, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 8)
                .padding(.bottom, 26)

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
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)
                .padding(.top, 18)
        }
        .frame(maxWidth: 560, alignment: .leading)
        .padding(.horizontal, Metrics.gutter)
        .padding(.top, Metrics.titleTop)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func row(_ title: String, detail: String, granted: Bool, action: @escaping () -> Void) -> some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: granted ? "checkmark" : "circle")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(granted ? AnyShapeStyle(Color.green) : AnyShapeStyle(.tertiary))
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .medium))
                Text(detail).font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Spacer()
            if granted {
                Text("On").font(.system(size: 12)).foregroundStyle(.secondary)
            } else {
                Button("Open Settings", action: action)
            }
        }
        .padding(.vertical, 14)
    }
}

// MARK: - Settings

struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Settings")
                .font(.system(size: 20, weight: .semibold))
                .padding(.bottom, 18)

            Divider()

            Toggle("Ask AI when a button can't be found with confidence", isOn: $model.aiEnabled)
                .font(.system(size: 13))
                .padding(.vertical, 14)

            Divider()

            field("Anthropic API key",
                  note: "Kept in your keychain. Only a text list of the window's buttons and labels is sent, never your screen or what you typed.") {
                SecureField("sk-ant-…", text: $model.apiKey)
            }
            .disabled(!model.aiEnabled)
            .opacity(model.aiEnabled ? 1 : 0.5)

            Divider()

            field("Model", note: nil) {
                TextField(AppModel.defaultModel, text: $model.model)
            }
            .disabled(!model.aiEnabled)
            .opacity(model.aiEnabled ? 1 : 0.5)

            Divider()

            HStack {
                Text("Esc stops a running task.")
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 18)
        }
        .padding(28)
        .frame(width: 460)
    }

    private func field<F: View>(_ title: String, note: String?, @ViewBuilder input: () -> F) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
            input()
                .textFieldStyle(.plain)
                .font(.system(size: 13))
            if let note {
                Text(note)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 14)
    }
}
