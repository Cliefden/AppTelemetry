import Foundation
#if canImport(AuthenticationServices)
import AuthenticationServices
#endif
#if canImport(StoreKit)
import StoreKit
#endif

/// Adopt on an app's own error type so `TelemetryErrors` can classify it
/// without the package knowing the type (Celiador's `Api.ApiError`, Ariman's
/// `APIError`, Contrarian's `ContriaError`).
public protocol TelemetryCodedError: Error {
    /// Low-cardinality code, e.g. `TelemetryErrors.httpCode(404)` → `http404`,
    /// or a fixed case name. Never a message.
    var telemetryCode: String { get }
    /// `true` when this error represents a cancellation. Default `false`.
    var isTelemetryCancellation: Bool { get }
}

extension TelemetryCodedError {
    public var isTelemetryCancellation: Bool { false }
}

/// Error classification shared by every app: one cancellation test and one
/// low-cardinality error code, replacing the per-app copies
/// (Lunker/Sextant/Otta/Ariman `isCancellation`, Celiador `code(for:)`,
/// Equinox `transportErrorCode`, Otta/Ariman `errorCode`).
public enum TelemetryErrors {
    /// `true` for user- or system-initiated cancellations, which are never
    /// failures and must not be reported:
    /// - `CancellationError` (SwiftUI tearing down a `.task`, a superseded request)
    /// - `URLError.cancelled` / `NSURLErrorCancelled`
    /// - `NSUserCancelledError` (Cocoa)
    /// - `ASAuthorizationError.canceled` (1001 — Sign in with Apple sheet dismissed)
    /// - `StoreKitError.userCancelled`
    /// - a `TelemetryCodedError` that says so
    /// The underlying error (`NSUnderlyingErrorKey`) is checked one level deep,
    /// so wrapped transport errors classify the same.
    public static func isCancellation(_ error: Error) -> Bool {
        isCancellation(error, depth: 0)
    }

    private static func isCancellation(_ error: Error, depth: Int) -> Bool {
        if error is CancellationError { return true }
        if let coded = error as? TelemetryCodedError, coded.isTelemetryCancellation { return true }
        if let url = error as? URLError, url.code == .cancelled { return true }
        #if canImport(StoreKit)
        if let store = error as? StoreKitError, case .userCancelled = store { return true }
        #endif
        #if canImport(AuthenticationServices)
        if let auth = error as? ASAuthorizationError, auth.code == .canceled { return true }
        #endif
        let ns = error as NSError
        switch ns.domain {
        case NSURLErrorDomain where ns.code == NSURLErrorCancelled: return true
        case NSCocoaErrorDomain where ns.code == NSUserCancelledError: return true
        case "com.apple.AuthenticationServices.AuthorizationError" where ns.code == 1001: return true
        default: break
        }
        if depth == 0, let underlying = ns.userInfo[NSUnderlyingErrorKey] as? Error {
            return isCancellation(underlying, depth: 1)
        }
        return false
    }

    /// `http<status>` — the house spelling for HTTP failures (`http404`).
    public static func httpCode(_ status: Int) -> String { "http\(status)" }

    /// A short, fixed code for an error — never its message — or `nil` for a
    /// cancellation (see `isCancellation`), which isn't a failure.
    ///
    /// | Code | Errors |
    /// |---|---|
    /// | `offline` | not connected, connection lost, data not allowed, roaming off, call active |
    /// | `timeout` | `URLError.timedOut` |
    /// | `unreachable` | cannot find / connect to host, DNS lookup failed |
    /// | `tls` | secure connection failed, untrusted / bad-date / not-yet-valid / unknown-root certificate |
    /// | `network` | any other `URLError` / `NSURLErrorDomain` error |
    /// | `httpNNN` | via `TelemetryCodedError` + `httpCode(_:)` |
    /// | `decode` / `encode` | `DecodingError` / `EncodingError` |
    /// | `storekit.*` | `StoreKitError` (`network`, `system`, `storefront`, `notEntitled`, `other`) |
    /// | `auth.*` | `ASAuthorizationError` (`failed`, `invalidResponse`, `notHandled`, `notInteractive`, `other`) |
    /// | *custom* | `TelemetryCodedError.telemetryCode` |
    /// | `other` | everything else |
    public static func errorCode(for error: Error) -> String? {
        if isCancellation(error) { return nil }
        if let coded = error as? TelemetryCodedError { return coded.telemetryCode }
        if let url = error as? URLError { return code(for: url.code) }
        if error is DecodingError { return "decode" }
        if error is EncodingError { return "encode" }
        #if canImport(StoreKit)
        if let store = error as? StoreKitError {
            switch store {
            case .networkError: return "storekit.network"
            case .systemError: return "storekit.system"
            case .notAvailableInStorefront: return "storekit.storefront"
            case .notEntitled: return "storekit.notEntitled"
            default: return "storekit.other"
            }
        }
        #endif
        #if canImport(AuthenticationServices)
        if let auth = error as? ASAuthorizationError {
            switch auth.code {
            case .failed: return "auth.failed"
            case .invalidResponse: return "auth.invalidResponse"
            case .notHandled: return "auth.notHandled"
            case .notInteractive: return "auth.notInteractive"
            default: return "auth.other"
            }
        }
        #endif
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain { return code(for: URLError.Code(rawValue: ns.code)) }
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError,
           underlying.domain == NSURLErrorDomain {
            return code(for: URLError.Code(rawValue: underlying.code))
        }
        return "other"
    }

    static func code(for code: URLError.Code) -> String {
        switch code {
        case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed,
             .internationalRoamingOff, .callIsActive:
            return "offline"
        case .timedOut:
            return "timeout"
        case .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed:
            return "unreachable"
        case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
             .serverCertificateNotYetValid, .serverCertificateHasUnknownRoot,
             .clientCertificateRejected, .clientCertificateRequired:
            return "tls"
        default:
            return "network"
        }
    }
}
