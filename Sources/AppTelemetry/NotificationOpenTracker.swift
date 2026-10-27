#if canImport(UserNotifications)
import Foundation
import os
import UserNotifications

/// Counts taps on the app's notifications as `notification.opened {kind}`,
/// generalized from Lunker's `NotificationTapTracker` and Sextant's
/// `NotificationOpenTracker`.
///
/// `kind` comes from the notification's `userInfo[kindUserInfoKey]` when the
/// app sets it at scheduling time (preferred — Lunker's pattern), else from
/// `classify(identifier)` (for notifications scheduled by older builds, or
/// apps that encode the kind in the request identifier — Sextant's pattern).
/// Keep kinds low-cardinality.
///
/// As a delegate it implements only `didReceive`, so foreground presentation
/// is unchanged: without a `willPresent` implementation the system behaves as
/// with no delegate (no banner while the app is frontmost). Apps that already
/// own a `UNUserNotificationCenterDelegate` don't install this one; they call
/// `record(_:)` from their own `didReceive` instead.
public final class NotificationOpenTracker: NSObject, UNUserNotificationCenterDelegate, Sendable {
    /// Default `userInfo` key for the notification kind.
    public static let defaultKindUserInfoKey = "telemetry.kind"

    public let kindUserInfoKey: String
    private let classify: @Sendable (String) -> String

    /// - Parameters:
    ///   - kindUserInfoKey: `userInfo` key holding the kind. Lunker: `"lunkerKind"`.
    ///   - classify: maps a request identifier to a kind when `userInfo` has
    ///     none. Default: `"other"`.
    public init(
        kindUserInfoKey: String = NotificationOpenTracker.defaultKindUserInfoKey,
        classify: @escaping @Sendable (_ identifier: String) -> String = { _ in "other" }
    ) {
        self.kindUserInfoKey = kindUserInfoKey
        self.classify = classify
    }

    /// The kind reported for a notification.
    public func kind(identifier: String, userInfo: [AnyHashable: Any]) -> String {
        if let kind = userInfo[kindUserInfoKey] as? String, !kind.isEmpty { return kind }
        return classify(identifier)
    }

    /// Emit `notification.opened {kind}` for a default-action tap (the user
    /// tapped the notification itself — not a custom action or dismiss).
    public func record(_ response: UNNotificationResponse) {
        guard response.actionIdentifier == UNNotificationDefaultActionIdentifier else { return }
        let request = response.notification.request
        record(kind: kind(identifier: request.identifier, userInfo: request.content.userInfo))
    }

    /// Emit `notification.opened {kind}` directly (e.g. from a push handler).
    public func record(kind: String) {
        Telemetry.signal(Signal.notificationOpened, ["kind": kind])
    }

    // MARK: Installing

    private static let installed = OSAllocatedUnfairLock<NotificationOpenTracker?>(initialState: nil)

    /// Make a tracker the notification center's delegate and keep it alive
    /// (the center holds its delegate weakly). Must run before launch finishes
    /// (e.g. in `App.init`) so cold-start taps are delivered.
    @discardableResult
    public static func install(
        kindUserInfoKey: String = defaultKindUserInfoKey,
        classify: @escaping @Sendable (_ identifier: String) -> String = { _ in "other" }
    ) -> NotificationOpenTracker {
        let tracker = NotificationOpenTracker(kindUserInfoKey: kindUserInfoKey, classify: classify)
        installed.withLock { $0 = tracker }
        UNUserNotificationCenter.current().delegate = tracker
        return tracker
    }

    // MARK: UNUserNotificationCenterDelegate

    public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        record(response)
        completionHandler()
    }
}
#endif
