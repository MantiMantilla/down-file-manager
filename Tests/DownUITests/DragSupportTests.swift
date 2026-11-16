import AppKit
import Foundation
import Testing
@testable import DownUI

@Suite("Drag support")
@MainActor
struct DragSupportTests {
    @Test func pinDragsAreRecognized() {
        #expect(DragSupport.isPinDrag([DragSupport.pinType, .fileURL]))
        #expect(!DragSupport.isPinDrag([.fileURL]))
        #expect(!DragSupport.isPinDrag(nil))
    }

    /// Runs the main run loop so the spring-load timer can fire (no awaiting: timers need the run loop).
    func pump(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    @Test func springLoadFiresWhileADragIsLive() {
        let loader = SpringLoader(delay: .milliseconds(20), isDragLive: { true })
        var fired = 0
        loader.hover("folder") { fired += 1 }
        pump(0.15)
        #expect(fired == 1)
    }

    @Test func springLoadDoesNotFireAfterTheMouseWasReleased() {
        // The drag ended (button up) without the view hearing that it left: no navigation.
        let loader = SpringLoader(delay: .milliseconds(20), isDragLive: { false })
        var fired = 0
        loader.hover("folder") { fired += 1 }
        pump(0.15)
        #expect(fired == 0)
    }

    @Test func cancelAndMovingOffStopThePendingSpringLoad() {
        let loader = SpringLoader(delay: .milliseconds(30), isDragLive: { true })
        var fired = 0
        loader.hover("a") { fired += 1 }
        loader.hover(nil) {}
        loader.hover("b") { fired += 1 }
        loader.cancel()
        pump(0.15)
        #expect(fired == 0)
    }
}
