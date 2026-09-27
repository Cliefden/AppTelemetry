import Foundation
import os

/// Central loggers and privacy-preserving error reporting, generalized from the
/// identical `AppLog` enums in Sextant and Lunker.
///
/// Errors are logged with `os.Logger` so they are visible in Console.app even in
/// Release builds (unlike `print`), and counted anonymously in TelemetryDeck as
/// `error.occurred`. Only the category and the error's domain/code are sent —
/// never message content, which could contain user data.
public enum AppLog {
    private static let subsystemStorage = OSAllocatedUnfairLock(
        initialState: Bundle.main.bundleIdentifier ?? "com.crawik.app"
    )

    /// Defaults to the app's bundle identifier; override at launch if you want a
    /// fixed subsystem (e.g. to group a widget/watch extension with its app).
    /// Loggers are created on access, so the override applies to every logger
    /// obtained after it is set. Thread-safe.
    public static var subsystem: String {
        get { subsystemStorage.withLock { $0 } }
        set { subsystemStorage.withLock { $0 = newValue } }
    }

    // Common categories. For anything app-specific, use `AppLog.logger("sync")`.
    public static var app: Logger { logger("app") }
    public static var store: Logger { logger("store") }
    public static var persistence: Logger { logger("persistence") }
    public static var notifications: Logger { logger("notifications") }
    public static var sync: Logger { logger("sync") }
    public static var telemetry: Logger { logger("telemetry") }

    /// A logger for an ad-hoc category (e.g. "sync", "routing").
    public static func logger(_ category: String) -> Logger {
        Logger(subsystem: subsystem, category: category)
    }

    /// Log an error and count it anonymously in TelemetryDeck.
    ///
    /// The unified log gets the category, domain and code publicly; the full
    /// error description (which may hold URLs, tokens, paths or server messages)
    /// is marked `.private`, so it is redacted in sysdiagnoses unless a debugger
    /// or logging profile is attached. TelemetryDeck receives only `category`,
    /// `domain`, and `code` — never the localized message.
    public static func reportError(_ category: String, _ error: Error, logger: Logger = app) {
        let ns = error as NSError
        logger.error("\(category, privacy: .public): \(ns.domain, privacy: .public) \(ns.code, privacy: .public) — \(String(describing: ns), privacy: .private)")
        Telemetry.signal(Signal.errorOccurred, errorParameters(category, ns))
    }

    /// The exact TelemetryDeck payload for an error (exposed internally for tests).
    static func errorParameters(_ category: String, _ error: NSError) -> [String: String] {
        [
            "category": category,
            "domain": error.domain,
            "code": String(error.code),
        ]
    }
}
