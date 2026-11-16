import AppKit
import SwiftUI
import DownCore

// Strings here are `String(localized:…, bundle: .module)` passed to SwiftUI's String initializers.
// A bare literal, as in `Text("…")` or `Toggle("…", isOn:)`, would be looked up in Bundle.main, not in
// DownUI's catalog, and never translated. Untranslated text uses Text(verbatim:).

/// SwiftUI settings: reads AppViewModel state, writes through `send`.
struct SettingsView: View {
    let app: AppViewModel

    var body: some View {
        TabView {
            GeneralPane(app: app)
                .tabItem {
                    Label(String(localized: "General", bundle: .module, comment: "Settings tab"), systemImage: "gearshape")
                }
            ShortcutsPane(app: app)
                .tabItem {
                    Label(String(localized: "Shortcuts", bundle: .module, comment: "Settings tab: keyboard shortcuts"),
                          systemImage: "keyboard")
                }
            AdvancedPane(app: app)
                .tabItem {
                    Label(String(localized: "Advanced", bundle: .module, comment: "Settings tab"), systemImage: "wrench.and.screwdriver")
                }
        }
        .frame(width: 520)
        .scenePadding()
    }
}

private struct GeneralPane: View {
    let app: AppViewModel

    var body: some View {
        Form {
            Picker(String(localized: "Appearance", bundle: .module, comment: "Settings, General: light/dark theme picker"),
                   selection: Binding(get: { app.settings.theme }, set: { app.send(.setTheme($0)) })) {
                Text(String(localized: "System", bundle: .module, comment: "Settings, Appearance: follow the system theme"))
                    .tag(Theme.system)
                Text(String(localized: "Light", bundle: .module, comment: "Settings, Appearance: light theme")).tag(Theme.light)
                Text(String(localized: "Dark", bundle: .module, comment: "Settings, Appearance: dark theme")).tag(Theme.dark)
            }
            .pickerStyle(.segmented)

            Toggle(String(localized: "Show hidden files", bundle: .module, comment: "Settings, General: checkbox"),
                   isOn: Binding(get: { app.settings.showHidden }, set: { app.send(.setShowHidden($0)) }))
            Toggle(String(localized: "Sort folders before files", bundle: .module, comment: "Settings, General: checkbox"),
                   isOn: Binding(get: { app.settings.sort.foldersFirst }, set: { v in
                       var s = app.settings.sort
                       s.foldersFirst = v
                       app.send(.setSort(s))
                   }))

            Picker(String(localized: "Open in Terminal uses", bundle: .module,
                          comment: "Settings, General: picker for the terminal app; followed by app names"),
                   selection: Binding(get: { app.settings.terminalBundleID ?? "" },
                                      set: { app.send(.setTerminal($0.isEmpty ? nil : $0)) })) {
                Text(String(localized: "Automatic", bundle: .module,
                            comment: "Settings, Open in Terminal uses: pick the first installed terminal"))
                    .tag("")
                ForEach(app.env.workspace.installedTerminals()) { t in
                    Text(verbatim: t.name).tag(t.bundleID)  // product names
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct ShortcutsPane: View {
    let app: AppViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(String(localized: """
                        GNOME Files shortcuts, translated for macOS (Ctrl → ⌘, Alt → ⌥). \
                        Overrides are stored in settings.json under “shortcutOverrides”.
                        """, bundle: .module,
                        comment: "Settings, Shortcuts: intro. Keep settings.json and shortcutOverrides untranslated"))
                .font(.callout)
                .foregroundStyle(.secondary)
            Text(String(localized: """
                        In the file list: Home/End (fn←/fn→) jump to the first/last item, \
                        Page Up/Down (fn↑/fn↓) move by a screenful. Hold ⇧ to extend the selection.
                        """, bundle: .module,
                        comment: "Settings, Shortcuts: explains the navigation keys. Home, End, Page Up and Page Down are key names"))
                .font(.callout)
                .foregroundStyle(.secondary)
            List(Command.allCases.filter { $0.tabIndex == nil || $0 == .tab1 }, id: \.self) { command in
                HStack {
                    Text(command == .tab1
                         ? String(localized: "Go to Tab 1…9", bundle: .module,
                                  comment: "Settings, Shortcuts: one row for the Go to Tab 1 to 9 commands")
                         : command.title)
                    Spacer()
                    Text(verbatim: app.keybindings.combos(for: command).map(\.displayDescription).joined(separator: "  "))
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
                Toggle(String(localized: "Enable Debug Console", bundle: .module, comment: "Settings, Advanced: checkbox"),
                       isOn: Binding(get: { app.settings.debugConsoleEnabled }, set: { app.send(.setDebugConsoleEnabled($0)) }))
                Text(String(localized: "Adds View → Debug Console (⌥⌘J) with live logs, tab state and performance timings.",
                            bundle: .module,
                            comment: "Settings, Advanced: caption under Enable Debug Console. View → Debug Console is a menu path"))
                    .font(.caption).foregroundStyle(.secondary)
                Toggle(String(localized: "Verbose logging", bundle: .module, comment: "Settings, Advanced: checkbox"),
                       isOn: Binding(get: { app.settings.verboseLogging }, set: { app.send(.setVerboseLogging($0)) }))
                if app.settings.verboseLogging {
                    LabeledContent(String(localized: "Trace categories", bundle: .module,
                                          comment: "Settings, Advanced: label before the log category toggles")) {
                        HStack {
                            ForEach(LogCategory.allCases, id: \.self) { c in
                                // Category names are log identifiers, not translated.
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
                Text(String(localized: "Debugging", bundle: .module, comment: "Settings, Advanced: section header"))
            }
            Section {
                Toggle(String(localized: "Write logs to ~/Library/Logs/Down", bundle: .module,
                              comment: "Settings, Advanced: checkbox. Keep the path as is"),
                       isOn: Binding(get: { app.settings.fileLogging }, set: { app.send(.setFileLogging($0)) }))
                Toggle(String(localized: "Anonymize file names in copied logs and diagnostics", bundle: .module,
                              comment: "Settings, Advanced: checkbox"),
                       isOn: Binding(get: { app.settings.anonymizeExports }, set: { app.send(.setAnonymizeExports($0)) }))
            } header: {
                Text(String(localized: "Logs", bundle: .module, comment: "Settings, Advanced: section header"))
            }
            if app.debugSession {
                Text(String(localized: "Started with --debug: console and verbose logging are on for this session.", bundle: .module,
                            comment: "Settings, Advanced: shown when launched with the --debug option (keep --debug as is)"))
                    .font(.caption).foregroundStyle(.orange)
            }
        }
        .formStyle(.grouped)
    }
}

@MainActor
final class SettingsWindowController: NSWindowController {
    init(app: AppViewModel) {
        let hosting = NSHostingController(rootView: SettingsView(app: app))
        let window = NSWindow(contentViewController: hosting)
        window.title = String(localized: "Down Settings", bundle: .module, comment: "Settings window title")
        window.styleMask = [.titled, .closable]
        window.setFrameAutosaveName("DownSettings")
        super.init(window: window)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
}
