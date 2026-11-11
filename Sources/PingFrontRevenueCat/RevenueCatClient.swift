import PingFrontAdapterKit
import PingFrontCore

/// A RevenueCat offering, reduced to what offer slots and offer cards need.
struct RCOffering: Sendable, Equatable {
    var id: String
    var title: String
    var kind: OfferSlot.Kind
    var hasPaywall: Bool
    var packages: [RCPackage]
}

/// A package in an offering.
struct RCPackage: Sendable, Equatable {
    var id: String
    var productId: String
    var price: String
    var period: String?
    var trial: String?
    /// Promotional offer ids on the product (`StoreProductDiscount.offerIdentifier`).
    var promotionalOfferIds: [String] = []
}

/// Which store offer a purchase redeems.
enum RCOfferChoice: Sendable, Equatable {
    case none
    /// An App Store promotional offer: RevenueCat signs it with the key uploaded to RevenueCat.
    case promotional(String)
    /// A win-back offer (iOS 18+), when RevenueCat says the person is eligible.
    case winBack(String)
}

/// A purchase through RevenueCat: a package of an offering, or a product by id.
struct RCPurchase: Sendable, Equatable {
    var offeringId: String
    var packageId: String?
    var productId: String?
    var offer: RCOfferChoice = .none
}

/// The slice of RevenueCat the adapter uses.
///
/// The live client wraps `Purchases.shared` and RevenueCatUI.
@MainActor protocol RevenueCatClient: AnyObject {
    /// `Purchases.isConfigured`.
    var isConfigured: Bool { get }
    /// `purchasesAreCompletedBy == .revenueCat`: RevenueCat finishes the transactions it starts.
    var completesPurchases: Bool { get }
    /// Every offering, the current one first.
    func offerings() async throws -> [RCOffering]
    /// Customer info now and after every change (`customerInfoStream`).
    func customerInfoUpdates() -> AsyncStream<AccessState>
    /// `Purchases.shared.attribution.setAttributes(_:)`; an empty value removes the attribute.
    func setAttributes(_ attributes: [String: String])
    /// Buys through RevenueCat, which finishes the transaction.
    func purchase(_ purchase: RCPurchase) async -> OfferOutcome
    /// Presents the offering's RevenueCat paywall and waits until it closes.
    func presentPaywall(offeringId: String) async -> OfferOutcome
    /// Presents Apple's offer code sheet.
    func presentCodeRedemption() async -> OfferOutcome
}
