import Foundation
import PingFrontAdapterKit
import PingFrontCore

@testable import PingFrontRevenueCat

/// Records every call the adapter makes to RevenueCat.
@MainActor final class FakeRevenueCat: RevenueCatClient {
    var isConfigured = true
    var completesPurchases = true
    var offeringsResult: [RCOffering] = []
    var offeringsFail = false
    var purchaseOutcome: OfferOutcome = .purchased
    var paywallOutcome: OfferOutcome = .cancelled
    private(set) var attributes: [[String: String]] = []
    private(set) var purchases: [RCPurchase] = []
    private(set) var paywalls: [String] = []
    private(set) var codeSheets = 0
    private(set) var offeringLoads = 0
    private var customer: AsyncStream<AccessState>.Continuation?

    func offerings() async throws -> [RCOffering] {
        offeringLoads += 1
        if offeringsFail { throw URLError(.notConnectedToInternet) }
        return offeringsResult
    }

    func customerInfoUpdates() -> AsyncStream<AccessState> {
        let (stream, continuation) = AsyncStream.makeStream(of: AccessState.self)
        customer = continuation
        return stream
    }

    func send(_ state: AccessState) { customer?.yield(state) }

    func setAttributes(_ attributes: [String: String]) { self.attributes.append(attributes) }

    func purchase(_ purchase: RCPurchase) async -> OfferOutcome {
        purchases.append(purchase)
        return purchaseOutcome
    }

    func presentPaywall(offeringId: String) async -> OfferOutcome {
        paywalls.append(offeringId)
        return paywallOutcome
    }

    func presentCodeRedemption() async -> OfferOutcome {
        codeSheets += 1
        return .pending
    }
}

/// Records calls to the app's own paywall.
@MainActor final class AppPaywall {
    private(set) var calls = 0
    let outcome: OfferOutcome?
    init(_ outcome: OfferOutcome?) { self.outcome = outcome }
    var handler: AppOfferHandler {
        {
            self.calls += 1
            return self.outcome
        }
    }
}

extension RCOffering {
    static let annual = RCOffering(
        id: "annual_sale", title: "Annual sale", kind: .discount, hasPaywall: true,
        packages: [
            RCPackage(
                id: "$rc_annual", productId: "pro.annual", price: "€29.99", period: "P1Y", trial: "P1W", promotionalOfferIds: ["save50"]),
            RCPackage(id: "$rc_monthly", productId: "pro.monthly", price: "€4.99", period: "P1M"),
        ])
    static let plain = RCOffering(
        id: "default", title: "", kind: .standard, hasPaywall: false,
        packages: [RCPackage(id: "$rc_monthly", productId: "pro.monthly", price: "€4.99", period: "P1M")])
}
