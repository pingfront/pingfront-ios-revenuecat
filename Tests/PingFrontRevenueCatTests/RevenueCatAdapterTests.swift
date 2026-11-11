import Foundation
import PingFrontAdapterKit
import PingFrontAdapterTestSupport
import PingFrontCore
import Testing

@testable import PingFrontRevenueCat

@Suite("RevenueCat adapter")
@MainActor struct RevenueCatAdapterTests {
    let client = FakeRevenueCat()
    let host = FakeHost()

    func adapter(_ options: RevenueCatOptions = RevenueCatOptions()) -> RevenueCatAdapter {
        RevenueCatAdapter(client: client, host: host, options: options, sleep: noSleep)
    }

    // MARK: Offer slots

    @Test("Each offering becomes a slot: id, title, kind, products, availability")
    func slots() async {
        client.offeringsResult = [.annual, .plain]
        let adapter = adapter()
        await adapter.customerChanged(AccessState(owned: ["pro.monthly"]))
        let slots = host.lastOffers ?? []
        #expect(slots.map(\.id) == ["annual_sale", "default"])
        #expect(slots[0].title == "Annual sale")
        #expect(slots[0].kind == .discount)
        #expect(
            slots[0].products == [
                OfferSlot.Product(id: "pro.annual", price: "€29.99", period: "P1Y", trial: "P1W"),
                OfferSlot.Product(id: "pro.monthly", price: "€4.99", period: "P1M"),
            ])
        #expect(slots[0].isAvailable)
        // The person owns the only product in "default"; a blank description falls back to the identifier.
        #expect(!slots[1].isAvailable)
        #expect(slots[1].title == "default")
        #expect(adapter.slots.source == .revenuecat)
    }

    @Test("Configured offerings are reported in their order; unknown ones are skipped")
    func chosenOfferings() async {
        client.offeringsResult = [.annual, .plain]
        let adapter = adapter(RevenueCatOptions(offerings: ["default", "missing", "annual_sale"]))
        await adapter.refreshOfferings()
        #expect(host.lastOffers?.map(\.id) == ["default", "annual_sale"])
    }

    @Test("Nothing is reported before offerings and customer info load, so a failed load never clears them")
    func nothingBeforeLoad() async {
        client.offeringsFail = true
        let adapter = adapter()
        await adapter.refreshOfferings()
        adapter.tokenChanged(sampleToken)
        #expect(host.offers.isEmpty)
        #expect(host.entitlements.isEmpty)
        client.offeringsFail = false
        client.offeringsResult = [.plain]
        await adapter.refreshOfferings()
        client.offeringsFail = true
        await adapter.refreshOfferings()
        #expect(host.offers.count == 1)
        #expect(host.lastOffers?.map(\.id) == ["default"])
    }

    // MARK: Entitlement

    @Test("Customer info maps to the entitlement with source revenuecat")
    func entitlement() async {
        let adapter = adapter()
        let renews = Date(timeIntervalSince1970: 1_800_000_000)
        await adapter.customerChanged(
            AccessState(access: [AccessSnapshot(productId: "pro.annual", isActive: true, isTrial: true, expiresAt: renews)]))
        await adapter.customerChanged(AccessState(access: [AccessSnapshot(productId: "pro.annual", isActive: true, willRenew: false)]))
        await adapter.customerChanged(AccessState(access: [AccessSnapshot(productId: "pro.annual", isActive: true, hasBillingIssue: true)]))
        await adapter.customerChanged(AccessState(access: [AccessSnapshot(productId: "lifetime", isActive: true, isLifetime: true)]))
        await adapter.customerChanged(AccessState())
        #expect(host.entitlements.map(\.state) == [.trial, .cancelled, .billingRetry, .lifetime, .none])
        #expect(host.entitlements[0] == Entitlement(state: .trial, productId: "pro.annual", renewsAt: renews, source: .revenuecat))
        #expect(host.entitlements.allSatisfy { $0.source == .revenuecat })
    }

    // MARK: Identity

    @Test("pingfront_token is set to the lowercase store account token, once per person")
    func token() {
        let adapter = adapter()
        adapter.tokenChanged(nil)
        #expect(client.attributes.isEmpty)
        adapter.tokenChanged(sampleToken)
        adapter.tokenChanged(sampleToken)
        #expect(client.attributes == [["pingfront_token": "6f1c2b9e-0d4a-4c7b-9e2f-1a2b3c4d5e6f"]])
        #expect(adapter.sentToken == "6f1c2b9e-0d4a-4c7b-9e2f-1a2b3c4d5e6f")
    }

    @Test("Logout removes pingfront_token; the next person's token replaces it")
    func logout() {
        let adapter = adapter()
        adapter.tokenChanged(sampleToken)
        adapter.tokenChanged(nil)
        let next = UUID()
        adapter.tokenChanged(next)
        #expect(client.attributes.map { $0["pingfront_token"] } == [tokenString(sampleToken), "", tokenString(next)])
    }

    @Test("A new person gets the slots and entitlement again")
    func republishes() async {
        client.offeringsResult = [.plain]
        let adapter = adapter()
        await adapter.customerChanged(AccessState(access: [AccessSnapshot(productId: "pro.monthly", isActive: true)]))
        let (offers, entitlements) = (host.offers.count, host.entitlements.count)
        adapter.tokenChanged(sampleToken)
        #expect(host.offers.count == offers + 1)
        #expect(host.entitlements.count == entitlements + 1)
        #expect(host.entitlements.last == Entitlement(state: .active, productId: "pro.monthly", source: .revenuecat))
    }

    // MARK: Run loop

    @Test("run waits for Purchases.configure, then sets the token and reports slots and entitlement")
    func runs() async {
        client.isConfigured = false
        client.offeringsResult = [.plain]
        host.setToken(sampleToken)
        let adapter = RevenueCatAdapter(client: client, host: host, options: RevenueCatOptions(), sleep: yieldingSleep)
        let task = Task { await adapter.run() }
        await Task.yield()
        #expect(client.attributes.isEmpty)
        client.isConfigured = true
        #expect(await settle { client.attributes.count == 1 && host.lastOffers?.count == 1 })
        client.send(AccessState(access: [AccessSnapshot(productId: "pro.monthly", isActive: true)], owned: ["pro.monthly"]))
        #expect(await settle { host.entitlements.last?.state == .active && host.lastOffers?.first?.isAvailable == false })
        task.cancel()
    }

    // MARK: Offer cards

    @Test("An offering with a RevenueCat paywall presents it")
    func paywall() async {
        client.offeringsResult = [.annual]
        client.paywallOutcome = .purchased
        let app = AppPaywall(.cancelled)
        let outcome = await adapter().handle(CardTap(offerId: "annual_sale"), app: app.handler)
        #expect(outcome == .purchased)
        #expect(client.paywalls == ["annual_sale"])
        #expect(app.calls == 0)
        #expect(client.purchases.isEmpty)
    }

    @Test("Without a RevenueCat paywall the app's handler shows its own")
    func appPaywall() async {
        client.offeringsResult = [.plain]
        let app = AppPaywall(.cancelled)
        let outcome = await adapter().handle(CardTap(offerId: "default"), app: app.handler)
        #expect(outcome == .cancelled)
        #expect(app.calls == 1)
        #expect(client.purchases.isEmpty)
    }

    @Test("Without any paywall the first package is bought through RevenueCat")
    func firstPackage() async {
        client.offeringsResult = [.plain]
        let outcome = await adapter().handle(CardTap(offerId: "default"), app: AppPaywall(nil).handler)
        #expect(outcome == .purchased)
        #expect(client.purchases == [RCPurchase(offeringId: "default", packageId: "$rc_monthly", productId: "pro.monthly")])
    }

    @Test("A promotional offer is bought through RevenueCat for the named product")
    func promotional() async {
        client.offeringsResult = [.annual]
        let offer = StoreOffer(kind: .promotional, id: "save50", productId: "pro.annual")
        _ = await adapter().handle(CardTap(offerId: "annual_sale", storeOffer: offer), app: AppPaywall(nil).handler)
        #expect(
            client.purchases == [
                RCPurchase(offeringId: "annual_sale", packageId: "$rc_annual", productId: "pro.annual", offer: .promotional("save50"))
            ])
        #expect(client.paywalls.isEmpty)
    }

    @Test("A promotional offer without a product uses the package that carries it")
    func promotionalCarrier() async {
        client.offeringsResult = [.annual]
        _ = await adapter().handle(
            CardTap(offerId: "annual_sale", storeOffer: StoreOffer(kind: .promotional, id: "save50")), app: AppPaywall(nil).handler)
        #expect(client.purchases.first?.packageId == "$rc_annual")
    }

    @Test("Win-back and intro offers are bought; a product outside the offering is bought by id")
    func otherOffers() async {
        client.offeringsResult = [.annual]
        let adapter = adapter()
        _ = await adapter.handle(
            CardTap(offerId: "annual_sale", storeOffer: StoreOffer(kind: .winback, id: "back", productId: "pro.monthly")),
            app: AppPaywall(nil).handler)
        _ = await adapter.handle(
            CardTap(offerId: "annual_sale", storeOffer: StoreOffer(kind: .intro, id: "trial", productId: "pro.annual")),
            app: AppPaywall(nil).handler)
        _ = await adapter.handle(
            CardTap(offerId: "annual_sale", storeOffer: StoreOffer(kind: .promotional, id: "x", productId: "elsewhere")),
            app: AppPaywall(nil).handler)
        #expect(
            client.purchases == [
                RCPurchase(offeringId: "annual_sale", packageId: "$rc_monthly", productId: "pro.monthly", offer: .winBack("back")),
                RCPurchase(offeringId: "annual_sale", packageId: "$rc_annual", productId: "pro.annual", offer: .none),
                RCPurchase(offeringId: "annual_sale", productId: "elsewhere", offer: .promotional("x")),
            ])
    }

    @Test("An unknown store offer kind opens the paywall")
    func unknownOffer() async {
        client.offeringsResult = [.annual]
        _ = await adapter().handle(
            CardTap(offerId: "annual_sale", storeOffer: StoreOffer(kind: .unknown, id: "?")), app: AppPaywall(nil).handler)
        #expect(client.paywalls == ["annual_sale"])
        #expect(client.purchases.isEmpty)
    }

    @Test("An offer code opens Apple's redemption sheet")
    func code() async {
        client.offeringsResult = [.annual]
        let outcome = await adapter().handle(
            CardTap(offerId: "annual_sale", storeOffer: StoreOffer(kind: .code, id: "WINTER")), app: AppPaywall(nil).handler)
        #expect(outcome == .pending)
        #expect(client.codeSheets == 1)
    }

    @Test("With purchasesAreCompletedBy .myApp the adapter never buys or presents: the app does")
    func myApp() async {
        client.offeringsResult = [.annual]
        client.completesPurchases = false
        let adapter = adapter()
        let app = AppPaywall(.purchased)
        #expect(
            await adapter.handle(
                CardTap(offerId: "annual_sale", storeOffer: StoreOffer(kind: .promotional, id: "save50")), app: app.handler) == .purchased)
        #expect(await adapter.handle(CardTap(offerId: "annual_sale"), app: AppPaywall(nil).handler) == .unavailable)
        #expect(app.calls == 1)
        #expect(client.purchases.isEmpty && client.paywalls.isEmpty && client.codeSheets == 0)
    }

    @Test("A card that matches no offering, or RevenueCat not configured, is unavailable")
    func unavailable() async {
        client.offeringsResult = [.annual]
        let adapter = adapter()
        #expect(await adapter.handle(CardTap(offerId: "nope"), app: AppPaywall(nil).handler) == .unavailable)
        client.isConfigured = false
        #expect(await adapter.handle(CardTap(offerId: "annual_sale"), app: AppPaywall(nil).handler) == .unavailable)
        #expect(client.purchases.isEmpty && client.paywalls.isEmpty)
    }

    @Test("Offerings load on the first tap when they have not loaded yet")
    func loadsOnTap() async {
        client.offeringsResult = [.annual]
        _ = await adapter().handle(CardTap(offerId: "annual_sale"), app: AppPaywall(nil).handler)
        #expect(client.offeringLoads == 1)
        #expect(client.paywalls == ["annual_sale"])
    }
}
