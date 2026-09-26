// swift-tools-version: 5.9
import PackageDescription

// Shared telemetry surface for the Apps-AppStore family (Ariman, Contrarian,
// Lunker, Sextant, Stokked, ThenCam). Vendors the TelemetryDeck SwiftClient so
// individual apps depend on `AppTelemetry` only and never wire the SDK directly.
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
        .package(url: "https://github.com/TelemetryDeck/SwiftClient", from: "2.14.1"),
    ],
    targets: [
        .target(
            name: "AppTelemetry",
            dependencies: [
                .product(name: "TelemetryDeck", package: "SwiftClient"),
            ]
        ),
    ]
)
