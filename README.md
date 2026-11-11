# pingfront for RevenueCat

The RevenueCat adapter for the [pingfront iOS SDK](https://github.com/pingfront/pingfront-ios). Your RevenueCat
offerings become offer slots your team can send as offer cards, and a card opens the offering's RevenueCat paywall. It
is its own Swift package, so an app that adds it fetches RevenueCat and nothing from the other vendors.

The adapter:

- reports your paywalls as offer slots, so your team can send them as offer cards;
- opens the RevenueCat paywall when the person taps an offer card;
- reports the RevenueCat entitlement as the person's entitlement;
- links the person to RevenueCat so its webhooks match them on pingfront's server.

It leaves transactions to RevenueCat (it never finishes one) and reports no store events: RevenueCat's webhook
delivers purchases, renewals and lapses.

## Install

In Xcode, choose File > Add Package Dependencies, enter `https://github.com/pingfront/pingfront-ios-revenuecat`, and add the
**PingFrontRevenueCat** product to your app target. In a `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/pingfront/pingfront-ios-revenuecat", from: "1.0.0"),
],
// and in your target:
dependencies: [.product(name: "PingFrontRevenueCat", package: "pingfront-ios-revenuecat")]
```

It brings in the pingfront SDK (`pingfront-ios`), the shared adapter kit (`pingfront-ios-adapter-kit`) and
RevenueCat's `purchases-ios` (RevenueCat and RevenueCatUI), 5.100.0 or later in major 5. iOS 17 or later, Swift 6.

## Set up

```swift
import PingFrontRevenueCat
Purchases.configure(withAPIKey: "appl_…")
PingFront.configure("pk_live_…") { $0.use(.revenueCat) }
```

Configure RevenueCat before or right after `PingFront.configure`. The adapter waits up to a minute for it, then
stays idle and logs why.

## How it works

- **Offer slots:** one per offering, the current one first. `id` is the offering identifier, `title` its
  description, `kind` the offering metadata key `pingfront_kind` (`standard`, `discount`, `winback`; default
  `standard`). Products come from the packages. A slot is unavailable once the person owns every product in it.
  Slots refresh on every `customerInfoStream` update.
- **Offer cards:**
  - an offering with a published RevenueCat paywall opens it (RevenueCatUI);
  - otherwise your `onOffer` handler runs;
  - without one, the offering's first package is bought.
- **Store offers:**
  - `promotional`: RevenueCat signs it with the In-App Purchase key uploaded to RevenueCat. If RevenueCat cannot
    sign it, the purchase goes ahead at the regular price, which Apple's sheet shows.
  - `winback` (iOS 18+): bought when RevenueCat says the person is eligible.
  - `intro`: a plain purchase.
  - `code`: Apple's offer code sheet opens.
- **Entitlement:** `CustomerInfo.entitlements`. Lifetime, grace, billing issue (`billing_retry`), auto-renew off
  (`cancelled`), trial, then `active`; `source: revenuecat`.
- **Identity:** the subscriber attribute `pingfront_token` is set to `PingFront.shared.storeAccountToken` once a
  session exists, and removed on logout. The server matches RevenueCat webhooks on it, even when `app_user_id`
  is your own id. If you call `Purchases.logIn`, use the id you pass to `PingFront.shared.identify`.
- **Your own purchase code:** with `purchasesAreCompletedBy: .myApp` the adapter never buys. Every card goes to
  `onOffer`.

```swift
config.use(.revenueCat(RevenueCatOptions(offerings: ["winter_sale", "default"]) { request in
    await showMyPaywall(for: request.offerId)   // returns an OfferOutcome
}))
```

## Reference

The public API. Everything else is internal.

| Symbol | What it is |
| --- | --- |
| `PingFrontModule.revenueCat` | The adapter with default options. |
| `PingFrontModule.revenueCat(_ options: RevenueCatOptions)` | The adapter with options. Module id `pingfront.revenuecat`. |
| `RevenueCatOptions.offerings: [String]?` | Offering identifiers to report, in order. `nil`: every offering, the current one first. |
| `RevenueCatOptions.presentsPaywalls: Bool` | Present RevenueCatUI paywalls for offerings that have one. Default `true`. |
| `RevenueCatOptions.onOffer` | `@MainActor @Sendable (OfferRequest) async -> OfferOutcome`: your own paywall. |
| `RevenueCatOptions.init(offerings:presentsPaywalls:onOffer:)` | Creates options. |

## More

- [Modules and vendor adapters](https://pingfront.sh/docs/modules#revenuecat-superwall-and-adapty) in the pingfront docs.
- Connect RevenueCat's webhook too: [Store events](https://pingfront.sh/docs/store-events).
- [CHANGELOG.md](CHANGELOG.md). MIT licensed (see `LICENSE`).
