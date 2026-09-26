import Foundation

/// The shared signal vocabulary. Standardizing the names is the whole point of
/// this module: today Sextant/Lunker use dot-style (`trial.started`), ThenCam
/// and Contrarian use camelCase (`trialStarted`), Stokked uses `App.launched`.
/// Dot-namespaced `category.action` is TelemetryDeck-idiomatic, so that's the
/// house convention. Add app-specific names as raw strings at call sites; when a
/// name recurs across apps, promote it here.
public enum Signal {
    // Lifecycle
    public static let appLaunched = "app.launched"

    // Auth (bind identity with Telemetry.identify / reset separately)
    public static let signedIn = "user.signedIn"
    public static let signedUp = "user.signedUp"
    public static let signedOut = "user.signedOut"
    public static let passwordResetRequested = "user.passwordResetRequested"

    // Monetization funnel
    public static let paywallShown = "paywall.shown"
    public static let purchaseStarted = "purchase.started"
    public static let trialStarted = "trial.started"
    public static let premiumPurchased = "premium.purchased"
    public static let premiumRestored = "premium.restored"
    public static let purchaseFailed = "purchase.failed"

    // Errors (emitted by AppLog.reportError — see AppLog.swift)
    public static let errorOccurred = "error.occurred"
}
