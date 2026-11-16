import Foundation

/// Builds the "Save Diagnostics…" report: environment header + recent log lines, redacted.
public enum Diagnostics {
    public static func report(entries: [LogEntry], settingsSummary: String, redaction: Redaction,
                              appVersion: String = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev",
                              osVersion: String = ProcessInfo.processInfo.operatingSystemVersionString,
                              homeDirectory: String = NSHomeDirectory(),
                              now: Date = Date()) -> String {
        let formatter = LogLineFormatter(homeDirectory: homeDirectory)
        var out = """
        Down diagnostics
        Generated: \(now.ISO8601Format())
        Version: \(appVersion)
        macOS: \(osVersion)
        Architecture: \(Self.architecture)
        Settings: \(settingsSummary)
        Redaction: \(redaction == .anonymize ? "anonymized names" : "home folder abbreviated")
        Entries: \(entries.count)
        ----------------------------------------------------------------

        """
        for e in entries {
            out += formatter.format(e, redaction: redaction == .none ? .abbreviateHome : redaction)
            out += "\n"
        }
        return out
    }

    static var architecture: String {
        #if arch(arm64)
        "arm64"
        #else
        "x86_64"
        #endif
    }
}
