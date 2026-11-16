import Foundation
import Observation
import DownCore

public struct NavigationHistory: Equatable, Sendable {
    public private(set) var back: [Location] = []
    public private(set) var forward: [Location] = []
    public static let limit = 100

    public init() {}

    public mutating func visit(from current: Location?) {
        if let current {
            back.append(current)
            if back.count > Self.limit { back.removeFirst(back.count - Self.limit) }
        }
        forward.removeAll()
    }

    public mutating func goBack(from current: Location) -> Location? {
        guard let target = back.popLast() else { return nil }
        forward.append(current)
        return target
    }

    public mutating func goForward(from current: Location) -> Location? {
        guard let target = forward.popLast() else { return nil }
        back.append(current)
        return target
    }
}

public enum LoadState: Equatable, Sendable {
    case idle, loading, loaded
    case failed(message: String, permissionDenied: Bool)
}

/// One tab: location, history, listing, selection, sort and view mode.
///
/// `send(_:)` is the only mutator. State changes synchronously; slow work runs as keyed
/// effects whose results come back as internal actions (tagged with a generation so results
/// for a folder the user already left are dropped).
@MainActor @Observable
public final class BrowserViewModel {
    public enum Action: Sendable, CustomStringConvertible {
        // User intents
        case navigate(Location)
        case goBack, goForward, goUp, goHome, reload
        case openSelection
        case open(paths: [String])
        case select(Set<String>)
        case setSort(FileSortOrder)
        case setViewMode(ViewMode)
        case toggleHidden
        case openInTerminal
        case springLoad(Location)
        case springLoadCancelled
        case dragEnded
        /// A drag started in this tab (list or sidebar): drop any spring-load origin left over from an
        /// earlier drag whose end was never observed (e.g. a cancelled drag from another app).
        case dragBegan
        case settingsChanged
        case dismissError
        // Internal results
        case listingBatch(gen: Int, [FileItem])
        case listingFinished(gen: Int)
        case listingFailed(gen: Int, message: String, permissionDenied: Bool)
        case watchEvent(gen: Int, WatchEvent)
        case itemsRefreshed(gen: Int, upserts: [FileItem], removals: Set<String>)
        case sorted(token: Int, [FileItem])
        case rootVanished(gen: Int, fallback: Location)

        public var description: String {
            switch self {
            case .navigate(let l): "navigate(\(l.path))"
            case .goBack: "goBack"
            case .goForward: "goForward"
            case .goUp: "goUp"
            case .goHome: "goHome"
            case .reload: "reload"
            case .openSelection: "openSelection"
            case .open(let p): "open(\(p.count) items)"
            case .select(let s): "select(\(s.count))"
            case .setSort(let s): "setSort(\(s.field.rawValue), asc: \(s.ascending))"
            case .setViewMode(let m): "setViewMode(\(m.rawValue))"
            case .toggleHidden: "toggleHidden"
            case .openInTerminal: "openInTerminal"
            case .springLoad(let l): "springLoad(\(l.path))"
            case .springLoadCancelled: "springLoadCancelled"
            case .dragEnded: "dragEnded"
            case .dragBegan: "dragBegan"
            case .settingsChanged: "settingsChanged"
            case .dismissError: "dismissError"
            case .listingBatch(let g, let items): "listingBatch(gen \(g), \(items.count))"
            case .listingFinished(let g): "listingFinished(gen \(g))"
            case .listingFailed(let g, let m, _): "listingFailed(gen \(g), \(m))"
            case .watchEvent(let g, let e): "watchEvent(gen \(g), \(e))"
            case .itemsRefreshed(let g, let u, let r): "itemsRefreshed(gen \(g), +\(u.count) -\(r.count))"
            case .sorted(let t, let items): "sorted(token \(t), \(items.count))"
            case .rootVanished(let g, let f): "rootVanished(gen \(g), → \(f.path))"
            }
        }

        /// Internal results are logged at trace level (they're frequent); intents at debug.
        var isInternal: Bool {
            switch self {
            case .listingBatch, .listingFinished, .listingFailed, .watchEvent, .itemsRefreshed, .sorted, .rootVanished: true
            default: false
            }
        }
    }

    enum EffectKey: Hashable, CustomStringConvertible {
        case listing, watch, refresh, sort, open, terminal, vanish
        var description: String {
            switch self {
            case .listing: "listing"
            case .watch: "watch"
            case .refresh: "refresh"
            case .sort: "sort"
            case .open: "open"
            case .terminal: "terminal"
            case .vanish: "vanish"
            }
        }
    }

    // MARK: State (read by views)

    public private(set) var location: Location
    public private(set) var history = NavigationHistory()
    /// Visible items (hidden filter applied), sorted.
    public private(set) var items: [FileItem] = []
    public private(set) var loadState: LoadState = .idle
    public private(set) var selection: Set<String> = []
    public private(set) var sort: FileSortOrder
    public private(set) var viewMode: ViewMode
    /// Set while a drag has spring-loaded us away from where it started.
    public private(set) var springOrigin: Location?
    /// Transient message for the toast/overlay (e.g. "folder was removed").
    public private(set) var notice: String?
    /// Bumped whenever `items` actually changes (not when a refresh yields the same rows),
    /// so AppKit views can cheaply detect reloads.
    public private(set) var itemsRevision = 0
    /// Path to select and reveal once the listing arrives (e.g. the folder we came up from).
    public private(set) var pendingReveal: String?

    public var showHidden: Bool { app.settings.showHidden }
    public var canGoBack: Bool { !history.back.isEmpty }
    public var canGoForward: Bool { !history.forward.isEmpty }
    public var canGoUp: Bool { location.parent != nil }
    public var selectedItems: [FileItem] { items.filter { selection.contains($0.path) } }

    // MARK: Internals

    public let app: AppViewModel
    @ObservationIgnored private let env: AppEnvironment
    @ObservationIgnored private let log: Logger
    @ObservationIgnored private let effects = EffectRunner<EffectKey>()
    @ObservationIgnored private var all: [String: FileItem] = [:]
    @ObservationIgnored private var incoming: [String: FileItem]?  // soft reload buffer
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var sortToken = 0
    @ObservationIgnored private var lastRebuild = ContinuousClock.now
    @ObservationIgnored private var pendingRefresh = Set<String>()

    /// Above this many items, sorting runs off the main actor.
    public static let backgroundSortThreshold = 5_000
    /// Intermediate re-sorts while a big listing streams in.
    public static let streamingRebuildInterval: Duration = .milliseconds(250)

    public init(app: AppViewModel, location: Location? = nil) {
        self.app = app
        env = app.env
        log = app.env.logger(.nav)
        sort = app.settings.sort
        viewMode = app.settings.defaultViewMode
        self.location = location ?? .file(app.env.homePath)
        app.register(self)
    }

    /// Kicks off the first listing.
    public func start() {
        load(location, soft: false, id: .next())
    }

    public func send(_ action: Action, id: ActionID = .next()) {
        if action.isInternal {
            log.trace("action \(action)", actionID: id)
        } else {
            log.debug("action \(action)", actionID: id)
        }

        // A deliberate navigation (including opening a folder) ends any spring-loaded detour. Drags that
        // start in Down's list or sidebar report their end; a cancelled drag from another app doesn't,
        // so its detour would otherwise linger and a later cancelled drag would jump back to it.
        switch action {
        case .navigate, .goBack, .goForward, .goUp, .goHome, .open, .openSelection: springOrigin = nil
        default: break
        }

        switch action {
        case .navigate(let target):
            navigate(to: target, id: id)

        case .goBack:
            guard let target = history.goBack(from: location) else { return }
            reveal(childOf: target, from: location)
            location = target
            load(target, soft: false, id: id)

        case .goForward:
            guard let target = history.goForward(from: location) else { return }
            reveal(childOf: target, from: location)
            location = target
            load(target, soft: false, id: id)

        case .goUp:
            guard let parent = location.parent else { return }
            navigate(to: parent, id: id)

        case .goHome:
            navigate(to: .file(env.homePath), id: id)

        case .reload:
            load(location, soft: true, id: id)

        case .openSelection:
            open(selectedItems, id: id)

        case .open(let paths):
            let set = Set(paths)
            open(items.filter { set.contains($0.path) }, id: id)

        case .select(let paths):
            // Keep only paths that still exist. The file list holds its rows while the mouse is down
            // (reloads wait for mouse-up), so it can report a row whose file was deleted mid-press.
            selection = paths.filter { all[$0] != nil }

        case .setSort(let order):
            guard order != sort else { return }
            sort = order
            app.send(.setSort(order), id: id)
            rebuildVisible(id: id)

        case .setViewMode(let mode):
            viewMode = mode
            app.send(.setDefaultViewMode(mode), id: id)

        case .toggleHidden:
            app.send(.setShowHidden(!app.settings.showHidden), id: id)  // broadcasts .settingsChanged

        case .settingsChanged:
            rebuildVisible(id: id)

        case .openInTerminal:
            let folder = location.url
            let terminal = app.settings.terminalBundleID
            let workspace = env.workspace, log = env.logger(.app)
            effects.run(.terminal) {
                do {
                    try await workspace.openFolderInTerminal(folder, terminalBundleID: terminal)
                    log.info("opened terminal at \(url: folder)", actionID: id)
                } catch {
                    log.error("open in terminal failed: \(error.localizedDescription)", actionID: id)
                }
            }

        case .springLoad(let target):
            guard target != location else { return }
            if springOrigin == nil { springOrigin = location }
            env.logger(.dnd).debug("spring-loaded into \(path: target.path)", actionID: id)
            navigate(to: target, id: id)

        case .springLoadCancelled:
            guard let origin = springOrigin else { return }
            springOrigin = nil
            env.logger(.dnd).debug("drag cancelled, returning to \(path: origin.path)", actionID: id)
            navigate(to: origin, id: id)

        case .dragEnded, .dragBegan:
            springOrigin = nil

        case .dismissError:
            notice = nil

        // MARK: internal results

        case .listingBatch(let gen, let batch):
            guard gen == generation else { return }
            if incoming != nil {
                for item in batch { incoming![item.path] = item }
            } else {
                let firstBatch = all.isEmpty
                for item in batch { all[item.path] = item }
                if firstBatch || ContinuousClock.now - lastRebuild > Self.streamingRebuildInterval {
                    rebuildVisible(id: id)
                }
            }

        case .listingFinished(let gen):
            guard gen == generation else { return }
            if let fresh = incoming {
                all = fresh
                incoming = nil
            }
            loadState = .loaded
            rebuildVisible(id: id)
            startWatching(gen: gen, id: id)

        case .listingFailed(let gen, let message, let denied):
            guard gen == generation else { return }
            incoming = nil
            loadState = .failed(message: message, permissionDenied: denied)
            all = [:]
            setItems([])

        case .watchEvent(let gen, let event):
            guard gen == generation else { return }
            handleWatch(event, gen: gen, id: id)

        case .itemsRefreshed(let gen, let upserts, let removals):
            guard gen == generation else { return }
            for path in removals { all[path] = nil }
            for item in upserts { all[item.path] = item }
            rebuildVisible(id: id)

        case .sorted(let token, let sorted):
            guard token == sortToken else { return }
            setItems(sorted)

        case .rootVanished(let gen, let fallback):
            guard gen == generation else { return }
            notice = "“\(location.name)” is no longer available."
            env.logger(.watch).notice("folder vanished, moving to \(path: fallback.path)", actionID: id)
            navigate(to: fallback, id: id)
        }
    }

    /// Waits for all finite effects (listing, sorting, refreshes) to finish. For tests.
    public func settle() async {
        await effects.settle()
    }

    /// Debug Console "State" tab.
    public var debugState: [(String, String)] {
        [
            ("location", location.path),
            ("loadState", "\(loadState)"),
            ("items (visible)", "\(items.count)"),
            ("items (all)", "\(all.count)"),
            ("selection", "\(selection.count)"),
            ("viewMode", viewMode.rawValue),
            ("sort", "\(sort.field.rawValue) \(sort.ascending ? "↑" : "↓") foldersFirst=\(sort.foldersFirst)"),
            ("showHidden", "\(showHidden)"),
            ("history", "back \(history.back.count) / forward \(history.forward.count)"),
            ("springOrigin", springOrigin?.path ?? "—"),
            ("generation", "\(generation)"),
            ("effects", effects.active.map { "\($0.key) (\(String(format: "%.1f", $0.age)) s)" }.joined(separator: ", ")),
        ]
    }

    // MARK: - Private

    private func navigate(to target: Location, id: ActionID) {
        if target == location {
            load(target, soft: true, id: id)
            return
        }
        history.visit(from: location)
        reveal(childOf: target, from: location)
        location = target
        load(target, soft: false, id: id)
    }

    /// Going up (or back to a parent) selects the folder we came from, like Nautilus.
    private func reveal(childOf target: Location, from previous: Location) {
        let prefix = target.path == "/" ? "/" : target.path + "/"
        if previous.path.hasPrefix(prefix) {
            let rest = previous.path.dropFirst(prefix.count)
            if let first = rest.split(separator: "/").first {
                pendingReveal = prefix + first
                return
            }
        }
        pendingReveal = nil
    }

    private func load(_ target: Location, soft: Bool, id: ActionID) {
        generation += 1
        let gen = generation
        effects.cancel(.watch)
        effects.cancel(.refresh)
        pendingRefresh.removeAll()
        notice = nil

        if soft && loadState == .loaded {
            incoming = [:]
        } else {
            incoming = nil
            all = [:]
            selection = []
            setItems([])
            loadState = .loading
        }

        let source: any FileSource
        do {
            source = try env.sources.source(for: target)
        } catch {
            loadState = .failed(message: error.localizedDescription, permissionDenied: false)
            return
        }

        log.info("loading \(path: target.path)\(soft ? " (soft)" : "")", actionID: id)
        effects.run(.listing) { [weak self] in
            do {
                for try await batch in source.list(target) {
                    if Task.isCancelled { return }
                    self?.send(.listingBatch(gen: gen, batch), id: id)
                }
                if Task.isCancelled { return }
                self?.send(.listingFinished(gen: gen), id: id)
            } catch {
                if Task.isCancelled { return }
                let denied = (error as? FileSourceError)?.isPermissionDenied ?? false
                self?.send(.listingFailed(gen: gen, message: error.localizedDescription, permissionDenied: denied), id: id)
            }
        }
    }

    private func startWatching(gen: Int, id: ActionID) {
        guard let source = try? env.sources.source(for: location), source.capabilities.contains(.watch) else { return }
        let target = location
        effects.run(.watch, finite: false) { [weak self] in
            for await event in source.watch(target) {
                if Task.isCancelled { return }
                self?.send(.watchEvent(gen: gen, event), id: .next())
            }
        }
    }

    private func handleWatch(_ event: WatchEvent, gen: Int, id: ActionID) {
        switch event {
        case .rescan:
            load(location, soft: true, id: id)
        case .rootChanged:
            let current = location
            effects.run(.vanish) { [weak self] in
                var candidate: Location? = current
                while let c = candidate, !FileManager.default.fileExists(atPath: c.path) { candidate = c.parent }
                guard let fallback = candidate else { return }
                if fallback == current {
                    self?.send(.reload, id: id)  // renamed in place or remounted
                } else {
                    self?.send(.rootVanished(gen: gen, fallback: fallback), id: id)
                }
            }
        case .changed(let names):
            let prefix = location.path == "/" ? "/" : location.path + "/"
            pendingRefresh.formUnion(names.map { prefix + $0 })
            guard !effects.isRunning(.refresh), let source = try? env.sources.source(for: location) else { return }
            effects.run(.refresh) { [weak self] in
                while let self, !self.pendingRefresh.isEmpty {
                    let batch = self.pendingRefresh
                    self.pendingRefresh.removeAll()
                    var upserts: [FileItem] = []
                    var removals = Set<String>()
                    for path in batch {
                        if Task.isCancelled { return }
                        if let item = try? await source.item(atPath: path) {
                            upserts.append(item)
                        } else {
                            removals.insert(path)
                        }
                    }
                    self.send(.itemsRefreshed(gen: gen, upserts: upserts, removals: removals), id: id)
                }
            }
        }
    }

    private func open(_ targets: [FileItem], id: ActionID) {
        guard !targets.isEmpty else { return }
        if let folder = targets.first(where: \.isFolderLike), targets.count == 1 || targets.allSatisfy(\.isFolderLike) {
            navigate(to: folder.location, id: id)
            return
        }
        let files = targets.filter { !$0.isFolderLike }
        let workspace = env.workspace, log = env.logger(.app)
        effects.run(.open) {
            for file in files {
                let ok = await workspace.open(file.url)
                if ok {
                    log.info("opened \(path: file.path)", actionID: id)
                } else {
                    log.error("could not open \(path: file.path)", actionID: id)
                }
            }
        }
    }

    private func rebuildVisible(id: ActionID) {
        lastRebuild = ContinuousClock.now
        let showHidden = app.settings.showHidden
        let candidates = showHidden ? Array(all.values) : all.values.filter { !$0.isHidden }
        let order = sort
        sortToken += 1
        let token = sortToken
        if candidates.count < Self.backgroundSortThreshold {
            setItems(env.perf.measure("sort", detail: "\(candidates.count) items") { Sorter.sorted(candidates, by: order) })
        } else {
            let perf = env.perf
            effects.run(.sort) { [weak self] in
                let sorted = await Task.detached(priority: .userInitiated) {
                    perf.measure("sort", detail: "\(candidates.count) items") { Sorter.sorted(candidates, by: order) }
                }.value
                if Task.isCancelled { return }
                self?.send(.sorted(token: token, sorted), id: id)
            }
        }
    }

    private func setItems(_ new: [FileItem]) {
        // Only a real change bumps the revision: every bump makes the list reload, which drops the
        // selection AppKit is tracking. Changes to hidden items (e.g. ~/Library, which changes several
        // times a second) re-sort to the same visible rows and must not reload the list. `==` alone
        // isn't enough: it ignores e.g. a symlink's target kind, which changes the row's icon and Open.
        if new.count != items.count || !zip(new, items).allSatisfy({ $0.isIdentical(to: $1) }) {
            items = new
            itemsRevision &+= 1
        }
        if !selection.isEmpty {
            let present = Set(new.lazy.map(\.path))
            let kept = selection.intersection(present)
            if kept.count != selection.count { selection = kept }
        }
        if let reveal = pendingReveal, new.contains(where: { $0.path == reveal }) {
            selection = [reveal]
            pendingReveal = nil
        }
    }

    /// Clears the one-shot reveal after the view has scrolled to it.
    public func consumeReveal() { pendingReveal = nil }
}
