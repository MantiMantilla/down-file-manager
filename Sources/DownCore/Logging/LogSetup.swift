import Foundation

/// Command-line / environment options that affect logging.
public struct LaunchOptions: Sendable, Equatable {
    /// `--log-level <spec>` or `DOWN_LOG=<spec>`; nil means "decide from isatty".
    public var stderrSpec: LevelSpec?
    /// `--debug`: enables the Debug Console and verbose logging for this session only.
    public var debugSession = false
    /// First non-flag argument: a folder to open.
    public var initialPath: String?
    /// `--snapshot <png>`: render the first window to an image after launch and quit (diagnostics/tests).
    public var snapshotPath: String?

    public init(stderrSpec: LevelSpec? = nil, debugSession: Bool = false, initialPath: String? = nil) {
        self.stderrSpec = stderrSpec
        self.debugSession = debugSession
        self.initialPath = initialPath
    }

    public static func parse(arguments: [String], environment: [String: String]) -> LaunchOptions {
        var options = LaunchOptions()
        if let env = environment["DOWN_LOG"], !env.isEmpty {
            options.stderrSpec = LevelSpec.parse(env, default: .debug)
        }
        var i = 1
        while i < arguments.count {
            let arg = arguments[i]
            switch arg {
            case "--log-level":
                if i + 1 < arguments.count {
                    options.stderrSpec = LevelSpec.parse(arguments[i + 1], default: .debug)
                    i += 1
                }
            case "--debug":
                options.debugSession = true
            case "--snapshot":
                if i + 1 < arguments.count {
                    options.snapshotPath = arguments[i + 1]
                    i += 1
                }
            default:
                if arg.hasPrefix("--log-level=") {
                    options.stderrSpec = LevelSpec.parse(String(arg.dropFirst("--log-level=".count)), default: .debug)
                } else if arg.hasPrefix("-") {
                    // Ignore AppKit's own flags (e.g. -NSDocumentRevisionsDebugMode YES).
                    if i + 1 < arguments.count, !arguments[i + 1].hasPrefix("-"), arg.hasPrefix("-NS") || arg.hasPrefix("-Apple") {
                        i += 1
                    }
                } else if options.initialPath == nil {
                    options.initialPath = arg
                }
            }
            i += 1
        }
        return options
    }
}

/// Owns the process-wide sinks and keeps their levels in sync with settings.
public final class LoggingSystem: Sendable {
    public let hub: LogHub
    public let osLog: OSLogSink
    public let ring: RingBufferSink
    public let stderr: StderrSink?
    public let file: RollingFileSink

    public init(hub: LogHub = .shared, options: LaunchOptions, logDirectory: URL) {
        self.hub = hub
        osLog = OSLogSink()
        ring = RingBufferSink(capacity: 10_000)
        file = RollingFileSink(directory: logDirectory)

        let interactive = isatty(STDERR_FILENO) != 0
        if let spec = options.stderrSpec {
            stderr = StderrSink(spec: spec)
        } else if interactive {
            stderr = StderrSink(spec: LevelSpec(base: .debug))
        } else {
            stderr = nil
        }

        hub.add(osLog)
        hub.add(ring)
        if let stderr { hub.add(stderr) }
    }

    /// Applies the Debug Console / verbose / file-logging settings to the sinks.
    public func apply(debugConsoleEnabled: Bool, verbose: Bool, verboseCategories: Set<LogCategory>,
                      fileLogging: Bool) {
        let ringBase: LogLevel = debugConsoleEnabled ? .debug : .info
        var ringSpec = LevelSpec(base: verbose ? .debug : ringBase)
        if verbose { for c in verboseCategories { ringSpec.overrides[c] = .trace } }
        ring.setSpec(ringSpec)

        if fileLogging {
            file.setSpec(LevelSpec(base: verbose ? .debug : .info, overrides: ringSpec.overrides))
            hub.remove(file)  // keep a single registration
            hub.add(file)
        } else {
            hub.remove(file)
        }
        hub.recomputeThreshold()
    }

    public static var defaultLogDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Logs/Down")
    }
}
