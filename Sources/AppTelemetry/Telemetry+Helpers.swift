import Foundation
import os

// MARK: - Install-date anchor

extension Telemetry {
    /// `UserDefaults` key of the single install-date anchor (a `Date`).
    public static let installDateDefaultsKey = "AppTelemetry.installDate"

    /// Keys that apps used for their own install date before 2.1. The first
    /// time the anchor is needed, the **earliest** date found under any of
    /// these is adopted, so migrating an app never resets everyone's tenure to
    /// "0". Values may be a `Date` or seconds since 1970 (Otta). Legacy keys
    /// are left in place (read-only).
    public static let legacyInstallDateKeys = [
        "analyticsInstallDate",     // Lunker
        "telemetry.installDate",    // Sextant, Equinox
        "analytics.installDate",    // Otta (TimeInterval since 1970)
        "celiador.installDate",     // Celiador
        "contria.td.firstLaunch",   // Contrarian
    ]

    /// The install date: the anchor for `TelemetryBuckets.daysSinceInstall`.
    /// Recorded on first access (normally by `start(appID:)`), see
    /// `recordInstallDateIfNeeded`.
    public static var installDate: Date { recordInstallDateIfNeeded() }

    /// Return the stored install anchor, creating it on first call from (in
    /// order) the earliest legacy key, else the app's Documents directory
    /// creation date (created on first launch, so a good proxy for installs
    /// that predate any key — iOS/watchOS/visionOS only), else `now`.
    /// Never in the future. Thread-safe.
    @discardableResult
    public static func recordInstallDateIfNeeded(defaults: UserDefaults = .standard, now: Date = Date()) -> Date {
        installDateLock.withLockUnchecked {
            if let stored = defaults.object(forKey: installDateDefaultsKey) as? Date {
                return stored
            }
            let date = min(legacyInstallDate(in: defaults) ?? documentsCreationDate() ?? now, now)
            defaults.set(date, forKey: installDateDefaultsKey)
            return date
        }
    }

    private static let installDateLock = OSAllocatedUnfairLock()

    /// Earliest date stored under any `legacyInstallDateKeys` entry.
    static func legacyInstallDate(in defaults: UserDefaults) -> Date? {
        legacyInstallDateKeys.compactMap { key -> Date? in
            switch defaults.object(forKey: key) {
            case let date as Date: return date
            case let seconds as Double where seconds > 0: return Date(timeIntervalSince1970: seconds)
            case let seconds as Int where seconds > 0: return Date(timeIntervalSince1970: TimeInterval(seconds))
            default: return nil
            }
        }.min()
    }

    /// Overridable for tests (the real lookup sees the test runner's sandbox).
    nonisolated(unsafe) static var documentsCreationDate: () -> Date? = {
        #if os(macOS)
        // A non-sandboxed Mac app's Documents folder is the user's, created
        // long before the app — not an install proxy.
        return nil
        #else
        guard let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first,
              let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else { return nil }
        return attributes[.creationDate] as? Date
        #endif
    }
}

// MARK: - Common signals

extension Telemetry {
    /// `screen.viewed {screen}` — call from `onAppear` of top-level screens and
    /// sheets (or use `.trackScreen(_:)`). `name` must be a fixed identifier.
    public static func screen(_ name: String) {
        signal(Signal.screenViewed, ["screen": name])
    }

    /// `screen.viewed` for an app's `Screen` enum.
    public static func screen<S: RawRepresentable>(_ screen: S) where S.RawValue == String {
        self.screen(screen.rawValue)
    }

    /// `setting.changed {key, value}` — boolean / enumerable settings only;
    /// `value` must be low-cardinality (never free text).
    public static func settingChanged(_ key: String, _ value: String) {
        signal(Signal.settingChanged, ["key": key, "value": value])
    }

    /// `setting.changed {key, value: "true"/"false"}`.
    public static func settingChanged(_ key: String, _ value: Bool) {
        settingChanged(key, TelemetryBuckets.bool(value))
    }

    /// `permission.prompted {permission, context?}` — right before a system
    /// permission prompt. `permission`: e.g. `location`, `notifications`.
    public static func permissionPrompted(_ permission: String, context: String? = nil) {
        var params = ["permission": permission]
        if let context { params["context"] = context }
        signal(Signal.permissionPrompted, params)
    }

    /// `permission.result {permission, result, context?}` for a prompt the user
    /// actually answered. `result`: `granted`, `denied`, `restricted`, …
    public static func permissionResult(_ permission: String, result: String, context: String? = nil) {
        var params = ["permission": permission, "result": result]
        if let context { params["context"] = context }
        signal(Signal.permissionResult, params)
    }

    /// `permission.result` with `result` = `granted` / `denied`.
    public static func permissionResult(_ permission: String, granted: Bool, context: String? = nil) {
        permissionResult(permission, result: granted ? "granted" : "denied", context: context)
    }

    /// `error.<domain> {code, …extra}` for a real failure, with `code` from
    /// `TelemetryErrors.errorCode(for:)`. Cancellations are dropped. Returns
    /// whether a signal was emitted.
    @discardableResult
    public static func error(_ domain: String, _ error: Error, _ extra: [String: String] = [:]) -> Bool {
        guard let code = TelemetryErrors.errorCode(for: error) else { return false }
        self.error(domain, code: code, extra)
        return true
    }

    /// `error.<domain> {code, …extra}` for failures that aren't a thrown error.
    public static func error(_ domain: String, code: String, _ extra: [String: String] = [:]) {
        signal(Signal.error(domain), extra.merging(["code": code]) { _, new in new })
    }
}

// MARK: - Once / daily

extension Telemetry {
    static let oncePrefix = "AppTelemetry.once."
    static let dailyPrefix = "AppTelemetry.lastSent."

    /// Send `signal` the first time `key` is seen **per install** (activation
    /// milestones, funnel steps). The key is consumed even while telemetry is
    /// disabled or opted out, matching the per-app versions this replaces, so a
    /// milestone is never back-filled later. Returns `true` when it fired.
    ///
    /// - Parameter legacyKey: the full `UserDefaults` key the app's own copy
    ///   used (a `Bool`, e.g. Contrarian `contria.td.once.<name>`, Celiador
    ///   `celiador.telemetry.onboarding.<step>`). If it is set, the milestone
    ///   counts as already sent, so migrating doesn't re-fire it for existing
    ///   installs.
    @discardableResult
    public static func once(
        _ key: String,
        _ signal: String,
        _ parameters: [String: String] = [:],
        legacyKey: String? = nil,
        defaults: UserDefaults = .standard
    ) -> Bool {
        let defaultsKey = oncePrefix + key
        let first = onceLock.withLockUnchecked { () -> Bool in
            guard !defaults.bool(forKey: defaultsKey) else { return false }
            defaults.set(true, forKey: defaultsKey)
            if let legacyKey, defaults.bool(forKey: legacyKey) { return false }
            return true
        }
        if first { self.signal(signal, parameters) }
        return first
    }

    /// `once(name, name, parameters)` — the milestone *is* the signal name.
    @discardableResult
    public static func once(_ signal: String, _ parameters: [String: String] = [:]) -> Bool {
        once(signal, signal, parameters)
    }

    /// `true` the first time it is called for `key` on a given calendar day
    /// (and records that), so state snapshots — widgets installed, alerts
    /// enabled — are sent at most daily.
    public static func firstTimeToday(
        _ key: String,
        now: Date = Date(),
        calendar: Calendar = .current,
        defaults: UserDefaults = .standard
    ) -> Bool {
        let defaultsKey = dailyPrefix + key
        return onceLock.withLockUnchecked {
            if let last = defaults.object(forKey: defaultsKey) as? Date,
               calendar.isDate(last, inSameDayAs: now) {
                return false
            }
            defaults.set(now, forKey: defaultsKey)
            return true
        }
    }

    private static let onceLock = OSAllocatedUnfairLock()
}

#if canImport(SwiftUI)
import SwiftUI

extension View {
    /// Send `screen.viewed {screen}` each time this view appears.
    public func trackScreen(_ name: String) -> some View {
        onAppear { Telemetry.screen(name) }
    }

    /// Send `screen.viewed` for an app's `Screen` enum each time this view appears.
    public func trackScreen<S: RawRepresentable>(_ screen: S) -> some View where S.RawValue == String {
        onAppear { Telemetry.screen(screen.rawValue) }
    }
}
#endif
