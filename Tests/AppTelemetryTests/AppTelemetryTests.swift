import Foundation
import Testing
import TelemetryDeck
@testable import AppTelemetry

// These tests touch process-global state (Telemetry's start state and the
// opt-out flag in UserDefaults.standard), so they run serially and never call
// `start` with a real ID while opted in — that would initialize the SDK and
// send network traffic.
@Suite(.serialized)
struct TelemetryTests {
    init() {
        Telemetry.resetStateForTesting()
        UserDefaults.standard.removeObject(forKey: Telemetry.optOutDefaultsKey)
    }

    @Test(arguments: ["", "   ", "REPLACE_WITH_APP_ID", "YOUR_APP_ID"])
    func placeholderIDsAreRejected(_ id: String) {
        #expect(!Telemetry.idLooksReal(id))
    }

    @Test func realLookingIDIsAccepted() {
        #expect(Telemetry.idLooksReal("7C3B4A88-0000-0000-0000-000000000000"))
    }

    @Test func placeholderStartStaysDisabled() {
        Telemetry.start(appID: "REPLACE_ME")
        #expect(Telemetry.configuredAppID == nil)
        #expect(!Telemetry.isEnabled)
        // Guarded no-ops must not crash before start.
        Telemetry.signal(Signal.appLaunched)
        Telemetry.identify("user")
        Telemetry.reset()
    }

    @Test func optOutIsPersisted() {
        #expect(!Telemetry.isOptedOut)
        Telemetry.setOptedOut(true)
        #expect(Telemetry.isOptedOut)
        #expect(UserDefaults.standard.bool(forKey: Telemetry.optOutDefaultsKey))
        UserDefaults.standard.removeObject(forKey: Telemetry.optOutDefaultsKey)
        #expect(!Telemetry.isOptedOut)
    }

    @Test func startWhileOptedOutDoesNotInitializeAndIsIdempotent() {
        Telemetry.setOptedOut(true)
        Telemetry.start(appID: "AAAAAAAA-0000-0000-0000-000000000001")
        #expect(Telemetry.configuredAppID == "AAAAAAAA-0000-0000-0000-000000000001")
        #expect(!Telemetry.isEnabled)

        // A second start is ignored; the first real ID wins.
        Telemetry.start(appID: "BBBBBBBB-0000-0000-0000-000000000002")
        #expect(Telemetry.configuredAppID == "AAAAAAAA-0000-0000-0000-000000000001")
        #expect(!Telemetry.isEnabled)
        UserDefaults.standard.removeObject(forKey: Telemetry.optOutDefaultsKey)
    }

    // A standalone Config does not initialize the SDK, so this stays offline.
    @Test func optOutDisablesAndReEnablesALiveSDKConfig() {
        let config = TelemetryDeck.Config(appID: "AAAAAAAA-0000-0000-0000-000000000003")
        #expect(!config.analyticsDisabled)
        Telemetry.applyOptOut(true, to: config)
        #expect(config.analyticsDisabled)
        Telemetry.applyOptOut(false, to: config)
        #expect(!config.analyticsDisabled)
    }

    @Test func concurrentStartIsSafe() async {
        Telemetry.setOptedOut(true)
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<50 {
                group.addTask { Telemetry.start(appID: "ID-\(i)", sendLaunchSignal: false) }
            }
        }
        #expect(Telemetry.configuredAppID?.hasPrefix("ID-") == true)
        #expect(!Telemetry.isEnabled)
        UserDefaults.standard.removeObject(forKey: Telemetry.optOutDefaultsKey)
    }
}

@Suite(.serialized)
struct AppLogTests {
    @Test func errorPayloadHasOnlyCategoryDomainAndCode() {
        let error = NSError(
            domain: "NSURLErrorDomain", code: -1009,
            userInfo: [NSURLErrorFailingURLStringErrorKey: "https://x.test/?token=secret"]
        )
        let params = AppLog.errorParameters("sync", error)
        #expect(params == ["category": "sync", "domain": "NSURLErrorDomain", "code": "-1009"])
    }

    @Test func subsystemOverrideApplies() {
        let original = AppLog.subsystem
        defer { AppLog.subsystem = original }
        _ = AppLog.telemetry // touching a logger first must not freeze the subsystem
        AppLog.subsystem = "com.example.widget"
        #expect(AppLog.subsystem == "com.example.widget")
        // reportError before start is a safe no-op for telemetry.
        AppLog.reportError("test", NSError(domain: "d", code: 1))
    }
}
