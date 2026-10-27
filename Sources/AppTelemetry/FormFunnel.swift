import Foundation
import os

/// Start / complete / fail / abandon funnel for one form instance,
/// generalized from Ariman (`form` ∈ rsvp, booking, job, gallery there).
///
/// A "form session" begins at the first edit with input and ends on success or
/// when the user leaves the screen:
/// - `edited(hasInput:)` → `form.started {form}` once per session
/// - `completed()` → `form.completed {form}` and ends the session
/// - `failed(reason)` → `form.failed {form, reason}`; the session stays open
///   (the user may retry, or leave → abandoned)
/// - `left()` → `form.abandoned {form}` if a session was open
///
/// Keep one instance per form screen (e.g. `@State private var funnel = FormFunnel("rsvp")`).
/// Thread-safe.
public final class FormFunnel: Sendable {
    public let form: String
    private let started = OSAllocatedUnfairLock(initialState: false)

    public init(_ form: String) { self.form = form }

    /// `true` between the first edit and completion / leaving.
    public var isStarted: Bool { started.withLock { $0 } }

    /// Call whenever any field changes; fires `form.started` once per session.
    public func edited(hasInput: Bool = true, _ extra: [String: String] = [:]) {
        guard hasInput else { return }
        let first = started.withLock { s -> Bool in
            guard !s else { return false }
            s = true
            return true
        }
        if first { Telemetry.signal(Signal.formStarted, params(extra)) }
    }

    /// Successful submit.
    public func completed(_ extra: [String: String] = [:]) {
        started.withLock { $0 = false }
        Telemetry.signal(Signal.formCompleted, params(extra))
    }

    /// Failed submit. `reason` must be low-cardinality (e.g. `network`,
    /// `server`, `auth`, `rejected`, or `TelemetryErrors.errorCode(for:)`).
    public func failed(_ reason: String, _ extra: [String: String] = [:]) {
        Telemetry.signal(Signal.formFailed, params(extra.merging(["reason": reason]) { $1 }))
    }

    /// Call when the form's screen goes away; fires `form.abandoned` if the
    /// user had started but never submitted successfully.
    public func left(_ extra: [String: String] = [:]) {
        let wasStarted = started.withLock { s -> Bool in
            defer { s = false }
            return s
        }
        if wasStarted { Telemetry.signal(Signal.formAbandoned, params(extra)) }
    }

    private func params(_ extra: [String: String]) -> [String: String] {
        extra.merging(["form": form]) { $1 }
    }
}
