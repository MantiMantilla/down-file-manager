import AppKit
import DownCore
import DownUI

let options = LaunchOptions.parse(arguments: CommandLine.arguments, environment: ProcessInfo.processInfo.environment)

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = DownAppDelegate(options: options)
    app.delegate = delegate
    app.setActivationPolicy(.regular)
    withExtendedLifetime(delegate) {
        app.run()
    }
}
