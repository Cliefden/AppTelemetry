// swift-tools-version: 6.0
import PackageDescription

// Shared telemetry surface for the Apps-AppStore family (Ariman, Contrarian,
// Lunker, Sextant, Stokked, ThenCam). Vendors the TelemetryDeck Swift SDK so
// individual apps depend on `AppTelemetry` only and never wire the SDK directly.
//
// The SDK is referenced by its canonical URL `TelemetryDeck/SwiftSDK` (the repo
// formerly named `SwiftClient`; GitHub redirects the old URL, and both resolve
// to the same revisions). SwiftPM derives package identity from the last URL
// component, so an app that ALSO lists TelemetryDeck directly under the old
// `SwiftClient` URL gets two identities vending the same `TelemetryDeck`
// product — a resolution error. Apps adopting AppTelemetry must remove their
// direct TelemetryDeck package reference in the same change (see README).
let package = Package(
    name: "AppTelemetry",
    platforms: [
        .iOS(.v17),
        .watchOS(.v10),
        .macOS(.v14),
        .visionOS(.v1),
    ],
    products: [
        .library(name: "AppTelemetry", targets: ["AppTelemetry"]),
    ],
    dependencies: [
        .package(url: "https://github.com/TelemetryDeck/SwiftSDK", from: "2.14.1"),
    ],
    targets: [
        .target(
            name: "AppTelemetry",
            dependencies: [
                .product(name: "TelemetryDeck", package: "SwiftSDK"),
            ]
        ),
        .testTarget(
            name: "AppTelemetryTests",
            dependencies: [
                "AppTelemetry",
                .product(name: "TelemetryDeck", package: "SwiftSDK"),
            ]
        ),
    ]
)
