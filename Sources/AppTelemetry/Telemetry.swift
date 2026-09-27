import Foundation
import os
import TelemetryDeck

/// The single, stable analytics surface for every app in the family.
///
/// Design goals, distilled from the per-app implementations this replaces:
/// - **Guarded no-op** (from Stokked's `AnalyticsService`): every call is inert
///   until `start(appID:)` runs with a real app ID, so instrumentation can be
///   sprinkled freely without worrying about init ordering or a placeholder ID.
/// - **Thin wrapper** (from ThenCam's `Analytics`): the rest of the app calls
///   `Telemetry.signal(_:_:)` and never imports TelemetryDeck directly (the SDK
///   is deliberately *not* re-exported, so the guards below can't be bypassed).
/// - **User identity on auth changes** (from Contrarian's `updateDefaultUserID`
///   calls in `AppState`): `identify(_:)` / `reset()` map the analytics user to
///   the Supabase user UUID so web + iOS signals deduplicate to one person.
/// - **User opt-out** (PORTFOLIO_STANDARD §Analytics): `setOptedOut(_:)` is
///   persisted in `UserDefaults` and checked both before the SDK is initialized
///   and on every send.
///
/// Call `start(appID:)` once, early, from the app's `init()`. TelemetryDeck app
/// IDs are NOT secret — they ship in the binary and only route signals to the
/// right TelemetryDeck app. All entry points are thread-safe.
public enum Telemetry {
    /// `UserDefaults` key holding the user's analytics opt-out choice.
    public static let optOutDefaultsKey = "AppTelemetry.optedOut"

    struct State {
        /// The real app ID passed to `start`, remembered even while opted out so
        /// that opting back in can initialize the SDK without a relaunch.
        var appID: String?
        /// Whether `TelemetryDeck.initialize` has run (at most once per process).
        var sdkInitialized = false
    }

    private static let state = OSAllocatedUnfairLock(initialState: State())

    static func idLooksReal(_ appID: String) -> Bool {
        let trimmed = appID.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && !trimmed.hasPrefix("REPLACE_") && !trimmed.hasPrefix("YOUR_")
    }

    // MARK: - Opt-out

    /// `true` if the user has opted out of analytics. Persisted across launches.
    public static var isOptedOut: Bool {
        UserDefaults.standard.bool(forKey: optOutDefaultsKey)
    }

    /// Persist the user's analytics choice. Bind a Settings toggle to this.
    ///
    /// Opting out stops all further signals immediately. Opting back in
    /// initializes the SDK if `start(appID:)` already ran with a real ID while
    /// the user was opted out.
    public static func setOptedOut(_ optedOut: Bool) {
        UserDefaults.standard.set(optedOut, forKey: optOutDefaultsKey)
        if !optedOut { initializeSDKIfNeeded(sendLaunchSignal: false) }
    }

    /// `true` when signals are actually being sent: the SDK is initialized with
    /// a real app ID and the user has not opted out.
    public static var isEnabled: Bool {
        state.withLock { $0.sdkInitialized } && !isOptedOut
    }

    // MARK: - Lifecycle

    /// Initialize TelemetryDeck. No-op (with a log line) if `appID` is a
    /// placeholder, which keeps un-provisioned apps like Ariman from crashing or
    /// emitting to a bogus app. If the user has opted out, the SDK is not
    /// initialized at all (until they opt back in). Safe to call more than once:
    /// only the first real app ID is used.
    ///
    /// - Parameters:
    ///   - appID: TelemetryDeck app ID (dashboard → Create App → App ID).
    ///   - sendLaunchSignal: fire `Signal.appLaunched` right after init. Default `true`.
    public static func start(appID: String, sendLaunchSignal: Bool = true) {
        guard idLooksReal(appID) else {
            AppLog.telemetry.info("TelemetryDeck app ID not set — analytics disabled")
            return
        }
        let accepted = state.withLock { s -> Bool in
            guard s.appID == nil else { return false }
            s.appID = appID
            return true
        }
        guard accepted else {
            AppLog.telemetry.debug("Telemetry.start called more than once — ignored")
            return
        }
        guard !isOptedOut else {
            AppLog.telemetry.info("User opted out of analytics — TelemetryDeck not initialized")
            return
        }
        initializeSDKIfNeeded(sendLaunchSignal: sendLaunchSignal)
    }

    private static func initializeSDKIfNeeded(sendLaunchSignal: Bool) {
        let appID = state.withLock { s -> String? in
            guard !s.sdkInitialized, let id = s.appID else { return nil }
            s.sdkInitialized = true
            return id
        }
        guard let appID else { return }
        TelemetryDeck.initialize(config: TelemetryDeck.Config(appID: appID))
        if sendLaunchSignal { signal(Signal.appLaunched) }
    }

    // MARK: - Sending

    /// Send a signal. TelemetryDeck parameter values are strings by convention.
    /// Pass a `Signal` constant (`Telemetry.signal(Signal.trialStarted)`) for the
    /// shared vocabulary, or a raw string for one-offs.
    public static func signal(_ name: String, _ parameters: [String: String] = [:]) {
        guard isEnabled else { return }
        TelemetryDeck.signal(name, parameters: parameters)
    }

    /// Bind subsequent signals to a user (pass the Supabase user UUID). Call on
    /// sign-in / session restore. TelemetryDeck hashes it client-side, but the
    /// consuming app's privacy label / `PrivacyInfo.xcprivacy` must still declare
    /// analytics data as linked to the user's identity.
    public static func identify(_ userID: String) {
        guard isEnabled else { return }
        TelemetryDeck.updateDefaultUserID(to: userID)
    }

    /// Clear the bound user. Call on sign-out.
    public static func reset() {
        guard state.withLock({ $0.sdkInitialized }) else { return }
        TelemetryDeck.updateDefaultUserID(to: nil)
    }

    // MARK: - Testing

    /// Test hook: the app ID remembered by `start`, if any.
    static var configuredAppID: String? { state.withLock { $0.appID } }

    /// Test hook: forget `start` state. Does not un-initialize the SDK.
    static func resetStateForTesting() {
        state.withLock { $0 = State() }
    }
}
