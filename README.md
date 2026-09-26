# AppTelemetry

One shared telemetry surface for the App Store family (Ariman, Contrarian,
Lunker, Sextant, Stokked, ThenCam). It vendors the TelemetryDeck SwiftClient, so
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

## Integration

### XcodeGen projects (Sextant)

In `project.yml`, replace the `TelemetryDeck` package with the local package and
depend on `AppTelemetry`:

```yaml
packages:
  AppTelemetry:
    path: ../AppTelemetry
targets:
  Sextant:
    dependencies:
      - package: AppTelemetry
        product: AppTelemetry
```

Then `xcodegen generate`.

### `.xcodeproj` projects (Ariman, Contrarian, Lunker, Stokked, ThenCam)

File → Add Package Dependencies → **Add Local…** → select
`Apps-AppStore/AppTelemetry`. Add the `AppTelemetry` product to the app target
(and to widget/watch targets that log). Remove the old direct SwiftClient
package reference once the migration below is done.

## Per-app migration

Each TelemetryDeck app keeps its **own app ID** — only the plumbing is shared.

| App | Today | Change |
|-----|-------|--------|
| **Sextant** | `TelemetryDeck.initialize` in `SextantApp.init`; own `AppLog` | `Telemetry.start(appID: "7C3B4A88-…")`; delete `Models/AppLog.swift`; keep custom `sync`/`routing` categories via `AppLog.logger(_:)` |
| **Lunker** | same as Sextant (`9F07E2B9-…`) | same; delete `Models/AppLog.swift` |
| **Stokked** | `Analytics.start()` wrapper (`721F6963-…`) | `Telemetry.start(appID: "721F6963-…")`; delete `AnalyticsService.swift` (the guard/no-op is now built in) |
| **ThenCam** | `Analytics.initialize` + string constants (`809BB813-…`) | `Telemetry.start(appID: "809BB813-…")`; map its camelCase names to `Signal.*` |
| **Contrarian** | `TelemetryDeck.initialize` + `updateDefaultUserID` in `AppState` | `Telemetry.start(appID: Config.telemetryDeckAppID)`; swap the 3 `updateDefaultUserID` calls for `Telemetry.identify/reset` |
| **Ariman** | SDK present, **never initialized** | add `Telemetry.start(appID:)` to wire it up, or leave the placeholder ID and it stays a safe no-op |

The `Signal` enum is where naming converges — migrate camelCase/`App.launched`
call sites to the dot-style constants, and promote any name that recurs across
apps into `Signal.swift`.
