import PingFrontAdapterKit
public import PingFrontCore

/// Options for the RevenueCat adapter.
public struct RevenueCatOptions: Sendable {
    /// The offering identifiers to report as offer slots, in this order. `nil` reports every offering, the current one
    /// first.
    public var offerings: [String]?
    /// Presents the RevenueCat paywall (RevenueCatUI) for offerings that have a published paywall.
    public var presentsPaywalls: Bool
    /// Shows your own paywall for an offer card and returns what happened.
    ///
    /// Called for offerings without a RevenueCat paywall, for cards that match no offering, and for every card when
    /// RevenueCat does not complete purchases (`purchasesAreCompletedBy: .myApp`). Without it, an offering without a
    /// paywall buys its first package.
    public var onOffer: (@MainActor @Sendable (OfferRequest) async -> OfferOutcome)?

    /// Creates options.
    public init(
        offerings: [String]? = nil, presentsPaywalls: Bool = true,
        onOffer: (@MainActor @Sendable (OfferRequest) async -> OfferOutcome)? = nil
    ) {
        self.offerings = offerings
        self.presentsPaywalls = presentsPaywalls
        self.onOffer = onOffer
    }
}

extension PingFrontModule {
    /// RevenueCat with the default options.
    public static var revenueCat: PingFrontModule { revenueCat(RevenueCatOptions()) }

    /// RevenueCat: offerings become offer slots, offer cards open the offering's paywall, and the customer's
    /// entitlements become the person's entitlement.
    ///
    /// - Configure RevenueCat (`Purchases.configure`) before or right after pingfront; the adapter waits for it.
    /// - Sets the subscriber attribute `pingfront_token` to `PingFront.shared.storeAccountToken`, so RevenueCat
    ///   webhooks match the person even when `app_user_id` is your own id.
    /// - Purchases go through RevenueCat, which finishes them; with `purchasesAreCompletedBy: .myApp` the adapter
    ///   never buys and calls `onOffer` instead. It never finishes a transaction itself.
    /// - Promotional offers on cards are signed by RevenueCat with the In-App Purchase key uploaded to RevenueCat.
    /// - It reports no store events: the RevenueCat webhook delivers them.
    ///
    /// - Parameter options: Which offerings to report and how cards open.
    /// - Returns: The module, for `config.use(_:)`.
    public static func revenueCat(_ options: RevenueCatOptions) -> PingFrontModule {
        PingFrontModule(id: "pingfront.revenuecat") { context in
            let adapter = RevenueCatAdapter(client: RevenueCatLive(), host: ContextHost(context), options: options)
            context.setOfferHandler(adapter)
            context.run { await adapter.run() }
        }
    }
}
