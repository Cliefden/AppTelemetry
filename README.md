# AppTelemetry

One shared telemetry surface for the App Store family (Ariman, Contrarian,
Lunker, Sextant, Stokked, ThenCam). It vendors the TelemetryDeck Swift SDK, so
apps depend on **`AppTelemetry` only** and stop wiring the SDK directly. This
unifies three things that had drifted per-app:

- **Init** — one guarded, no-op-until-configured `Telemetry.start(appID:)`.
- **Errors** — one privacy-preserving `AppLog.reportError` → `error.occurred`.
- **Naming** — one `Signal` vocabulary (dot-style `category.action`).

## API

```swift
import AppTelemetry

// Once, early, in the App's init():
Telemetry.start(appID: "7C3B4A88-…")     // no-op if the ID is a placeholder

// Anywhere:
Telemetry.signal(Signal.trialStarted)
Telemetry.signal(Signal.premiumPurchased, ["product": id])
Telemetry.signal("mob.activated")        // app-specific one-off

// On auth changes (pass the Supabase user UUID):
Telemetry.identify(user.id.uuidString)   // sign-in / session restore
Telemetry.reset()                        // sign-out

// Errors — logs to Console + counts anonymously (category/domain/code only):
AppLog.reportError("sync", error, logger: AppLog.logger("sync"))
```

## Opt-out

The portfolio standard requires a user-facing analytics opt-out. The choice is
persisted in `UserDefaults` (`Telemetry.optOutDefaultsKey`) and respected both
before the SDK is initialized (an opted-out user's launch never initializes
TelemetryDeck) and on every `signal`/`identify`.

```swift
Toggle("Share anonymous usage data", isOn: Binding(
    get: { !Telemetry.isOptedOut },
    set: { Telemetry.setOptedOut(!$0) }
))
```

Opting back in initializes the SDK immediately if `start(appID:)` already ran.
`Telemetry.start` is idempotent and every entry point is thread-safe.

## Helpers (2.1)

Generic helpers that every app had re-implemented. All are additive; every
signal still goes through `Telemetry.signal`, so the opt-out and the
no-op-until-started guard apply.

```swift
// Install anchor + launch
Telemetry.start(appID: id)            // records Telemetry.installDate on first run;
                                      // app.launched now carries {daysSinceInstall}
Telemetry.start(appID: id, testMode: true)   // force TelemetryDeck test mode
Telemetry.installDate                 // Date — one anchor for every app

// Buckets (TelemetryBuckets)
TelemetryBuckets.count(n)             // 0 · 1 · 2 · 3-5 · 6-20 · 21+
TelemetryBuckets.duration(seconds)    // <1m · 1-5m · 5-15m · 15-60m · 1-4h · 4h+
TelemetryBuckets.duration(since: start)        // … or "unknown" for nil
TelemetryBuckets.latency(since: shownAt)       // <10s · 10-60s · 1-5m · 5-60m · 1h+
TelemetryBuckets.daysSinceInstall()   // 0 · 1-7 · 8-30 · 31+
TelemetryBuckets.days(n) / .days(from:to:)     // same day buckets for any gap
TelemetryBuckets.bool(flag)           // "true" / "false"

// Errors (TelemetryErrors)
TelemetryErrors.isCancellation(error) // CancellationError, URLError.cancelled,
                                      // NSUserCancelledError, ASAuthorizationError.canceled,
                                      // StoreKitError.userCancelled (+ one wrapped level)
TelemetryErrors.errorCode(for: error) // nil for cancellations, else offline · timeout ·
                                      // unreachable · tls · network · decode · encode ·
                                      // storekit.* · auth.* · httpNNN (via TelemetryCodedError) · other
extension APIError: TelemetryCodedError {      // teach it your own error type
    var telemetryCode: String { TelemetryErrors.httpCode(status) }   // "http404"
}
Telemetry.error("sync", error, ["op": "push"]) // error.sync {code, op}; drops cancellations
AppLog.reportError("sync", error)     // now also drops cancellations

// Common signals
Telemetry.screen("today")             // screen.viewed {screen}   (or Screen enum)
SomeView().trackScreen(Screen.today)  // same, on every onAppear
Telemetry.settingChanged("units", "metric")    // setting.changed {key, value}
Telemetry.settingChanged("alerts", true)
Telemetry.permissionPrompted("location", context: "onboarding")
Telemetry.permissionResult("location", granted: true, context: "onboarding")
Telemetry.permissionResult("location", result: "restricted")

// Once / daily
Telemetry.once("firstCatch", "catch.first")    // once per install; returns Bool
Telemetry.once("onboarding.signedIn", Signal.onboardingStep, ["step": "signedIn"],
               legacyKey: "celiador.telemetry.onboarding.signedIn")  // don't re-fire after migrating
if Telemetry.firstTimeToday("widgets") { Telemetry.signal("widgets.snapshot", …) }

// Notification taps → notification.opened {kind}
NotificationOpenTracker.install(kindUserInfoKey: "lunkerKind") { id in
    id.hasPrefix("bestday-") ? "bestDay" : "period"   // fallback when userInfo has no kind
}
// …or, if the app already owns the UNUserNotificationCenter delegate:
tracker.record(response)              // from your own didReceive

// Form funnel → form.started / completed / failed {reason} / abandoned
@State private var funnel = FormFunnel("rsvp")
funnel.edited(hasInput: !name.isEmpty); funnel.failed("network"); funnel.completed(); funnel.left()
```

### Install-date anchor

One key, `AppTelemetry.installDate` (`Telemetry.installDateDefaultsKey`),
recorded the first time it is needed (normally by `start`, even for an
opted-out user or a placeholder ID — it never leaves the device). The first
time, it **adopts the earliest legacy key** found, so migrating never resets
tenure to "0":

| Legacy key | App | Stored as |
|---|---|---|
| `analyticsInstallDate` | Lunker | `Date` |
| `telemetry.installDate` | Sextant, Equinox | `Date` |
| `analytics.installDate` | Otta | seconds since 1970 |
| `celiador.installDate` | Celiador | `Date` |
| `contria.td.firstLaunch` | Contrarian | `Date` |

With no legacy key it falls back to the Documents directory's creation date
(iOS/watchOS/visionOS — created on first launch, the proxy Lunker, Sextant,
Otta and Ariman already used), else now. Never in the future. Legacy keys are
left in place.

### Bucket boundaries

Where apps disagreed, the bucket set is the **finest common refinement**, so
every old series can be rebuilt by unioning new buckets (a test enforces this
for `count`):

| Helper | New | Old variants |
|---|---|---|
| `count` | `0, 1, 2, 3-5, 6-20, 21+` | Lunker/Equinox `0,1,2,3-5,6+` · Otta `0,1,2-5,6-20,21+` · Celiador `0,1,2-5,6+` |
| `duration` | `<1m, 1-5m, 5-15m, 15-60m, 1-4h, 4h+` | Sextant identical · Otta `…,60m+` |
| `latency` | `<10s, 10-60s, 1-5m, 5-60m, 1h+` | Celiador identical |
| `daysSinceInstall` / `days` | `0, 1-7, 8-30, 31+` | identical everywhere (whole 24 h periods, floored) |

### Test mode

`start(appID:)` puts TelemetryDeck in test mode for bundle IDs ending in
`.dev` or `.staging` (Celiador's side-by-side dogfood channels), so their
signals stay out of the production view. Otherwise the SDK default applies
(test mode in DEBUG builds). Pass `testMode:` to force it.

### Promoted signal names

Added to `Signal` only where the exact name already appeared in **two or more
apps** (names unchanged, so dashboards keep continuity): `paywallDismissed`,
`purchaseCancelled`, `trialExpired`, `onboardingStarted`, `onboardingStep`,
`onboardingCompleted`, `screenViewed`, `settingChanged`, `permissionPrompted`,
`permissionResult`, `notificationOpened`, plus `Signal.error(domain)` for the
`error.<domain>` convention, and the `form.*` names emitted by `FormFunnel`.
Not promoted: `paywall.viewed` (Equinox, Otta) — it duplicates the existing
`paywall.shown`; those apps should move to `Signal.paywallShown` when they
next touch their paywall. Otta's `settings.changed` differs from the
`setting.changed` the other three apps use.

## Integration

Always consume AppTelemetry **by git URL + version**. Xcode Cloud clones only
the app's own repo, so a local `path: ../AppTelemetry` (or Xcode's
"Add Local…") cannot resolve there and the cloud build fails.

### XcodeGen projects

```yaml
packages:
  AppTelemetry:
    url: https://github.com/Cliefden/AppTelemetry.git
    from: "2.0.0"
targets:
  MyApp:
    dependencies:
      - package: AppTelemetry
        product: AppTelemetry
```

Then `xcodegen generate` and commit the resulting `Package.resolved`
(`*.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`) —
see `xcode-cloud-setup/README.md` for why Xcode Cloud needs it.

### `.xcodeproj` projects

File → Add Package Dependencies → paste
`https://github.com/Cliefden/AppTelemetry.git` → Up to Next Major. Add the
`AppTelemetry` product to the app target (and to widget/watch targets that log).

### TelemetryDeck package URL — remove the direct dependency

AppTelemetry depends on TelemetryDeck via its **canonical URL
`https://github.com/TelemetryDeck/SwiftSDK`** (the repo formerly named
`SwiftClient`; GitHub redirects the old name and both resolve to the same
revisions, e.g. 2.14.1 = `ad4a03e` in every app's `Package.resolved`).

SwiftPM derives a package's identity from the last URL component, so
`SwiftClient` and `SwiftSDK` are two *different* identities that both vend the
`TelemetryDeck` product. An app that keeps its own TelemetryDeck reference while
adopting AppTelemetry fails package resolution (duplicate product/module).
Therefore, **in the same change that adds AppTelemetry**:

1. Remove the app's direct `TelemetryDeck` / `SwiftClient` / `SwiftSDK`
   package reference (and the product from every target).
2. Replace `import TelemetryDeck` with `import AppTelemetry` — the SDK is not
   re-exported; use `Telemetry.*` only.

Apps that still wire TelemetryDeck directly (not yet migrated) should use the
`SwiftSDK` URL too, so that a later migration doesn't mix identities.

## Per-app migration

Each TelemetryDeck app keeps its **own app ID** — only the plumbing is shared.
Status as of 2026-09-26:

| App | Today | Change |
|-----|-------|--------|
| **Sextant** | migrated (git URL `from: 1.0.0`) | commit its `Package.resolved` |
| **ThenCam** | mid-migration, uncommitted, uses a **local path** reference | switch to the git URL before committing, or Xcode Cloud breaks |
| **Svamp** | uses `path: ../AppTelemetry` | switch to the git URL before Xcode Cloud onboarding |
| **Lunker** | `TelemetryDeck.initialize` (`SwiftClient` 2.14.1, `9F07E2B9-…`) | `Telemetry.start(appID:)`; delete `Models/AppLog.swift`; drop direct SDK ref |
| **Stokked** | `Analytics.start()` wrapper (`SwiftSDK`, `721F6963-…`) | `Telemetry.start(appID: "721F6963-…")`; delete `AnalyticsService.swift`; drop direct SDK ref |
| **Contrarian** | `TelemetryDeck.initialize` + `updateDefaultUserID` in `AppState` (`SwiftSDK`) | `Telemetry.start(appID: Config.telemetryDeckAppID)`; swap the 3 `updateDefaultUserID` calls for `Telemetry.identify/reset`; drop direct SDK ref |
| **Otta** | TelemetryDeck direct (`SwiftSDK`) | same pattern |
| **Ariman**, **Equinox** | SDK present (`SwiftClient`); Ariman **never initialized** | add `Telemetry.start(appID:)`, or leave the placeholder ID and it stays a safe no-op; drop direct SDK ref |

The `Signal` enum is where naming converges — migrate camelCase/`App.launched`
call sites to the dot-style constants, and promote any name that recurs across
apps into `Signal.swift`.

### Migrating to the 2.1 helpers

Bump to `from: "2.1.0"` (once tagged), then delete the app's own copy of each
helper. "Value change" marks the places where a parameter's values change, so
the dashboard needs a note (or keep the app's old helper for that one call).

| App | Delete | Replace |
|---|---|---|
| **Lunker** (not yet on AppTelemetry) | `Models/AppLog.swift` (its `AppLog`, `Analytics`, `AnalyticsConsent`); `NotificationTapTracker` in `Models/NotificationManager.swift` (~L402–433) | `Analytics.start()` → `Telemetry.start(appID: "9F07E2B9-…")`. Carry the opt-out over once: `if UserDefaults.standard.object(forKey: "analyticsEnabled") as? Bool == false { Telemetry.setOptedOut(true) }`; `Analytics.setEnabled(x)` → `Telemetry.setOptedOut(!x)`. `Analytics.signal(.x, p)` → `Telemetry.signal("x.y", p)` (keep the `Signal` case names as an app-local `enum LunkerSignal: String` if you like; shared ones → `Signal.*`). `Analytics.screen` / `settingChanged` → `Telemetry.screen` / `settingChanged`. `countBucket` → `TelemetryBuckets.count` (value change: `6+` → `6-20`/`21+`). `daysSinceInstallBucket()` / `bucket(days:)` → `TelemetryBuckets.daysSinceInstall()` / `days(_:)` (`analyticsInstallDate` adopted). `AppLog.isCancellation` → `TelemetryErrors.isCancellation`. `NotificationTapTracker.install()` → `NotificationOpenTracker.install(kindUserInfoKey: "lunkerKind", classify: legacyKind)`. |
| **Sextant** | `Telemetry/AppSignals.swift`, except `PaywallSource` and `notificationKind(identifier:)` (move those next to their call sites) | `start(…, sendLaunchSignal: false)` + `AppSignals.appLaunched()` → `Telemetry.start(appID:)` (the built-in `app.launched` now carries `daysSinceInstall`; `telemetry.installDate` adopted). `durationBucket` → `TelemetryBuckets.duration` (identical). `screen` / `settingChanged` / `permissionResult` → `Telemetry.*` (same names + params). `AppSignals.error(d, e)` → `Telemetry.error(d, e)` (value change: `code` was the numeric `NSError.code`, now `timeout`/`offline`/…; keep `Telemetry.error(d, code: String((e as NSError).code))` for continuity). `isCancellation` → `TelemetryErrors`. `NotificationOpenTracker.install()` → `NotificationOpenTracker.install(classify: notificationKind)`. `isSharingUsageData` → `!Telemetry.isOptedOut`. |
| **Otta** | `ios/Otta/Services/AnalyticsService.swift` | `Analytics.start()` → `Telemetry.start(appID: "F183A35A-…")` (`analytics.installDate` adopted). `screen` → `Telemetry.screen`. `settingChanged` → `Telemetry.settingChanged` (**name change** `settings.changed` → `setting.changed`, aligning with Lunker/Sextant/Equinox; or keep `Telemetry.signal("settings.changed", …)`). `durationBucket` → `TelemetryBuckets.duration` (value change: `60m+` → `1-4h`/`4h+`). `countBucket` → `TelemetryBuckets.count` (value change: `2-5` → `2`/`3-5`). `locationPrompted(context:)` → `Telemetry.permissionPrompted("location", context:)`; `locationResult` keeps its `CLAuthorizationStatus` switch and calls `Telemetry.permissionResult("location", result:, context:)`. `isCancellation` → `TelemetryErrors`. `errorCode` → `TelemetryErrors.errorCode` (value change: `url.-1009` → `offline`; `storekit.*` unchanged; `purchase.*` / `domain.code` → `other`). `error(d, e, extra)` → `Telemetry.error(d, e, extra)`. `setOptedOut(_:currentUserID:)` → `Telemetry.setOptedOut` + re-`identify` at the call site. `bool` → `TelemetryBuckets.bool`. |
| **Equinox** | `Equinox/Analytics.swift`; `installDateKey` + `installDate(now:)` in `EquinoxApp.swift` (~L100–123) | `Analytics.start()` → `Telemetry.start(appID: "EB62BCE1-…", sendLaunchSignal: false)` (keeps its own `app.open`). `Analytics.signal(n, parameters: p)` → `Telemetry.signal(n, p)`. `screen` → `Telemetry.screen`. `flag` → `TelemetryBuckets.bool`. `countBucket` → `TelemetryBuckets.count` (value change: `6+` → `6-20`/`21+`). `daysSinceInstallBucket(installDate: installDate())` → `TelemetryBuckets.daysSinceInstall()` (`telemetry.installDate` adopted, so the almanac back-dating is no longer needed). `transportErrorCode` → `TelemetryErrors.errorCode` (value change: verbose names like `notConnectedToInternet` → `offline`/`timeout`/`unreachable`/`tls`/`network`). `firstTimeToday` → `Telemetry.firstTimeToday` (new key prefix: each daily snapshot re-sends once on upgrade day). `NotificationRouting` can call `NotificationOpenTracker(classify:).record(response)` from its existing delegate. `isOptedOut` setter → `Telemetry.setOptedOut`. |
| **Celiador** (`celiador-ios`, TelemetryDeck direct) | Shrink `Celiador/Telemetry.swift` to the frozen `Event` / `Screen` / `OnboardingStep` / `ErrorDomain` enums (the editor shares the dashboard, so `celiador/*` names stay) | `configure()` → `Telemetry.start(appID: appId, sendLaunchSignal: false)` (test mode for `.dev`/`.staging` is now built in). Carry `celiador.telemetry.enabled == false` over once to `Telemetry.setOptedOut(true)`; `isEnabled` → `!Telemetry.isOptedOut`. `bucket(n)` → `TelemetryBuckets.count` (value change: `2-5` → `2`/`3-5`, `6+` → `6-20`/`21+`). `latency(since:)` → `TelemetryBuckets.latency(since:)` (identical). `daysSinceInstall` → `TelemetryBuckets.daysSinceInstall()` (`celiador.installDate` adopted). `code(for:)` → `TelemetryErrors.errorCode(for:)` with `extension Api.ApiError: TelemetryCodedError { var telemetryCode: String { status.map(TelemetryErrors.httpCode) ?? "client" } }` (identical values). `onboarding(step)` → `Telemetry.once("onboarding.\(step)", Event.onboardingStep.rawValue, …, legacyKey: "celiador.telemetry.onboarding.\(step.rawValue)")`. Keep `trackScreen` local (it sends `celiador/screenViewed`, not `screen.viewed`). |
| **ThenCam** | the `optOutDefaultsKey` / `isOptedOut` guards in `ThenCam/Analytics.swift` (AppTelemetry 2.0 owns the opt-out under the same key) | `Analytics.isOptedOut` → `Telemetry.isOptedOut` / `setOptedOut`. `initialize()` + explicit `appLaunched` → `Telemetry.start(appID: "809BB813-…")` (gains `daysSinceInstall`, anchored on the Documents date). Optionally `reminder.opened` → `NotificationOpenTracker().record(kind: "sceneReminder")` from `SceneReminders`' own delegate (name change; only if you want it in the shared `notification.opened` series). Errors → `Telemetry.error(domain, error)`. |
| **Ariman** | `FormFunnel` (bottom of `Sources/Analytics.swift`); `appLaunched`, `installAgeBucket`, `bucket(days:)`; the redundant `isOptedOut` guards (same key as AppTelemetry) | `FormFunnel` → package `FormFunnel` (same API, same `form.*` names and params). `start()` + `appLaunched()` → `Telemetry.start(appID: "E8F3B7C7-…")` (same Documents-date anchor; `unknown` disappears). `isCancellation` → `TelemetryErrors.isCancellation` with `extension APIError: TelemetryCodedError` (`isTelemetryCancellation`). `errorCode` → `TelemetryErrors.errorCode` (value change: `404` → `http404`, `cannotFindHost` `offline` → `unreachable`, `transport` → `network`), or keep it. `failureReason` / `eventType` stay app-specific. |
| **Stokked** (not yet on AppTelemetry) | `Stocked/Services/AnalyticsService.swift` | `Analytics.start()` → `Telemetry.start(appID: "721F6963-…")` (**name change** `App.launched` → `app.launched`). `Analytics.signal("Auth.signedIn")` etc. → `Telemetry.signal(Signal.signedIn)` / `signedUp` / `passwordResetRequested` (name changes; `Item.created`, `List.created`, `AI.mealPlanRequested`, `Subscription.purchased` → dot-lowercase app strings). Drop the direct `SwiftSDK` package. Wholesale (macOS) is out of scope. |
| **Contrarian** (`ios/`, TelemetryDeck direct) | most of `ios/Sources/Analytics.swift`; keep `launch()` (launch count / `returnVisit` are app-specific) | `TelemetryDeck.signal` / `Analytics.signal` → `Telemetry.signal` (keep the camelCase names — the web client shares them). `Analytics.screen` stays a one-liner over `Telemetry.signal("screenViewed", …)` (not `Telemetry.screen`, which sends `screen.viewed`). `once(name, p)` → `Telemetry.once(name, name, p, legacyKey: "contria.td.once.\(name)")`. `code(for:)` → `extension ContriaError: TelemetryCodedError` + `TelemetryErrors.errorCode` (value change: plain `URLError` `network` → `offline`/`timeout`/…). `daysBucket` → `TelemetryBuckets.days(from:to:)`; `launch()` reads `Telemetry.installDate` (`contria.td.firstLaunch` adopted). Add `Telemetry.start(appID: Config.telemetryDeckAppID)` + `identify`/`reset` as in the 2.0 table. |

## Privacy

- `AppLog.reportError` logs category/domain/code publicly and the full error
  description as `.private`; TelemetryDeck gets category/domain/code only.
- `Telemetry.identify` sends the Supabase user UUID (hashed client-side by
  TelemetryDeck). Apps that call it must declare analytics data as linked to
  the user in their App Privacy label and `PrivacyInfo.xcprivacy`.

## Development

`swift test` (Swift Testing; needs Xcode 16+ / Swift 6 toolchain).

## Changelog

### 2.1.0 (2026-10-27)

Additive — every 2.0 call site compiles unchanged.

- `TelemetryBuckets`: `count`, `duration`, `duration(since:)`, `latency(since:)`,
  `days`, `days(from:to:)`, `daysSinceInstall`, `bool`, plus the bucket lists.
- One install-date anchor: `Telemetry.installDate` /
  `recordInstallDateIfNeeded`, recorded by the first `start`, adopting the
  earliest legacy per-app key (Lunker, Sextant, Equinox, Otta, Celiador,
  Contrarian) or the Documents creation date.
- `TelemetryErrors.isCancellation`, `errorCode(for:)`, `httpCode`, and the
  `TelemetryCodedError` protocol for app error types.
- `Telemetry.screen`, `.trackScreen(_:)`, `settingChanged`, `permissionPrompted`,
  `permissionResult`, `error(_:_:_:)` / `error(_:code:_:)`, `once` (with
  `legacyKey:`), `firstTimeToday`.
- `NotificationOpenTracker` (`notification.opened {kind}`) and `FormFunnel`
  (`form.*`).
- `start(appID:sendLaunchSignal:testMode:)`: TelemetryDeck test mode for
  `.dev` / `.staging` bundle IDs; `Telemetry.testModeOverride`.
- `Signal`: promoted names used by ≥2 apps (see above) + `form.*` +
  `Signal.error(_:)`.
- Behaviour changes (both deliberate, both what the apps' own copies did):
  the built-in `app.launched` now carries `daysSinceInstall`, and
  `AppLog.reportError` ignores cancellations.

## Releasing

**2.0.0** (2026-10-19) — opt-out, thread safety, `SwiftSDK` URL, private
error details, and two breaking changes: TelemetryDeck is **no longer
re-exported** (`import AppTelemetry` no longer exposes TelemetryDeck types) and
user identity goes through `Telemetry.identify/reset`. It is a major bump so
apps on `from: "1.0.0"` keep resolving 1.x until they opt in by moving to
`from: "2.0.0"` (and dropping any direct TelemetryDeck reference — see above).
Consumers still on `1.0.0` get the old `SwiftClient` identity.
