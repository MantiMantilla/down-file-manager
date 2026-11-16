import AppKit
import SwiftUI
import DownCore

/// SwiftUI settings: reads AppViewModel state, writes through `send`.
struct SettingsView: View {
    let app: AppViewModel

    var body: some View {
        TabView {
            GeneralPane(app: app)
                .tabItem { Label("General", systemImage: "gearshape") }
            ShortcutsPane(app: app)
                .tabItem { Label("Shortcuts", systemImage: "keyboard") }
            AdvancedPane(app: app)
                .tabItem { Label("Advanced", systemImage: "wrench.and.screwdriver") }
        }
        // An explicit height: the panes are grouped Forms, which scroll and so have no height of their own
        // (sized from them, the window opened about 100 pt tall). Tall enough for the Shortcuts pane,
        // which doesn't scroll; SettingsWindowTests checks that it fits.
        .frame(width: 520, height: 460)
        .scenePadding()
    }
}

private struct GeneralPane: View {
    let app: AppViewModel

    var body: some View {
        Form {
            Picker("Appearance", selection: Binding(get: { app.settings.theme }, set: { app.send(.setTheme($0)) })) {
                Text("System").tag(Theme.system)
                Text("Light").tag(Theme.light)
                Text("Dark").tag(Theme.dark)
            }
            .pickerStyle(.segmented)

            Toggle("Show hidden files", isOn: Binding(get: { app.settings.showHidden }, set: { app.send(.setShowHidden($0)) }))
            Toggle("Sort folders before files", isOn: Binding(get: { app.settings.sort.foldersFirst }, set: { v in
                var s = app.settings.sort
                s.foldersFirst = v
                app.send(.setSort(s))
            }))

            Picker("Open in Terminal uses", selection: Binding(get: { app.settings.terminalBundleID ?? "" },
                                                               set: { app.send(.setTerminal($0.isEmpty ? nil : $0)) })) {
                Text("Automatic").tag("")
                ForEach(app.env.workspace.installedTerminals()) { t in
                    Text(t.name).tag(t.bundleID)
                }
            }
        }
        .formStyle(.grouped)
    }
}

struct ShortcutsPane: View {
    let app: AppViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("GNOME Files shortcuts, translated for macOS (Ctrl → ⌘, Alt → ⌥). Overrides are stored in settings.json under “shortcutOverrides”.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Text("In the file list: Home/End (fn←/fn→) jump to the first/last item, Page Up/Down (fn↑/fn↓) move by a screenful. Hold ⇧ to extend the selection.")
                .font(.callout)
                .foregroundStyle(.secondary)
            List(Command.allCases.filter { $0.tabIndex == nil || $0 == .tab1 }, id: \.self) { command in
                HStack {
                    Text(command == .tab1 ? "Go to Tab 1…9" : command.title)
                    Spacer()
                    Text(app.keybindings.combos(for: command).map(\.description).joined(separator: "  "))
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(height: 320)
        }
    }
}

private struct AdvancedPane: View {
    let app: AppViewModel

    var body: some View {
        Form {
            Section {
                Toggle("Enable Debug Console", isOn: Binding(get: { app.settings.debugConsoleEnabled },
                                                             set: { app.send(.setDebugConsoleEnabled($0)) }))
                Text("Adds View → Debug Console (⌥⌘J) with live logs, tab state and performance timings.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Verbose logging", isOn: Binding(get: { app.settings.verboseLogging },
                                                        set: { app.send(.setVerboseLogging($0)) }))
                if app.settings.verboseLogging {
                    LabeledContent("Trace categories") {
                        HStack {
                            ForEach(LogCategory.allCases, id: \.self) { c in
                                Toggle(c.rawValue, isOn: Binding(get: { app.settings.verboseCategories.contains(c) }, set: { on in
                                    var set = app.settings.verboseCategories
                                    if on { set.insert(c) } else { set.remove(c) }
                                    app.send(.setVerboseCategories(set))
                                }))
                                .toggleStyle(.button)
                                .controlSize(.small)
                            }
                        }
                    }
                }
            } header: {
                Text("Debugging")
            }
            Section {
                Toggle("Write logs to ~/Library/Logs/Down", isOn: Binding(get: { app.settings.fileLogging },
                                                                          set: { app.send(.setFileLogging($0)) }))
                Toggle("Anonymize file names in copied logs and diagnostics",
                       isOn: Binding(get: { app.settings.anonymizeExports }, set: { app.send(.setAnonymizeExports($0)) }))
            } header: {
                Text("Logs")
            }
            if app.debugSession {
                Text("Started with --debug: console and verbose logging are on for this session.")
                    .font(.caption).foregroundStyle(.orange)
            }
        }
        .formStyle(.grouped)
    }
}

@MainActor
final class SettingsWindowController: NSWindowController {
    init(app: AppViewModel) {
        // The hosting controller sizes the window from SettingsView, which sets its own size.
        let hosting = NSHostingController(rootView: SettingsView(app: app))
        let window = NSWindow(contentViewController: hosting)
        window.title = "Down Settings"
        window.styleMask = [.titled, .closable]
        // No frame autosave: showSettings() centers the window when it's created, and the size comes from
        // SettingsView. (Builds before this saved a ~100 pt tall frame as "DownSettings"; it's now ignored.)
        super.init(window: window)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
}
