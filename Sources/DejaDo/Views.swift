import SwiftUI
import AppKit
import DejaDoCore

struct MainView: View {
    @EnvironmentObject var model: AppModel
    @State private var showSettings = false

    var body: some View {
        NavigationSplitView {
            List(selection: $model.selection) {
                ForEach(model.automations) { a in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(a.name).lineLimit(1)
                        Text("\(a.steps.count) steps").font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 3)
                    .tag(a.id)
                    .contextMenu {
                        Button("Run") { model.run(a) }
                        Button("Duplicate") { model.duplicate(a.id) }
                        Divider()
                        Button("Delete", role: .destructive) { model.delete(a.id) }
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 230)
            .safeAreaInset(edge: .bottom) {
                HStack {
                    Button {
                        showSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Settings")
                    Spacer()
                }
                .padding(12)
            }
        } detail: {
            VStack(alignment: .leading, spacing: 0) {
                if !model.permissionsReady {
                    PermissionsView()
                    Divider()
                }
                if model.isRecording {
                    RecordingView()
                } else if let id = model.selection, let binding = model.binding(for: id) {
                    AutomationView(automation: binding)
                        .id(id)
                } else {
                    EmptyStateView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .toolbar {
            ToolbarItem {
                if model.isRecording {
                    Button {
                        model.stopRecording()
                    } label: {
                        Label("Stop and Save", systemImage: "stop.circle")
                    }
                } else {
                    Button {
                        model.startRecording()
                    } label: {
                        Label("Record", systemImage: "record.circle")
                    }
                    .disabled(model.runningID != nil)
                    .help("Record a task")
                }
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView().environmentObject(model)
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
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    TextField("Name", text: $automation.name)
                        .textFieldStyle(.plain)
                        .font(.system(size: 22, weight: .semibold))
                    Spacer()
                    if isRunning {
                        Button("Stop") { model.stopRun() }
                    } else {
                        Button("Run") { model.run(automation) }
                            .keyboardShortcut(.return, modifiers: .command)
                            .disabled(model.runningID != nil || model.isRecording)
                    }
                }
                Text(meta)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if let status = model.status, isRunning || model.runningID == nil {
                    Text(status)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }
            }
            .padding(.horizontal, 28)
            .padding(.top, 24)
            .padding(.bottom, 16)

            Divider()

            List {
                ForEach($automation.steps) { $step in
                    StepRow(step: $step,
                            number: number(of: step),
                            isCurrent: isRunning && model.runningStep == number(of: step) - 1)
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
        }
    }

    private var meta: String {
        var parts = ["\(automation.steps.count) steps"]
        parts.append(automation.runs == 1 ? "ran once" : "ran \(automation.runs) times")
        if automation.repairs > 0 {
            parts.append("AI fixed \(automation.repairs) step\(automation.repairs == 1 ? "" : "s")")
        }
        if let last = automation.lastRun {
            parts.append("last run \(last.formatted(.relative(presentation: .named)))")
        }
        return parts.joined(separator: " · ")
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

struct StepRow: View {
    @Binding var step: Step
    let number: Int
    let isCurrent: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            Text("\(number)")
                .font(.system(.callout, design: .monospaced))
                .foregroundStyle(isCurrent ? Color.accentColor : .secondary)
                .frame(width: 26, alignment: .trailing)
            Image(systemName: step.symbol)
                .foregroundStyle(isCurrent ? Color.accentColor : .secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 4) {
                Text(step.summary)
                    .fontWeight(isCurrent ? .semibold : .regular)
                if let detail = step.detail {
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
                editor
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 6)
    }

    @ViewBuilder private var editor: some View {
        switch step.kind {
        case .type(_, _, let secret, _) where !secret:
            HStack(spacing: 16) {
                TextField("Text", text: typedText)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 340)
                    .disabled(askEachRun.wrappedValue)
                Toggle("Ask each run", isOn: askEachRun)
                    .toggleStyle(.checkbox)
                    .font(.caption)
            }
        case .wait:
            Stepper(value: waitSeconds, in: 0.5...60, step: 0.5) {
                Text("\(waitSeconds.wrappedValue.formatted()) seconds").font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: 200, alignment: .leading)
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

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Circle().fill(Color.red).frame(width: 8, height: 8)
                    Text("Recording").font(.system(size: 22, weight: .semibold))
                }
                Text("Do the task the way you normally would. Every click, keystroke and app switch is saved as a step. Passwords are never recorded.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 16) {
                    Button("Stop and Save") { model.stopRecording() }
                        .keyboardShortcut(.return, modifiers: .command)
                    Button("Discard") { model.discardRecording() }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 6)
            }
            .padding(.horizontal, 28)
            .padding(.top, 24)
            .padding(.bottom, 16)

            Divider()

            List {
                ForEach(Array(model.liveSteps.enumerated()), id: \.element.id) { i, step in
                    HStack(alignment: .firstTextBaseline, spacing: 14) {
                        Text("\(i + 1)").font(.system(.callout, design: .monospaced)).foregroundStyle(.secondary)
                            .frame(width: 26, alignment: .trailing)
                        Image(systemName: step.symbol).foregroundStyle(.secondary).frame(width: 18)
                        Text(step.summary)
                    }
                    .padding(.vertical, 4)
                }
                if !model.pendingText.isEmpty {
                    HStack(alignment: .firstTextBaseline, spacing: 14) {
                        Text("").frame(width: 26)
                        Image(systemName: "character.cursor.ibeam").foregroundStyle(.secondary).frame(width: 18)
                        Text("Typing “\(model.pendingText)”").foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                }
            }
            .listStyle(.plain)
        }
    }
}

// MARK: - Empty state and permissions

struct EmptyStateView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Do it once.").font(.system(size: 28, weight: .semibold))
            Text("Record a boring task, like downloading a report, renaming it and emailing it. Deja Do saves every step and repeats the whole thing for you. If a button moves or gets renamed later, it finds it again, and asks AI only when it isn't sure.")
                .foregroundStyle(.secondary)
                .frame(maxWidth: 460, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            Text("Press Record in the toolbar, or use the ↻ menu in the menu bar.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.top, 6)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

struct PermissionsView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Two permissions first").font(.headline)
            Text("macOS has to let Deja Do see and press buttons in other apps, and notice your clicks and keys while you record.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            row("Accessibility", detail: "Find and press buttons when replaying", granted: model.hasAccessibility) {
                Permissions.requestAccessibility()
                Permissions.openAccessibilitySettings()
            }
            row("Input Monitoring", detail: "Notice clicks and typing while recording", granted: model.hasInputMonitoring) {
                Permissions.requestInputMonitoring()
                Permissions.openInputMonitoringSettings()
            }
            Text("After switching them on you may need to quit and reopen Deja Do.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 20)
    }

    private func row(_ title: String, detail: String, granted: Bool, action: @escaping () -> Void) -> some View {
        HStack(spacing: 12) {
            Image(systemName: granted ? "checkmark.circle" : "circle")
                .foregroundStyle(granted ? Color.green : .secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if !granted {
                Button("Open Settings", action: action)
            }
        }
        .frame(maxWidth: 520)
    }
}

// MARK: - Settings

struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Settings").font(.system(size: 20, weight: .semibold))

            Toggle("Ask AI when a button can't be found with confidence", isOn: $model.aiEnabled)

            VStack(alignment: .leading, spacing: 6) {
                Text("Anthropic API key").font(.callout)
                SecureField("sk-ant-…", text: $model.apiKey)
                    .textFieldStyle(.roundedBorder)
                Text("Stored in your keychain. Only a list of the window's buttons and labels is sent, never your screen or what you typed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .disabled(!model.aiEnabled)

            VStack(alignment: .leading, spacing: 6) {
                Text("Model").font(.callout)
                TextField(AppModel.defaultModel, text: $model.model)
                    .textFieldStyle(.roundedBorder)
            }
            .disabled(!model.aiEnabled)

            Divider()

            HStack {
                Text("Esc stops a running automation.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 440)
    }
}
