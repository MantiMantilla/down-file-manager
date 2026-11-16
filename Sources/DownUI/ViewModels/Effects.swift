import Foundation
import DownCore

/// Tracks the async work a ViewModel starts. Starting an effect with a key that's already
/// running cancels the old one, so e.g. a new navigation always cancels the previous listing.
@MainActor
final class EffectRunner<Key: Hashable> {
    private var tasks: [Key: (id: UUID, task: Task<Void, Never>, finite: Bool, started: Date)] = [:]

    func run(_ key: Key, finite: Bool = true, _ body: @escaping @MainActor () async -> Void) {
        tasks[key]?.task.cancel()
        let id = UUID()
        let task = Task { @MainActor [weak self] in
            await body()
            // Only remove ourselves if we weren't replaced meanwhile.
            if self?.tasks[key]?.id == id { self?.tasks[key] = nil }
        }
        tasks[key] = (id, task, finite, Date())
    }

    func cancel(_ key: Key) {
        tasks[key]?.task.cancel()
        tasks[key] = nil
    }

    func cancelAll() {
        for (_, t) in tasks { t.task.cancel() }
        tasks.removeAll()
    }

    func isRunning(_ key: Key) -> Bool { tasks[key] != nil }

    /// Snapshot for the Debug Console's State tab.
    var active: [(key: Key, age: TimeInterval)] {
        tasks.map { ($0.key, Date().timeIntervalSince($0.value.started)) }
    }

    /// Waits until every finite effect (including ones started meanwhile) has finished. For tests.
    func settle() async {
        while let next = tasks.values.first(where: { $0.finite }) {
            await next.task.value
            await Task.yield()
        }
    }
}
