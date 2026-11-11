import Foundation
import PingFrontAdapterKit
import PingFrontCore
import RevenueCat
import Testing

@testable import PingFrontRevenueCat

/// The live client's mapping, checked against RevenueCat's own test doubles.
@Suite("RevenueCat mapping")
struct RevenueCatMappingTests {
    func product(_ id: String, period: SubscriptionPeriod?, trial: Bool = false, promos: [String] = []) -> StoreProduct {
        let intro =
            trial
            ? TestStoreProductDiscount(
                identifier: "intro", price: 0, localizedPriceString: "Free", paymentMode: .freeTrial,
                subscriptionPeriod: SubscriptionPeriod(value: 1, unit: .week), numberOfPeriods: 1, type: .introductory) : nil
        let discounts = promos.map {
            TestStoreProductDiscount(
                identifier: $0, price: 1, localizedPriceString: "€1", paymentMode: .payAsYouGo,
                subscriptionPeriod: SubscriptionPeriod(value: 1, unit: .month), numberOfPeriods: 3, type: .promotional)
        }
        return TestStoreProduct(
            localizedTitle: id, price: 4.99, currencyCode: "EUR", localizedPriceString: "€4.99", productIdentifier: id,
            productType: .autoRenewableSubscription,
            localizedDescription: id, subscriptionPeriod: period, introductoryDiscount: intro, discounts: discounts,
            locale: Locale(identifier: "en_IE")
        ).toStoreProduct()
    }

    @Test("An offering maps to its id, description, pingfront_kind and packages")
    func offering() {
        let annual = Package(
            identifier: "$rc_annual", packageType: .annual,
            storeProduct: product("pro.annual", period: SubscriptionPeriod(value: 1, unit: .year), trial: true, promos: ["save50"]),
            offeringIdentifier: "winback", webCheckoutUrl: nil)
        let lifetime = Package(
            identifier: "$rc_lifetime", packageType: .lifetime, storeProduct: product("pro.lifetime", period: nil),
            offeringIdentifier: "winback", webCheckoutUrl: nil)
        let offering = Offering(
            identifier: "winback", serverDescription: "Come back", metadata: ["pingfront_kind": "winback"],
            availablePackages: [annual, lifetime], webCheckoutUrl: nil)
        let mapped = RevenueCatLive.offering(offering)
        #expect(
            mapped
                == RCOffering(
                    id: "winback", title: "Come back", kind: .winback, hasPaywall: false,
                    packages: [
                        RCPackage(
                            id: "$rc_annual", productId: "pro.annual", price: "€4.99", period: "P1Y", trial: "P1W",
                            promotionalOfferIds: ["save50"]),
                        RCPackage(id: "$rc_lifetime", productId: "pro.lifetime", price: "€4.99", period: nil, trial: nil),
                    ]))
    }

    @Test("Offering metadata without pingfront_kind is standard")
    func defaultKind() {
        let offering = Offering(identifier: "default", serverDescription: "Default", availablePackages: [], webCheckoutUrl: nil)
        #expect(RevenueCatLive.offering(offering).kind == .standard)
    }

    @Test("Periods map to ISO-8601")
    func periods() {
        #expect(RevenueCatLive.iso(SubscriptionPeriod(value: 3, unit: .month)) == "P3M")
        #expect(RevenueCatLive.iso(SubscriptionPeriod(value: 1, unit: .day)) == "P1D")
    }

    @Test("Purchase errors map to offer outcomes")
    func errors() {
        #expect(RevenueCatLive.outcome(for: ErrorCode.purchaseCancelledError) == .cancelled)
        #expect(RevenueCatLive.outcome(for: ErrorCode.paymentPendingError) == .pending)
        #expect(RevenueCatLive.outcome(for: ErrorCode.networkError) == .failed(.network))
        #expect(RevenueCatLive.outcome(for: ErrorCode.offlineConnectionError) == .failed(.network))
        #expect(RevenueCatLive.outcome(for: ErrorCode.productNotAvailableForPurchaseError) == .failed(.productNotFound))
        #expect(RevenueCatLive.outcome(for: ErrorCode.purchaseNotAllowedError) == .failed(.notAllowed))
        #expect(RevenueCatLive.outcome(for: ErrorCode.ineligibleError) == .failed(.notAllowed))
        #expect(RevenueCatLive.outcome(for: ErrorCode.storeProblemError) == .failed(.store))
        #expect(RevenueCatLive.outcome(for: CancellationError()) == .failed(.store))
        // RevenueCat throws NSErrors in its own domain.
        let bridged = NSError(domain: ErrorCode.errorDomain, code: ErrorCode.purchaseCancelledError.rawValue)
        #expect(RevenueCatLive.outcome(for: bridged) == .cancelled)
    }
}
