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

    // Promoted in 2.1 — each name already appears in at least two apps
    // (survey 2026-10-27). Names are unchanged so dashboards keep continuity.

    /// `{source}` — Sextant, Equinox, Otta.
    public static let paywallDismissed = "paywall.dismissed"
    /// Equinox, Sextant.
    public static let purchaseCancelled = "purchase.cancelled"
    /// Lunker, Sextant, Equinox.
    public static let trialExpired = "trial.expired"

    /// Lunker, Sextant, Equinox.
    public static let onboardingStarted = "onboarding.started"
    /// `{step}` — Sextant, Equinox, Otta.
    public static let onboardingStep = "onboarding.step"
    /// Lunker, Sextant, Equinox, Otta.
    public static let onboardingCompleted = "onboarding.completed"

    /// `{screen}` — emitted by `Telemetry.screen(_:)`. Lunker, Sextant, Otta, Equinox.
    public static let screenViewed = "screen.viewed"
    /// `{key, value}` — emitted by `Telemetry.settingChanged(_:_:)`. Lunker, Sextant, Equinox.
    public static let settingChanged = "setting.changed"
    /// `{permission, context?}` — emitted by `Telemetry.permissionPrompted`. Lunker, Otta.
    public static let permissionPrompted = "permission.prompted"
    /// `{permission, result, context?}` — emitted by `Telemetry.permissionResult`. Lunker, Sextant, Otta, Equinox.
    public static let permissionResult = "permission.result"
    /// `{kind}` — emitted by `NotificationOpenTracker`. Lunker, Sextant, Equinox.
    public static let notificationOpened = "notification.opened"

    // Form funnel (emitted by FormFunnel — generalized from Ariman)
    public static let formStarted = "form.started"
    public static let formCompleted = "form.completed"
    public static let formFailed = "form.failed"
    public static let formAbandoned = "form.abandoned"

    // Errors (emitted by AppLog.reportError — see AppLog.swift)
    public static let errorOccurred = "error.occurred"

    /// `error.<domain> {code, …}` — emitted by `Telemetry.error(_:_:_:)`, the
    /// per-domain error convention used by Sextant, Otta, Ariman and Contrarian.
    public static func error(_ domain: String) -> String { "error.\(domain)" }
}
