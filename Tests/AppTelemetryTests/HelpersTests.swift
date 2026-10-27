import Foundation
import os
import Testing
#if canImport(AuthenticationServices)
import AuthenticationServices
#endif
#if canImport(StoreKit)
import StoreKit
#endif
@testable import AppTelemetry

// MARK: - Fixtures

struct Captured: Sendable, Equatable {
    let name: String
    let parameters: [String: String]
}

/// Runs `body` with `Telemetry.signalSink` capturing every signal. Other
/// suites may emit concurrently (e.g. `app.launched`), so callers filter by
/// the names they care about.
func capturing(_ names: Set<String>, _ body: () throws -> Void) rethrows -> [Captured] {
    let box = OSAllocatedUnfairLock<[Captured]>(initialState: [])
    Telemetry.signalSink.withLock { $0 = { name, params in box.withLock { $0.append(Captured(name: name, parameters: params)) } } }
    defer { Telemetry.signalSink.withLock { $0 = nil } }
    try body()
    return box.withLock { $0 }.filter { names.contains($0.name) }
}

func scratchDefaults() -> UserDefaults {
    let name = "AppTelemetryTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defaults.removePersistentDomain(forName: name)
    return defaults
}

let day: TimeInterval = 86_400
let t0 = Date(timeIntervalSince1970: 1_800_000_000)

// MARK: - Buckets

struct BucketTests {
    @Test(arguments: [
        (-3, "0"), (0, "0"), (1, "1"), (2, "2"), (3, "3-5"), (5, "3-5"),
        (6, "6-20"), (20, "6-20"), (21, "21+"), (10_000, "21+"),
    ])
    func count(_ n: Int, _ expected: String) {
        #expect(TelemetryBuckets.count(n) == expected)
    }

    @Test(arguments: [
        (-5.0, "<1m"), (0, "<1m"), (59.9, "<1m"), (60, "1-5m"), (299, "1-5m"),
        (300, "5-15m"), (899, "5-15m"), (900, "15-60m"), (3_599, "15-60m"),
        (3_600, "1-4h"), (14_399, "1-4h"), (14_400, "4h+"), (1e9, "4h+"),
    ] as [(Double, String)])
    func duration(_ seconds: Double, _ expected: String) {
        #expect(TelemetryBuckets.duration(seconds) == expected)
    }

    @Test func durationEdgeCases() {
        #expect(TelemetryBuckets.duration(.nan) == "<1m")
        #expect(TelemetryBuckets.duration(since: nil) == "unknown")
        #expect(TelemetryBuckets.duration(since: t0, now: t0.addingTimeInterval(400)) == "5-15m")
    }

    @Test(arguments: [
        (-1.0, "<10s"), (0, "<10s"), (9.9, "<10s"), (10, "10-60s"), (59, "10-60s"),
        (60, "1-5m"), (299, "1-5m"), (300, "5-60m"), (3_599, "5-60m"), (3_600, "1h+"),
    ] as [(Double, String)])
    func latency(_ seconds: Double, _ expected: String) {
        #expect(TelemetryBuckets.latency(since: t0, now: t0.addingTimeInterval(seconds)) == expected)
    }

    @Test(arguments: [
        (-2, "0"), (0, "0"), (1, "1-7"), (7, "1-7"), (8, "8-30"), (30, "8-30"), (31, "31+"),
    ])
    func days(_ n: Int, _ expected: String) {
        #expect(TelemetryBuckets.days(n) == expected)
    }

    @Test func daysBetweenDatesFloorsAndClamps() {
        #expect(TelemetryBuckets.days(from: t0, to: t0.addingTimeInterval(day - 1)) == "0")
        #expect(TelemetryBuckets.days(from: t0, to: t0.addingTimeInterval(day)) == "1-7")
        #expect(TelemetryBuckets.days(from: t0, to: t0.addingTimeInterval(7.9 * day)) == "1-7")
        #expect(TelemetryBuckets.days(from: t0, to: t0.addingTimeInterval(-5 * day)) == "0")
    }

    @Test func bucketListsMatchFunctions() {
        let counts = Set([0, 1, 2, 4, 10, 50].map(TelemetryBuckets.count))
        #expect(counts == Set(TelemetryBuckets.countBuckets))
        let durations = Set([0, 120, 600, 1_200, 7_200, 20_000].map { TelemetryBuckets.duration(Double($0)) })
        #expect(durations == Set(TelemetryBuckets.durationBuckets))
        #expect(Set([0, 3, 15, 40].map(TelemetryBuckets.days)) == Set(TelemetryBuckets.dayBuckets))
        #expect(TelemetryBuckets.bool(true) == "true" && TelemetryBuckets.bool(false) == "false")
    }

    /// Every legacy scheme's buckets are unions of the new ones, so existing
    /// dashboards can be rebuilt (the reason for the chosen boundaries).
    @Test func countRefinesEveryLegacyScheme() {
        func lunkerEquinox(_ n: Int) -> String { n < 1 ? "0" : n == 1 ? "1" : n == 2 ? "2" : n <= 5 ? "3-5" : "6+" }
        func otta(_ n: Int) -> String { n < 1 ? "0" : n == 1 ? "1" : n <= 5 ? "2-5" : n <= 20 ? "6-20" : "21+" }
        func celiador(_ n: Int) -> String { n < 1 ? "0" : n == 1 ? "1" : n <= 5 ? "2-5" : "6+" }
        for legacy in [lunkerEquinox, otta, celiador] {
            var map: [String: String] = [:]
            for n in 0...100 {
                let new = TelemetryBuckets.count(n)
                if let old = map[new] { #expect(old == legacy(n), "new bucket \(new) straddles legacy buckets") }
                map[new] = legacy(n)
            }
        }
    }
}

// MARK: - Install date

@Suite(.serialized)
struct InstallDateTests {
    init() { Telemetry.documentsCreationDate = { nil } }

    @Test func freshInstallRecordsNowAndKeepsIt() {
        let defaults = scratchDefaults()
        #expect(Telemetry.recordInstallDateIfNeeded(defaults: defaults, now: t0) == t0)
        #expect(defaults.object(forKey: Telemetry.installDateDefaultsKey) as? Date == t0)
        #expect(Telemetry.recordInstallDateIfNeeded(defaults: defaults, now: t0.addingTimeInterval(40 * day)) == t0)
        #expect(TelemetryBuckets.daysSinceInstall(now: t0.addingTimeInterval(40 * day), defaults: defaults) == "31+")
    }

    @Test(arguments: ["analyticsInstallDate", "telemetry.installDate", "celiador.installDate", "contria.td.firstLaunch"])
    func adoptsLegacyDateKey(_ key: String) {
        let defaults = scratchDefaults()
        defaults.set(t0.addingTimeInterval(-10 * day), forKey: key)
        #expect(Telemetry.recordInstallDateIfNeeded(defaults: defaults, now: t0) == t0.addingTimeInterval(-10 * day))
        #expect(TelemetryBuckets.daysSinceInstall(now: t0, defaults: defaults) == "8-30")
        #expect(defaults.object(forKey: key) != nil, "legacy keys are left in place")
    }

    @Test func adoptsOttaTimeIntervalKey() {
        let defaults = scratchDefaults()
        defaults.set(t0.addingTimeInterval(-3 * day).timeIntervalSince1970, forKey: "analytics.installDate")
        #expect(Telemetry.recordInstallDateIfNeeded(defaults: defaults, now: t0) == t0.addingTimeInterval(-3 * day))
    }

    @Test func earliestLegacyKeyWins() {
        let defaults = scratchDefaults()
        defaults.set(t0.addingTimeInterval(-2 * day), forKey: "telemetry.installDate")
        defaults.set(t0.addingTimeInterval(-50 * day), forKey: "analyticsInstallDate")
        #expect(Telemetry.recordInstallDateIfNeeded(defaults: defaults, now: t0) == t0.addingTimeInterval(-50 * day))
    }

    @Test func existingAnchorBeatsLegacyKeys() {
        let defaults = scratchDefaults()
        defaults.set(t0, forKey: Telemetry.installDateDefaultsKey)
        defaults.set(t0.addingTimeInterval(-50 * day), forKey: "analyticsInstallDate")
        #expect(Telemetry.recordInstallDateIfNeeded(defaults: defaults, now: t0.addingTimeInterval(day)) == t0)
    }

    @Test func futureDatesClampToNow() {
        let defaults = scratchDefaults()
        defaults.set(t0.addingTimeInterval(5 * day), forKey: "telemetry.installDate")
        #expect(Telemetry.recordInstallDateIfNeeded(defaults: defaults, now: t0) == t0)
    }

    @Test func documentsDateIsTheFallback() {
        let defaults = scratchDefaults()
        Telemetry.documentsCreationDate = { t0.addingTimeInterval(-9 * day) }
        defer { Telemetry.documentsCreationDate = { nil } }
        #expect(Telemetry.recordInstallDateIfNeeded(defaults: defaults, now: t0) == t0.addingTimeInterval(-9 * day))
    }

    @Test func garbageLegacyValuesAreIgnored() {
        let defaults = scratchDefaults()
        defaults.set("yesterday", forKey: "telemetry.installDate")
        defaults.set(0.0, forKey: "analytics.installDate")
        #expect(Telemetry.recordInstallDateIfNeeded(defaults: defaults, now: t0) == t0)
    }
}

// MARK: - Errors

struct AppError: TelemetryCodedError {
    var status: Int?
    var cancelled = false
    var telemetryCode: String { status.map(TelemetryErrors.httpCode) ?? "client" }
    var isTelemetryCancellation: Bool { cancelled }
}

struct PlainError: Error {}

struct ErrorTests {
    @Test func cancellationsAreRecognized() {
        var cancellations: [Error] = [
            CancellationError(),
            URLError(.cancelled),
            NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled),
            NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError),
            NSError(domain: "com.apple.AuthenticationServices.AuthorizationError", code: 1001),
            NSError(domain: "Wrapper", code: 1, userInfo: [NSUnderlyingErrorKey: URLError(.cancelled)]),
            AppError(status: nil, cancelled: true),
        ]
        #if canImport(AuthenticationServices)
        cancellations.append(ASAuthorizationError(.canceled))
        #endif
        #if canImport(StoreKit)
        cancellations.append(StoreKitError.userCancelled)
        #endif
        for error in cancellations {
            #expect(TelemetryErrors.isCancellation(error), "\(error)")
            #expect(TelemetryErrors.errorCode(for: error) == nil, "\(error)")
        }
    }

    @Test func failuresAreNotCancellations() {
        let failures: [Error] = [
            URLError(.timedOut), PlainError(), AppError(status: 500),
            NSError(domain: "com.apple.AuthenticationServices.AuthorizationError", code: 1000),
        ]
        for error in failures { #expect(!TelemetryErrors.isCancellation(error), "\(error)") }
    }

    @Test(arguments: [
        (URLError.Code.notConnectedToInternet, "offline"), (.networkConnectionLost, "offline"),
        (.dataNotAllowed, "offline"), (.internationalRoamingOff, "offline"),
        (.timedOut, "timeout"),
        (.cannotFindHost, "unreachable"), (.cannotConnectToHost, "unreachable"), (.dnsLookupFailed, "unreachable"),
        (.secureConnectionFailed, "tls"), (.serverCertificateUntrusted, "tls"), (.serverCertificateHasBadDate, "tls"),
        (.serverCertificateNotYetValid, "tls"), (.serverCertificateHasUnknownRoot, "tls"),
        (.badServerResponse, "network"), (.badURL, "network"),
    ])
    func urlErrorCodes(_ code: URLError.Code, _ expected: String) {
        #expect(TelemetryErrors.errorCode(for: URLError(code)) == expected)
        #expect(TelemetryErrors.errorCode(for: NSError(domain: NSURLErrorDomain, code: code.rawValue)) == expected)
    }

    @Test func otherCodes() throws {
        #expect(TelemetryErrors.errorCode(for: AppError(status: 404)) == "http404")
        #expect(TelemetryErrors.errorCode(for: AppError(status: nil)) == "client")
        #expect(TelemetryErrors.errorCode(for: PlainError()) == "other")
        #expect(TelemetryErrors.errorCode(for: NSError(domain: "x", code: 1, userInfo: [NSUnderlyingErrorKey: URLError(.timedOut)])) == "timeout")
        let decode = #expect(throws: DecodingError.self) { try JSONDecoder().decode(Int.self, from: Data("\"x\"".utf8)) }
        #expect(TelemetryErrors.errorCode(for: try #require(decode)) == "decode")
        #if canImport(StoreKit)
        #expect(TelemetryErrors.errorCode(for: StoreKitError.networkError(URLError(.timedOut))) == "storekit.network")
        #expect(TelemetryErrors.errorCode(for: StoreKitError.notEntitled) == "storekit.notEntitled")
        #endif
        #if canImport(AuthenticationServices)
        #expect(TelemetryErrors.errorCode(for: ASAuthorizationError(.failed)) == "auth.failed")
        #endif
    }
}

// MARK: - Signals

@Suite(.serialized)
struct SignalHelperTests {
    enum Screen: String { case today, settings }

    @Test func screenAndSettings() {
        let got = capturing([Signal.screenViewed, Signal.settingChanged]) {
            Telemetry.screen("today")
            Telemetry.screen(Screen.settings)
            Telemetry.settingChanged("units", "metric")
            Telemetry.settingChanged("alerts", true)
        }
        #expect(got == [
            Captured(name: "screen.viewed", parameters: ["screen": "today"]),
            Captured(name: "screen.viewed", parameters: ["screen": "settings"]),
            Captured(name: "setting.changed", parameters: ["key": "units", "value": "metric"]),
            Captured(name: "setting.changed", parameters: ["key": "alerts", "value": "true"]),
        ])
    }

    @Test func permissions() {
        let got = capturing([Signal.permissionPrompted, Signal.permissionResult]) {
            Telemetry.permissionPrompted("location", context: "onboarding")
            Telemetry.permissionPrompted("notifications")
            Telemetry.permissionResult("location", granted: true, context: "onboarding")
            Telemetry.permissionResult("notifications", granted: false)
            Telemetry.permissionResult("location", result: "restricted")
        }
        #expect(got == [
            Captured(name: "permission.prompted", parameters: ["permission": "location", "context": "onboarding"]),
            Captured(name: "permission.prompted", parameters: ["permission": "notifications"]),
            Captured(name: "permission.result", parameters: ["permission": "location", "result": "granted", "context": "onboarding"]),
            Captured(name: "permission.result", parameters: ["permission": "notifications", "result": "denied"]),
            Captured(name: "permission.result", parameters: ["permission": "location", "result": "restricted"]),
        ])
    }

    @Test func domainErrors() {
        var sent = [Bool]()
        let got = capturing(["error.sync", "error.store"]) {
            sent.append(Telemetry.error("sync", URLError(.timedOut), ["op": "push"]))
            sent.append(Telemetry.error("sync", CancellationError()))
            Telemetry.error("store", code: "http503")
        }
        #expect(sent == [true, false])
        #expect(got == [
            Captured(name: "error.sync", parameters: ["code": "timeout", "op": "push"]),
            Captured(name: "error.store", parameters: ["code": "http503"]),
        ])
    }

    @Test func reportErrorDropsCancellations() {
        let got = capturing([Signal.errorOccurred]) {
            AppLog.reportError("helpers-cancel", CancellationError())
            AppLog.reportError("helpers-cancel", URLError(.cancelled))
            AppLog.reportError("helpers-real", URLError(.timedOut))
        }.filter { $0.parameters["category"]?.hasPrefix("helpers-") == true }
        #expect(got.map { $0.parameters["category"] } == ["helpers-real"])
    }

    @Test func onceFiresOncePerKey() {
        let defaults = scratchDefaults()
        var fired = [Bool]()
        let got = capturing(["milestone.first"]) {
            fired.append(Telemetry.once("first", "milestone.first", ["a": "1"], defaults: defaults))
            fired.append(Telemetry.once("first", "milestone.first", ["a": "2"], defaults: defaults))
            fired.append(Telemetry.once("other", "milestone.first", [:], defaults: defaults))
        }
        #expect(fired == [true, false, true])
        #expect(got == [
            Captured(name: "milestone.first", parameters: ["a": "1"]),
            Captured(name: "milestone.first", parameters: [:]),
        ])
        #expect(defaults.bool(forKey: "AppTelemetry.once.first"))
    }

    @Test func onceHonoursLegacyKey() {
        let defaults = scratchDefaults()
        defaults.set(true, forKey: "contria.td.once.firstChallenge")
        let got = capturing(["firstChallenge", "firstRating"]) {
            #expect(!Telemetry.once("firstChallenge", "firstChallenge", legacyKey: "contria.td.once.firstChallenge", defaults: defaults))
            #expect(Telemetry.once("firstRating", "firstRating", legacyKey: "contria.td.once.firstRating", defaults: defaults))
        }
        #expect(got.map(\.name) == ["firstRating"])
        #expect(defaults.bool(forKey: "AppTelemetry.once.firstChallenge"))
    }

    @Test func firstTimeTodayIsDaily() {
        let defaults = scratchDefaults()
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let morning = cal.date(from: DateComponents(year: 2026, month: 10, day: 27, hour: 8))!
        #expect(Telemetry.firstTimeToday("widgets", now: morning, calendar: cal, defaults: defaults))
        #expect(!Telemetry.firstTimeToday("widgets", now: morning.addingTimeInterval(10 * 3_600), calendar: cal, defaults: defaults))
        #expect(Telemetry.firstTimeToday("alerts", now: morning, calendar: cal, defaults: defaults))
        #expect(Telemetry.firstTimeToday("widgets", now: morning.addingTimeInterval(day), calendar: cal, defaults: defaults))
    }

    @Test func formFunnelLifecycle() {
        let funnel = FormFunnel("rsvp")
        let names: Set = [Signal.formStarted, Signal.formCompleted, Signal.formFailed, Signal.formAbandoned]
        let got = capturing(names) {
            funnel.edited(hasInput: false)      // nothing typed yet
            funnel.edited()                     // started
            funnel.edited(["step": "2"])        // already started
            funnel.failed("network")            // session stays open
            funnel.left()                       // abandoned
            funnel.left()                       // nothing open
            funnel.edited()                     // started again
            funnel.completed(["guests": "2"])   // completed
            funnel.left()                       // nothing open
        }
        #expect(got == [
            Captured(name: "form.started", parameters: ["form": "rsvp"]),
            Captured(name: "form.failed", parameters: ["form": "rsvp", "reason": "network"]),
            Captured(name: "form.abandoned", parameters: ["form": "rsvp"]),
            Captured(name: "form.started", parameters: ["form": "rsvp"]),
            Captured(name: "form.completed", parameters: ["form": "rsvp", "guests": "2"]),
        ])
        #expect(!funnel.isStarted)
    }

    #if canImport(UserNotifications)
    @Test func notificationKinds() {
        let tracker = NotificationOpenTracker(kindUserInfoKey: "lunkerKind") { id in
            id.hasPrefix("bestday-") ? "bestDay" : "period"
        }
        #expect(tracker.kind(identifier: "bestday-1", userInfo: ["lunkerKind": "bestSpot"]) == "bestSpot")
        #expect(tracker.kind(identifier: "bestday-1", userInfo: [:]) == "bestDay")
        #expect(tracker.kind(identifier: "x", userInfo: ["lunkerKind": ""]) == "period")
        #expect(NotificationOpenTracker().kind(identifier: "x", userInfo: [:]) == "other")
        #expect(NotificationOpenTracker().kind(identifier: "x", userInfo: ["telemetry.kind": "wind"]) == "wind")
        let got = capturing([Signal.notificationOpened]) { tracker.record(kind: "bestDay") }
        #expect(got == [Captured(name: "notification.opened", parameters: ["kind": "bestDay"])])
    }
    #endif
}

// MARK: - Test mode & vocabulary

struct TestModeTests {
    @Test(arguments: [
        ("ai.celiador.companion.dev", true), ("ai.celiador.companion.staging", true),
        ("com.x.App.DEV", true), ("ai.celiador.companion", false), ("com.devtools", false),
        ("com.x.development", false),
    ])
    func testChannels(_ id: String, _ expected: Bool) {
        #expect(Telemetry.isTestChannel(bundleID: id) == expected)
    }

    @Test func resolution() {
        #expect(Telemetry.isTestChannel(bundleID: nil) == false)
        #expect(Telemetry.resolveTestMode(nil, bundleID: "a.b.dev") == true)
        #expect(Telemetry.resolveTestMode(nil, bundleID: "a.b") == nil)
        #expect(Telemetry.resolveTestMode(false, bundleID: "a.b.dev") == false)
        #expect(Telemetry.resolveTestMode(true, bundleID: "a.b") == true)
    }
}

struct VocabularyTests {
    /// Names are dashboard identifiers: renaming one breaks continuity.
    @Test func promotedNamesAreStable() {
        #expect(Signal.paywallDismissed == "paywall.dismissed")
        #expect(Signal.purchaseCancelled == "purchase.cancelled")
        #expect(Signal.trialExpired == "trial.expired")
        #expect(Signal.onboardingStarted == "onboarding.started")
        #expect(Signal.onboardingStep == "onboarding.step")
        #expect(Signal.onboardingCompleted == "onboarding.completed")
        #expect(Signal.screenViewed == "screen.viewed")
        #expect(Signal.settingChanged == "setting.changed")
        #expect(Signal.permissionPrompted == "permission.prompted")
        #expect(Signal.permissionResult == "permission.result")
        #expect(Signal.notificationOpened == "notification.opened")
        #expect(Signal.error("sync") == "error.sync")
    }
}
