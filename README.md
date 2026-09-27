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

## Integration

Always consume AppTelemetry **by git URL + version**. Xcode Cloud clones only
the app's own repo, so a local `path: ../AppTelemetry` (or Xcode's
"Add Local…") cannot resolve there and the cloud build fails.

### XcodeGen projects

```yaml
packages:
  AppTelemetry:
    url: https://github.com/Cliefden/AppTelemetry.git
    from: "1.0.0"   # use 1.1.0 once tagged (opt-out, SwiftSDK URL)
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

## Privacy

- `AppLog.reportError` logs category/domain/code publicly and the full error
  description as `.private`; TelemetryDeck gets category/domain/code only.
- `Telemetry.identify` sends the Supabase user UUID (hashed client-side by
  TelemetryDeck). Apps that call it must declare analytics data as linked to
  the user in their App Privacy label and `PrivacyInfo.xcprivacy`.

## Development

`swift test` (Swift Testing; needs Xcode 16+ / Swift 6 toolchain).

## Releasing

Changes since `1.0.0` (opt-out, thread safety, `SwiftSDK` URL, no SDK
re-export, private error details) are unreleased. Tag **1.1.0** after commit
and bump consumers' `from:` to pick them up. Note that consumers still on
`1.0.0` get the old `SwiftClient` identity.
