import Foundation
import PingFrontAdapterKit
import PingFrontCore
import RevenueCat
import os

#if canImport(UIKit)
    import RevenueCatUI
    import UIKit
#endif

/// The live RevenueCat client: `Purchases.shared` and RevenueCatUI's `PaywallViewController`.
@MainActor final class RevenueCatLive: RevenueCatClient {
    private let log = AdapterLog.logger("revenuecat")
    #if canImport(UIKit)
        /// The paywall on screen; the controller holds its delegate weakly.
        private var paywall: PaywallSession?
    #endif

    var isConfigured: Bool { Purchases.isConfigured }

    var completesPurchases: Bool { Purchases.shared.purchasesAreCompletedBy == .revenueCat }

    func offerings() async throws -> [RCOffering] {
        let offerings = try await Purchases.shared.offerings()
        let current = offerings.current?.identifier
        let sorted = offerings.all.values.sorted { lhs, rhs in
            if (lhs.identifier == current) != (rhs.identifier == current) { return lhs.identifier == current }
            return lhs.identifier < rhs.identifier
        }
        return sorted.map(Self.offering)
    }

    func customerInfoUpdates() -> AsyncStream<AccessState> {
        AsyncStream { continuation in
            // Owned by the stream: cancelled when the adapter stops iterating.
            let task = Task { @MainActor in
                for await info in Purchases.shared.customerInfoStream { continuation.yield(Self.state(info)) }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func setAttributes(_ attributes: [String: String]) { Purchases.shared.attribution.setAttributes(attributes) }

    func purchase(_ purchase: RCPurchase) async -> OfferOutcome {
        do {
            let offering = try await Purchases.shared.offerings().all[purchase.offeringId]
            let package = purchase.packageId.flatMap { id in offering?.availablePackages.first { $0.identifier == id } }
            var product = package?.storeProduct
            if product == nil, let productId = purchase.productId { product = await Purchases.shared.products([productId]).first }
            guard let product else { return .failed(.productNotFound) }
            let builder = package.map { PurchaseParams.Builder(package: $0) } ?? PurchaseParams.Builder(product: product)
            await apply(purchase.offer, product: product, to: builder)
            #if canImport(UIKit)
                if let scene = Presentation.activeScene() { _ = builder.with(confirmInScene: scene) }
            #endif
            let result = try await Purchases.shared.purchase(builder.build())
            return result.userCancelled ? .cancelled : .purchased
        } catch {
            log.error("Purchase failed: \(String(describing: error), privacy: .private)")
            return Self.outcome(for: error)
        }
    }

    /// Adds the store offer RevenueCat can redeem.
    ///
    /// When it cannot (no key in RevenueCat, not eligible), the purchase goes ahead at the regular price, which
    /// Apple's sheet shows.
    private func apply(_ offer: RCOfferChoice, product: StoreProduct, to builder: PurchaseParams.Builder) async {
        switch offer {
        case .none:
            return
        case .promotional(let id):
            guard let discount = product.discounts.first(where: { $0.offerIdentifier == id }) else {
                log.error("The product has no promotional offer \(id, privacy: .public); buying at the regular price.")
                return
            }
            do {
                let signed = try await Purchases.shared.promotionalOffer(forProductDiscount: discount, product: product)
                _ = builder.with(promotionalOffer: signed)
            } catch {
                log.error("RevenueCat could not sign the promotional offer: \(String(describing: error), privacy: .private)")
            }
        case .winBack(let id):
            guard #available(iOS 18, macOS 15, *) else { return }
            do {
                let eligible = try await Purchases.shared.eligibleWinBackOffers(forProduct: product)
                if let winBack = eligible.first(where: { $0.discount.offerIdentifier == id }) { _ = builder.with(winBackOffer: winBack) }
            } catch {
                log.error("Could not check win-back eligibility: \(String(describing: error), privacy: .private)")
            }
        }
    }

    func presentPaywall(offeringId: String) async -> OfferOutcome {
        #if canImport(UIKit)
            guard let offering = try? await Purchases.shared.offerings().all[offeringId], let top = Presentation.topViewController()
            else { return .unavailable }
            let outcome = await withCheckedContinuation { continuation in
                let session = PaywallSession(once: ResumeOnce(continuation))
                paywall = session
                let controller = PaywallViewController(offering: offering, displayCloseButton: true)
                controller.delegate = session
                top.present(controller, animated: true)
            }
            paywall = nil
            return outcome
        #else
            return .unavailable
        #endif
    }

    func presentCodeRedemption() async -> OfferOutcome { await OfferCodes.present() }

    // MARK: Mapping (nonisolated, tested with RevenueCat's test doubles)

    nonisolated static func offering(_ offering: Offering) -> RCOffering {
        RCOffering(
            id: offering.identifier, title: offering.serverDescription,
            kind: SlotRules.kind(offering.getMetadataValue(for: SlotRules.kindKey, default: "")), hasPaywall: offering.hasPaywall,
            packages: offering.availablePackages.map(package))
    }

    nonisolated static func package(_ package: Package) -> RCPackage {
        let product = package.storeProduct
        var trial: String?
        if let intro = product.introductoryDiscount, intro.paymentMode == .freeTrial { trial = iso(intro.subscriptionPeriod) }
        return RCPackage(
            id: package.identifier, productId: product.productIdentifier, price: product.localizedPriceString,
            period: product.subscriptionPeriod.flatMap(iso), trial: trial,
            promotionalOfferIds: product.discounts.compactMap(\.offerIdentifier))
    }

    nonisolated static func iso(_ period: SubscriptionPeriod) -> String? {
        let unit: PeriodUnit? =
            switch period.unit {
            case .day: .day
            case .week: .week
            case .month: .month
            case .year: .year
            @unknown default: nil
            }
        return SlotRules.iso(value: period.value, unit: unit)
    }

    nonisolated static func state(_ info: CustomerInfo) -> AccessState {
        let access = info.entitlements.all.values.map { entitlement in
            AccessSnapshot(
                productId: entitlement.productIdentifier, isActive: entitlement.isActive,
                isLifetime: entitlement.expirationDate == nil, isTrial: entitlement.periodType == .trial,
                willRenew: entitlement.willRenew, hasBillingIssue: entitlement.billingIssueDetectedAt != nil,
                expiresAt: entitlement.expirationDate)
        }
        let owned = info.activeSubscriptions.union(info.nonSubscriptions.map(\.productIdentifier))
        return AccessState(access: access, owned: owned)
    }

    nonisolated static func outcome(for error: any Error) -> OfferOutcome {
        let nsError = error as NSError
        let code =
            (error as? RevenueCat.ErrorCode)
            ?? (nsError.domain == RevenueCat.ErrorCode.errorDomain ? RevenueCat.ErrorCode(rawValue: nsError.code) : nil)
        switch code {
        case .purchaseCancelledError?: return .cancelled
        case .paymentPendingError?: return .pending
        case .networkError?, .offlineConnectionError?: return .failed(.network)
        case .productNotAvailableForPurchaseError?: return .failed(.productNotFound)
        case .purchaseNotAllowedError?, .ineligibleError?: return .failed(.notAllowed)
        default: return .failed(.store)
        }
    }
}

#if canImport(UIKit)
    /// Waits for a RevenueCat paywall to close and remembers whether something was bought.
    ///
    /// Nonisolated with a lock: RevenueCatUI calls the delegate on the main thread, but its protocol is not
    /// main-actor annotated.
    final class PaywallSession: NSObject, PaywallViewControllerDelegate, Sendable {
        private let once: ResumeOnce<OfferOutcome>
        private let outcome = OSAllocatedUnfairLock<OfferOutcome>(initialState: .cancelled)

        init(once: ResumeOnce<OfferOutcome>) { self.once = once }

        func paywallViewController(_ controller: PaywallViewController, didFinishPurchasingWith customerInfo: CustomerInfo) {
            outcome.withLock { $0 = .purchased }
        }

        func paywallViewController(_ controller: PaywallViewController, didFailPurchasingWith error: NSError) {
            let failed = RevenueCatLive.outcome(for: error)
            outcome.withLock { if $0 != .purchased { $0 = failed } }
        }

        func paywallViewControllerWasDismissed(_ controller: PaywallViewController) {
            once.resume(outcome.withLock { $0 })
        }
    }
#endif
