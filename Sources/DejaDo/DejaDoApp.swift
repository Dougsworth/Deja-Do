import SwiftUI
import AppKit
import DejaDoCore

@main
struct DejaDoApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            MenuContent()
                .environmentObject(model)
        } label: {
            MenuBarLabel(model: model)
        }

        Window("Deja Do", id: "main") {
            MainView()
                .environmentObject(model)
                .frame(minWidth: 720, minHeight: 460)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 900, height: 600)
    }
}

/// The menu bar icon. It also opens the main window once at launch: a menu
/// bar app shows no window or Dock icon, and on a crowded menu bar the icon
/// itself can be hidden behind the notch, so launching would look like nothing.
struct MenuBarLabel: View {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow
    private static var openedAtLaunch = false

    var body: some View {
        Image(systemName: icon)
            .task {
                guard !Self.openedAtLaunch else { return }
                Self.openedAtLaunch = true
                // Opening in the same instant the menu bar item appears can
                // leave the window blank, so come forward first and give the
                // scene a moment to finish setting up.
                NSApp.activate(ignoringOtherApps: true)
                try? await Task.sleep(nanoseconds: 400_000_000)
                openWindow(id: "main")
            }
    }

    private var icon: String {
        if model.isRecording { return "record.circle" }
        if model.runningID != nil { return "play.circle" }
        return "repeat"
    }
}

struct MenuContent: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if model.isRecording {
            Text("Recording · \(model.liveSteps.count) steps")
            Button("Stop and Save") {
                model.stopRecording()
                openMain()
            }
            .keyboardShortcut("s")
            Button("Discard Recording") { model.discardRecording() }
        } else if model.runningID != nil {
            Text("Running step \(model.runningStep + 1) · press Esc to stop")
            Button("Stop") { model.stopRun() }
        } else {
            Button("Record a Task") {
                if !model.startRecording() { openMain() }
            }
            .keyboardShortcut("r")
        }

        if !model.automations.isEmpty && !model.isRecording {
            Divider()
            ForEach(model.automations.prefix(8)) { a in
                Button("Run “\(a.name)”") { model.run(a) }
                    .disabled(model.runningID != nil)
            }
        }

        if let status = model.status {
            Divider()
            Text(status)
        }

        Divider()
        Button("Open Deja Do") { openMain() }
            .keyboardShortcut("o")
        Button("Quit Deja Do") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }

    private func openMain() {
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
    }
}
