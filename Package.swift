// swift-tools-version: 6.2
import PackageDescription

/// The same upcoming language features as the pingfront SDK (pingfront-ios).
let upcoming: [SwiftSetting] = [
    .enableUpcomingFeature("NonisolatedNonsendingByDefault"),  // SE-0461
    .enableUpcomingFeature("InferIsolatedConformances"),  // SE-0470
    .enableUpcomingFeature("ExistentialAny"),  // SE-0335
    .enableUpcomingFeature("MemberImportVisibility"),  // SE-0444
    .enableUpcomingFeature("InternalImportsByDefault"),  // SE-0409
]

/// The pingfront adapter for RevenueCat.
///
/// Offerings become offer slots, RevenueCat paywalls open from offer cards.
/// It is its own package, so an app that adds it fetches RevenueCat and nothing from the other vendors.
let package = Package(
    name: "PingFrontRevenueCat",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "PingFrontRevenueCat", targets: ["PingFrontRevenueCat"])
    ],
    dependencies: [
        .package(url: "https://github.com/pingfront/pingfront-ios", from: "1.0.0"),
        .package(url: "https://github.com/pingfront/pingfront-ios-adapter-kit", from: "1.0.0"),
        // Current stable major, as built and tested here: purchases-ios 5.
        .package(url: "https://github.com/RevenueCat/purchases-ios.git", from: "5.100.0"),
    ],
    targets: [
        .target(
            name: "PingFrontRevenueCat",
            dependencies: [
                .product(name: "PingFrontAdapterKit", package: "pingfront-ios-adapter-kit"),
                .product(name: "PingFrontCore", package: "pingfront-ios"),
                .product(name: "RevenueCat", package: "purchases-ios"),
                .product(name: "RevenueCatUI", package: "purchases-ios"),
            ],
            swiftSettings: upcoming
        ),
        .testTarget(
            name: "PingFrontRevenueCatTests",
            dependencies: [
                "PingFrontRevenueCat",
                .product(name: "PingFrontAdapterKit", package: "pingfront-ios-adapter-kit"),
                .product(name: "PingFrontAdapterTestSupport", package: "pingfront-ios-adapter-kit"),
                .product(name: "PingFrontCore", package: "pingfront-ios"),
                .product(name: "RevenueCat", package: "purchases-ios"),
            ],
            swiftSettings: upcoming
        ),
    ],
    swiftLanguageModes: [.v6]
)
