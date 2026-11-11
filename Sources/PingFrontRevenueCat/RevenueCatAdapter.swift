import Foundation
import PingFrontAdapterKit
import PingFrontCore
import os

/// Reports RevenueCat offerings as offer slots and the customer's entitlements as the person's entitlement, sets the
/// `pingfront_token` subscriber attribute, and handles offer cards.
@MainActor final class RevenueCatAdapter: OfferHandling {
    /// The subscriber attribute the server matches RevenueCat webhooks on.
    static let tokenAttribute = "pingfront_token"

    private let client: any RevenueCatClient
    private let host: any AdapterHost
    private let options: RevenueCatOptions
    private let sleep: Sleep
    private let log = AdapterLog.logger("revenuecat")
    let slots: SlotPublisher
    /// `nil` until offerings load: nothing is reported before, so a failed load never clears the slots.
    private(set) var offerings: [RCOffering]?
    /// `nil` until customer info arrives: no entitlement is reported before.
    private(set) var state: AccessState?
    /// The `pingfront_token` value last set, if any.
    private(set) var sentToken: String?

    init(client: any RevenueCatClient, host: any AdapterHost, options: RevenueCatOptions, sleep: @escaping Sleep = liveSleep) {
        self.client = client
        self.host = host
        self.options = options
        self.sleep = sleep
        slots = SlotPublisher(host: host, source: .revenuecat)
    }

    /// Runs until cancelled: waits for `Purchases.configure`, then follows the token and the customer info.
    func run() async {
        guard await Readiness.wait(until: { [client] in client.isConfigured }, sleep: sleep) else {
            log.error("RevenueCat is not configured, so the adapter is idle. Call Purchases.configure before PingFront.configure.")
            return
        }
        async let tokens: Void = watchTokens()
        await refreshOfferings()
        for await info in client.customerInfoUpdates() { await customerChanged(info) }
        await tokens
    }

    private func watchTokens() async {
        for await token in host.storeAccountTokenChanges() { tokenChanged(token) }
    }

    /// Sets `pingfront_token` to the person's token, and removes it when they log out.
    func tokenChanged(_ token: UUID?) {
        guard let token else {
            if sentToken != nil {
                client.setAttributes([Self.tokenAttribute: ""])
                sentToken = nil
            }
            return
        }
        let value = tokenString(token)
        guard value != sentToken else { return }
        client.setAttributes([Self.tokenAttribute: value])
        sentToken = value
        // A new person: report what RevenueCat knows again.
        if offerings != nil { slots.publish(makeSlots(), force: true) }
        if let entitlement = entitlement() { host.setEntitlement(entitlement) }
    }

    func customerChanged(_ info: AccessState) async {
        state = info
        if let entitlement = entitlement() { host.setEntitlement(entitlement) }
        await refreshOfferings()
    }

    func refreshOfferings() async {
        do {
            offerings = try await client.offerings()
        } catch {
            log.error("Could not load offerings: \(String(describing: error), privacy: .private)")
        }
        if offerings != nil { slots.publish(makeSlots()) }
    }

    func entitlement() -> Entitlement? { state.map { EntitlementRules.entitlement(from: $0.access, source: .revenuecat) } }

    /// One slot per offering (or per configured offering, in that order).
    func makeSlots() -> [OfferSlot] {
        let loaded = offerings ?? []
        let owned = state?.owned ?? []
        let chosen = options.offerings.map { ids in ids.compactMap { id in loaded.first { $0.id == id } } } ?? loaded
        return chosen.map { offering in
            OfferSlot(
                id: SlotRules.id(offering.id), title: SlotRules.title(offering.title, fallback: offering.id), kind: offering.kind,
                isAvailable: SlotRules.isAvailable(products: offering.packages.map(\.productId), owned: owned),
                products: offering.packages.map { SlotRules.product(id: $0.productId, price: $0.price, period: $0.period, trial: $0.trial) }
            )
        }
    }

    func handle(_ request: OfferRequest) async -> OfferOutcome {
        let onOffer = options.onOffer
        return await handle(CardTap(request)) { await onOffer?(request) }
    }

    func handle(_ card: CardTap, app: AppOfferHandler) async -> OfferOutcome {
        guard client.isConfigured else { return await fallback(app, reason: "RevenueCat is not configured") }
        // Without RevenueCat completing purchases, the app's own code buys and finishes transactions.
        guard client.completesPurchases else { return await fallback(app, reason: "purchasesAreCompletedBy is .myApp") }
        if card.storeOffer?.kind == .code { return await client.presentCodeRedemption() }
        if offerings == nil { await refreshOfferings() }
        guard let offering = offerings?.first(where: { SlotRules.id($0.id) == card.offerId }) else {
            return await fallback(app, reason: "no offering matches the card")
        }
        if let purchase = Self.storeOfferPurchase(card.storeOffer, in: offering) { return await client.purchase(purchase) }
        if options.presentsPaywalls, offering.hasPaywall { return await client.presentPaywall(offeringId: offering.id) }
        if let outcome = await app() { return outcome }
        guard let first = offering.packages.first else { return .unavailable }
        return await client.purchase(RCPurchase(offeringId: offering.id, packageId: first.id, productId: first.productId))
    }

    private func fallback(_ app: AppOfferHandler, reason: String) async -> OfferOutcome {
        if let outcome = await app() { return outcome }
        log.error("Offer card not shown: \(reason, privacy: .public). Set RevenueCatOptions.onOffer to show your own paywall.")
        return .unavailable
    }

    /// The purchase that redeems the card's store offer, or `nil` to open the paywall instead.
    ///
    /// Promotional and win-back offers go through RevenueCat; an intro offer is a plain purchase the store discounts.
    static func storeOfferPurchase(_ offer: StoreOffer?, in offering: RCOffering) -> RCPurchase? {
        guard let offer else { return nil }
        let choice: RCOfferChoice
        switch offer.kind {
        case .promotional: choice = .promotional(offer.id)
        case .winback: choice = .winBack(offer.id)
        case .intro: choice = .none
        case .code, .unknown: return nil
        // An offer kind a later SDK adds opens the paywall until this adapter learns it.
        @unknown default: return nil
        }
        let named = offer.productId.flatMap { productId in offering.packages.first { $0.productId == productId } }
        let carrying = offer.kind == .promotional ? offering.packages.first { $0.promotionalOfferIds.contains(offer.id) } : nil
        if let package = named ?? carrying {
            return RCPurchase(offeringId: offering.id, packageId: package.id, productId: package.productId, offer: choice)
        }
        // A product outside the offering is bought by id.
        if let productId = offer.productId { return RCPurchase(offeringId: offering.id, productId: productId, offer: choice) }
        return nil
    }
}
