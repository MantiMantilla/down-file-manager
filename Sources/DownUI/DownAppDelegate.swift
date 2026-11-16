import AppKit
import DownCore

/// Composition root: wires logging, settings, the live environment and windows together.
@MainActor
public final class DownAppDelegate: NSObject, NSApplicationDelegate, AppCoordinating {
    private let options: LaunchOptions
    private var logging: LoggingSystem!
    private var app: AppViewModel!
    private var windows: [BrowserWindowController] = []
    private var settingsWindow: SettingsWindowController?
    private var debugConsole: DebugConsoleWindowController?
    private var tokens: [ObservationToken] = []
    private let log = Logger(.app)
    private let launchStart = ContinuousClock.now

    public init(options: LaunchOptions) {
        self.options = options
        super.init()
    }

    public func applicationWillFinishLaunching(_ notification: Notification) {
        logging = LoggingSystem(hub: .shared, options: options, logDirectory: LoggingSystem.defaultLogDirectory)
        let store = SettingsStore(directory: SettingsStore.defaultDirectory)
        let settings = store.loadNow()
        let perf = PerfMonitor()
        let env = AppEnvironment(logHub: .shared,
                                 sources: SourceRegistry([LocalFileSource(perf: perf)]),
                                 workspace: LiveWorkspace(),
                                 perf: perf,
                                 springDelay: AppEnvironment.systemSpringDelay())
        app = AppViewModel(env: env, settings: settings, store: store, logging: logging, debugSession: options.debugSession)
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
        log.notice("Down \(version) starting (macOS \(ProcessInfo.processInfo.operatingSystemVersionString))")

        NSApp.mainMenu = MainMenu.build(keybindings: app.keybindings)
        NSWindow.allowsAutomaticWindowTabbing = true

        tokens.append(track { [weak self] in
            guard let self else { return }
            switch app.settings.theme {
            case .system: NSApp.appearance = nil
            case .light: NSApp.appearance = NSAppearance(named: .aqua)
            case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
            }
        })
        tokens.append(track { [weak self] in
            guard let self else { return }
            _ = app.keybindings
            NSApp.mainMenu = MainMenu.build(keybindings: app.keybindings)
            updateDebugMenuVisibility()
        })
        tokens.append(track { [weak self] in
            guard let self else { return }
            _ = app.debugConsoleAvailable
            updateDebugMenuVisibility()
        })
    }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        var start: Location?
        if let path = options.initialPath {
            start = PathInput.resolve(path, relativeTo: .file(FileManager.default.currentDirectoryPath))
        }
        newWindow(at: start)
        NSApp.activate()
        let elapsed = ContinuousClock.now - launchStart
        app.env.perf.record("launch", elapsed)
        log.info("launched in \(PerfMonitor.format(elapsed))")
        if options.debugSession { showDebugConsole() }
        if let path = options.snapshotPath { scheduleSnapshot(to: path) }
    }

    /// Renders the front window (including its toolbar) to a PNG, then quits. Needs no screen-recording permission.
    private func scheduleSnapshot(to path: String) {
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.5))
            guard let window = NSApp.windows.first(where: { $0.windowController is BrowserWindowController }),
                  let frameView = window.contentView?.superview else { return }
            // Render in light appearance so text is legible against the PNG's transparent glass areas.
            if ProcessInfo.processInfo.environment["DOWN_SNAPSHOT_DARK"] != "1" {
                NSApp.appearance = NSAppearance(named: .aqua)
            }
            frameView.layoutSubtreeIfNeeded()
            try? await Task.sleep(for: .milliseconds(300))
            let bounds = frameView.bounds
            guard let rep = frameView.bitmapImageRepForCachingDisplay(in: bounds) else { return }
            frameView.cacheDisplay(in: bounds, to: rep)
            if let data = rep.representation(using: .png, properties: [:]) {
                try? data.write(to: URL(filePath: path))
                log.notice("snapshot written to \(path: path)")
            }
            // Glass materials don't render through cacheDisplay; also capture the sidebar rows and
            // the toolbar's path bar on their own so they can be inspected.
            if let controller = window.windowController as? BrowserWindowController {
                for (suffix, view) in controller.snapshotParts() {
                    guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
                    view.cacheDisplay(in: view.bounds, to: rep)
                    let partPath = path.replacingOccurrences(of: ".png", with: "-\(suffix).png")
                    try? rep.representation(using: .png, properties: [:])?.write(to: URL(filePath: partPath))
                }
            }
            NSApp.terminate(nil)
        }
    }

    public func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    public func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { newWindow(at: nil) }
        return true
    }

    public func applicationWillTerminate(_ notification: Notification) {
        log.notice("terminating")
        // Flush debounced settings synchronously before the process exits.
        let app = self.app!
        let done = DispatchSemaphore(value: 0)
        Task.detached { await app.flushSettings(); done.signal() }
        _ = done.wait(timeout: .now() + 1)
    }

    public func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.isFileURL {
            newWindow(at: Location(url: url))
        }
    }

    // MARK: - AppCoordinating

    public func newWindow(at location: Location?) {
        let controller = makeController(at: location)
        if let key = NSApp.keyWindow {
            controller.window?.setFrameTopLeftPoint(NSPoint(x: key.frame.minX + 24, y: key.frame.maxY - 24))
        } else {
            controller.window?.center()
        }
        controller.showWindow(nil)
        controller.start()
    }

    public func newTab(beside window: NSWindow, at location: Location?) {
        let controller = makeController(at: location)
        guard let newWindow = controller.window else { return }
        window.addTabbedWindow(newWindow, ordered: .above)
        newWindow.makeKeyAndOrderFront(nil)
        controller.start()
    }

    public func showSettings() {
        if settingsWindow == nil {
            settingsWindow = SettingsWindowController(app: app)
            // Center once; afterwards the window stays where the user moved it (also when ⌘, is
            // pressed while it's open).
            settingsWindow?.window?.center()
        }
        settingsWindow?.showWindow(nil)
    }

    public func showDebugConsole() {
        guard app.debugConsoleAvailable else { return }
        if debugConsole == nil {
            debugConsole = DebugConsoleWindowController(app: app, ring: logging.ring) { [weak self] in
                guard let self else { return [] }
                let focused = (NSApp.mainWindow?.windowController as? BrowserWindowController) ?? windows.last
                var pairs = focused?.vm.debugState ?? [("tab", "none")]
                pairs.append(("open tabs", "\(windows.count)"))
                pairs.append(("pins", "\(app.settings.pins.count)"))
                pairs.append(("spring delay", "\(app.env.springDelay)"))
                pairs.append(("ring buffer", "\(logging.ring.count) / \(logging.ring.capacity)"))
                return pairs
            }
        }
        debugConsole?.showWindow(nil)
    }

    // MARK: - Private

    private func makeController(at location: Location?) -> BrowserWindowController {
        let vm = BrowserViewModel(app: app, location: location)
        let controller = BrowserWindowController(vm: vm, coordinator: self)
        windows.append(controller)
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: controller.window,
                                               queue: .main) { [weak self, weak controller] _ in
            MainActor.assumeIsolated {
                self?.windows.removeAll { $0 === controller }
            }
        }
        return controller
    }

    private func updateDebugMenuVisibility() {
        let visible = app.debugConsoleAvailable
        func walk(_ menu: NSMenu) {
            for item in menu.items {
                if MainMenu.command(of: item) == .debugConsole { item.isHidden = !visible }
                if let sub = item.submenu { walk(sub) }
            }
        }
        if let menu = NSApp.mainMenu { walk(menu) }
        if !visible { debugConsole?.close() }
    }
}
