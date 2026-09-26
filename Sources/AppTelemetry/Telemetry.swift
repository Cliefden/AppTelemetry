import Foundation
@_exported import TelemetryDeck

/// The single, stable analytics surface for every app in the family.
///
/// Design goals, distilled from the per-app implementations this replaces:
/// - **Guarded no-op** (from Stokked's `AnalyticsService`): every call is inert
///   until `start(appID:)` runs with a real app ID, so instrumentation can be
///   sprinkled freely without worrying about init ordering or a placeholder ID.
/// - **Thin wrapper** (from ThenCam's `Analytics`): the rest of the app calls
///   `Telemetry.signal(_:_:)` and never imports TelemetryDeck directly.
/// - **User identity on auth changes** (from Contrarian's `updateDefaultUserID`
///   calls in `AppState`): `identify(_:)` / `reset()` map the analytics user to
///   the Supabase user UUID so web + iOS signals deduplicate to one person.
///
/// Call `start(appID:)` once, early, from the app's `init()`. TelemetryDeck app
/// IDs are NOT secret — they ship in the binary and only route signals to the
/// right TelemetryDeck app.
public enum Telemetry {
    /// Set once by `start(appID:)`. Reads are benign; the only writer is launch.
    nonisolated(unsafe) private static var isEnabled = false

    private static func idLooksReal(_ appID: String) -> Bool {
        !appID.isEmpty && !appID.hasPrefix("REPLACE_") && !appID.hasPrefix("YOUR_")
    }

    /// Initialize TelemetryDeck. No-op (with a log line) if `appID` is a
    /// placeholder, which keeps un-provisioned apps like Ariman from crashing or
    /// emitting to a bogus app.
    ///
    /// - Parameters:
    ///   - appID: TelemetryDeck app ID (dashboard → Create App → App ID).
    ///   - sendLaunchSignal: fire `Signal.appLaunched` right after init. Default `true`.
    public static func start(appID: String, sendLaunchSignal: Bool = true) {
        guard idLooksReal(appID) else {
            AppLog.telemetry.info("TelemetryDeck app ID not set — analytics disabled")
            return
        }
        TelemetryDeck.initialize(config: TelemetryDeck.Config(appID: appID))
        isEnabled = true
        if sendLaunchSignal { signal(Signal.appLaunched) }
    }

    /// Send a signal. TelemetryDeck parameter values are strings by convention.
    /// Pass a `Signal` constant (`Telemetry.signal(Signal.trialStarted)`) for the
    /// shared vocabulary, or a raw string for one-offs.
    public static func signal(_ name: String, _ parameters: [String: String] = [:]) {
        guard isEnabled else { return }
        TelemetryDeck.signal(name, parameters: parameters)
    }

    /// Bind subsequent signals to a user (pass the Supabase user UUID). Call on
    /// sign-in / session restore.
    public static func identify(_ userID: String) {
        guard isEnabled else { return }
        TelemetryDeck.updateDefaultUserID(to: userID)
    }

    /// Clear the bound user. Call on sign-out.
    public static func reset() {
        guard isEnabled else { return }
        TelemetryDeck.updateDefaultUserID(to: nil)
    }
}
