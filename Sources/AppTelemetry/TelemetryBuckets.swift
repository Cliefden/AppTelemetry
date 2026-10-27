import Foundation

/// Low-cardinality buckets for TelemetryDeck parameters, so small numbers,
/// exact durations or precise tenure never fingerprint anyone.
///
/// The boundaries were chosen by comparing the copies they replace
/// (survey 2026-10-27). Where apps disagreed, the bucket set is the *finest
/// common refinement* of all of them, so every existing dashboard series can
/// be rebuilt by unioning new buckets — no app loses continuity:
///
/// | Helper | Values | Replaces |
/// |---|---|---|
/// | `count` | `0` `1` `2` `3-5` `6-20` `21+` | Lunker/Equinox `0,1,2,3-5,6+` (6+ = 6-20 ∪ 21+); Otta `0,1,2-5,6-20,21+` (2-5 = 2 ∪ 3-5); Celiador `0,1,2-5,6+` |
/// | `duration` | `<1m` `1-5m` `5-15m` `15-60m` `1-4h` `4h+` | Sextant (identical); Otta `…,60m+` (= 1-4h ∪ 4h+) |
/// | `latency` | `<10s` `10-60s` `1-5m` `5-60m` `1h+` | Celiador (identical) |
/// | `days` / `daysSinceInstall` | `0` `1-7` `8-30` `31+` | identical in Lunker, Sextant, Otta, Equinox, Celiador, Ariman, Contrarian |
public enum TelemetryBuckets {
    /// Every value `count(_:)` can return, in order.
    public static let countBuckets = ["0", "1", "2", "3-5", "6-20", "21+"]
    /// Every value `duration(_:)` can return, in order.
    public static let durationBuckets = ["<1m", "1-5m", "5-15m", "15-60m", "1-4h", "4h+"]
    /// Every value `latency(since:now:)` can return, in order.
    public static let latencyBuckets = ["<10s", "10-60s", "1-5m", "5-60m", "1h+"]
    /// Every value `days(_:)` / `daysSinceInstall` can return, in order.
    public static let dayBuckets = ["0", "1-7", "8-30", "31+"]

    /// Small counts: `0`, `1`, `2`, `3-5`, `6-20`, `21+`. Negative → `0`.
    public static func count(_ n: Int) -> String {
        switch n {
        case ..<1: return "0"
        case 1: return "1"
        case 2: return "2"
        case 3...5: return "3-5"
        case 6...20: return "6-20"
        default: return "21+"
        }
    }

    /// Time spent in a feature / session: `<1m`, `1-5m`, `5-15m`, `15-60m`,
    /// `1-4h`, `4h+`. Negative or NaN → `<1m`.
    public static func duration(_ seconds: TimeInterval) -> String {
        let s = seconds.isNaN ? 0 : max(0, seconds)
        switch s {
        case ..<60: return "<1m"
        case ..<300: return "1-5m"
        case ..<900: return "5-15m"
        case ..<3_600: return "15-60m"
        case ..<14_400: return "1-4h"
        default: return "4h+"
        }
    }

    /// Duration since `start`, or `unknown` when there is no start.
    public static func duration(since start: Date?, now: Date = Date()) -> String {
        guard let start else { return "unknown" }
        return duration(now.timeIntervalSince(start))
    }

    /// How long the user took to act on something (an approval card, a
    /// question): `<10s`, `10-60s`, `1-5m`, `5-60m`, `1h+`.
    public static func latency(since start: Date, now: Date = Date()) -> String {
        let s = max(0, now.timeIntervalSince(start))
        switch s {
        case ..<10: return "<10s"
        case ..<60: return "10-60s"
        case ..<300: return "1-5m"
        case ..<3_600: return "5-60m"
        default: return "1h+"
        }
    }

    /// Whole days: `0`, `1-7`, `8-30`, `31+`. Negative → `0`.
    public static func days(_ days: Int) -> String {
        switch days {
        case ..<1: return "0"
        case 1...7: return "1-7"
        case 8...30: return "8-30"
        default: return "31+"
        }
    }

    /// Whole days elapsed between two dates (24 h periods, floored, never negative).
    public static func days(from start: Date, to end: Date) -> String {
        let elapsed = end.timeIntervalSince(start)
        return days(elapsed > 0 ? Int(elapsed / 86_400) : 0)
    }

    /// Days since `Telemetry.installDate` (the single install anchor; recorded
    /// on first access / first `Telemetry.start`): `0`, `1-7`, `8-30`, `31+`.
    public static func daysSinceInstall(now: Date = Date(), defaults: UserDefaults = .standard) -> String {
        days(from: Telemetry.recordInstallDateIfNeeded(defaults: defaults, now: now), to: now)
    }

    /// `"true"` / `"false"` — TelemetryDeck parameter values are strings.
    public static func bool(_ value: Bool) -> String { value ? "true" : "false" }
}
