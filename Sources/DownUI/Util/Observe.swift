import Foundation
import Observation

/// Cancels an `track { }` subscription.
@MainActor
public final class ObservationToken {
    fileprivate var cancelled = false
    public func cancel() { cancelled = true }
    deinit {}
}

/// Runs `body` now and again whenever any observable property it read changes.
/// Changes are coalesced to the next main-actor turn, so a burst of mutations triggers one update.
@MainActor
@discardableResult
public func track(_ body: @escaping @MainActor () -> Void) -> ObservationToken {
    let token = ObservationToken()
    let box = ObserveBox(token: token, body: body)
    box.run()
    return token
}

@MainActor
private final class ObserveBox {
    let token: ObservationToken
    let body: @MainActor () -> Void
    var scheduled = false

    init(token: ObservationToken, body: @escaping @MainActor () -> Void) {
        self.token = token
        self.body = body
    }

    func run() {
        guard !token.cancelled else { return }
        scheduled = false
        withObservationTracking {
            body()
        } onChange: { [self] in
            Task { @MainActor in
                guard !self.scheduled else { return }
                self.scheduled = true
                self.run()
            }
        }
    }
}
