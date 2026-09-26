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
    /// Defaults to the app's bundle identifier; override once at launch if you
    /// want a fixed subsystem (e.g. for a widget/watch extension).
    nonisolated(unsafe) public static var subsystem =
        Bundle.main.bundleIdentifier ?? "com.crawik.app"

    // Common categories. For anything app-specific, use `AppLog.logger("sync")`.
    public static let app = Logger(subsystem: subsystem, category: "app")
    public static let store = Logger(subsystem: subsystem, category: "store")
    public static let persistence = Logger(subsystem: subsystem, category: "persistence")
    public static let notifications = Logger(subsystem: subsystem, category: "notifications")
    public static let sync = Logger(subsystem: subsystem, category: "sync")
    public static let telemetry = Logger(subsystem: subsystem, category: "telemetry")

    /// A logger for an ad-hoc category (e.g. "sync", "routing").
    public static func logger(_ category: String) -> Logger {
        Logger(subsystem: subsystem, category: category)
    }

    /// Log an error and count it anonymously in TelemetryDeck.
    ///
    /// Sends only `category`, `domain`, and `code` — never the localized message.
    public static func reportError(_ category: String, _ error: Error, logger: Logger = app) {
        let ns = error as NSError
        logger.error("\(category, privacy: .public): \(ns, privacy: .public)")
        Telemetry.signal(Signal.errorOccurred, [
            "category": category,
            "domain": ns.domain,
            "code": String(ns.code),
        ])
    }
}
