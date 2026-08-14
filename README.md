# Intempt Swift SDK

Analytics, personalization and consent for iOS, tvOS, macOS and watchOS.

> **Built on mixpanel-swift.** This SDK's foundation — its storage layer,
> concurrency model, type system, retry curve and flush loop — is derived from
> [mixpanel-swift](https://github.com/mixpanel/mixpanel-swift), which Mixpanel
> released under the Apache License 2.0. We inherited a design that has run in
> production for the better part of a decade rather than rediscovering its
> lessons. See [NOTICE](NOTICE) for the file-by-file attribution. Intempt is not
> affiliated with or endorsed by Mixpanel, Inc.

## Requirements

| | |
|---|---|
| Swift | 5.9+ |
| Xcode | 15.0+ |
| iOS / tvOS | 15.0+ |
| macOS | 12.0+ |
| watchOS | 8.0+ |

## Install

This repository is **private** while the SDK is in preview, and no version tag
has been cut yet. Swift Package Manager cannot resolve it anonymously — your
git credentials need read access to `intempt/intempt-swift` first. Ask your
Intempt contact for access.

Pin the branch until there is a tag to pin instead:

```swift
dependencies: [
    .package(url: "https://github.com/intempt/intempt-swift.git", branch: "main")
]
```

In CI, where there is no keychain to authenticate from, rewrite the URL with a
token that can read the repository:

```bash
git config --global url."https://x-access-token:${TOKEN}@github.com/".insteadOf "https://github.com/"
```

## Quick start

```swift
import Intempt

let intempt = try IntemptInstance.initialize(
    apiKey: "yourPrefix.yourSecret",
    orgId: "your-org",
    projectId: "your-project",
    sourceId: "your-source-id"
)

intempt.track(eventTitle: "Checkout Started", data: [
    "cart_value": 129.99,
    "item_count": 3,
])

intempt.identify(userId: "user@example.com", userAttributes: [
    "plan": "pro",
    "signup_date": Date(),
])
```

`initialize` is declared on `IntemptInstance`. The `Intempt` enum is a namespace
for constants (`sdkVersion`, `defaultFeedFields`), not an entry point.

Later, reach the same instance from anywhere with `IntemptInstance.mainInstance()`,
which returns an optional rather than trapping if you call it before `initialize`.

`initialize` throws rather than logging and continuing. A blank `orgId` is a
build-time integration error, and silently posting to `.../(null)/projects/...`
forever is not a recovery.

## Public API

### Tracking

```swift
intempt.track(eventTitle: String, data: [String: IntemptType]?)
intempt.identify(userId: String, eventTitle: String, userAttributes: [String: IntemptType]?, data: [String: IntemptType]?)
intempt.group(accountId: String, eventTitle: String, accountAttributes: [String: IntemptType]?)
intempt.alias(userId: String, anotherUserId: String)
intempt.record(eventTitle: String, userId: String?, accountId: String?, data: ..., userAttributes: ..., accountAttributes: ...)
```

`identify` sets the **user**. `group` sets the **account** — Intempt's concept
for the company a user belongs to. `record` does both in one call.

### Commerce

```swift
intempt.productView(productId: String)
intempt.productAdd(productId: String, quantity: Int)
intempt.productOrdered(products: [(productId: String, quantity: Int)])
```

### Personalization

```swift
intempt.experiments(names: ["checkout-button"]) { result in
    // Result<[ExperimentChoice], IntemptError>
    // ExperimentChoice: .experience, .variant, .target
    if case .success(let choices) = result {
        for choice in choices where choice.experience == "checkout-button" {
            apply(choice.variant)
        }
    }
}

intempt.products(feedId: "feed-id", count: 10) { result in
    // Result<[ProductRecommendation], IntemptError>
}
```

`experiments` also takes `groups:`, `optimizationType:` (`.experiment` or
`.personalization`) and `productId:`. All are optional; omitting every filter
asks for everything that matches.

`products` defaults `fields:` to `Intempt.defaultFeedFields` deliberately. An
unfielded request returns every catalog column including raw ML embedding
vectors — measured at **443x** the payload. Widen it on purpose, never by
omission.

### Consent

```swift
intempt.consent(action: .accept, validUntil: 31_536_000)
intempt.consent(action: .reject, validUntil: 0)
```

`.reject` **enforces** the decision: collection stops and the queue is purged.
The withdrawal record itself is preserved and still transmitted — it's the
evidence the user objected, and dropping it would mean the objection is
recorded nowhere.

### Privacy

```swift
intempt.optOut()          // stop collecting AND discard what's queued
intempt.optIn()
intempt.hasOptedOut()
intempt.logOut()          // rotate anonymous identity
intempt.reset()           // new identity, empty queue
```

### Delivery

```swift
intempt.flush()                   // fire and forget
intempt.flush { sent in ... }      // completion carries the count
intempt.flushInterval = 30         // seconds; 0 disables the timer
```

### Autocapture (iOS, tvOS)

```swift
intempt.autocapture.configure(.all)
intempt.autocapture.start()
```

Or pick the families you want:

```swift
intempt.autocapture.configure(AutocaptureOptions(
    screens: true,        // UIViewController appeared      -> "View screen"
    taps: true,           // UIControl action, e.g. a button -> "Action"
    controlChanges: true, // UIControl value changed         -> "Edit Field"
    screenExits: true,    // disappeared, carries dwell time -> "Leave screen"
    rawTouches: true      // taps NOT on a UIControl         -> "Touch"
))
```

`taps` and `rawTouches` are separate on purpose: a button press already emits
*Action*, so counting it as a *Touch* too would double-count every press.
`rawTouches` covers what the first one misses — taps that land on plain views.

Off by default, and **nothing is swizzled until `start()`**. `.all` turns on all
five; `.none` is the other preset.

### Push (APNs)

```swift
intempt.setPushToken(deviceToken)   // didRegisterForRemoteNotificationsWithDeviceToken
intempt.trackPushOpen(userInfo)     // userNotificationCenter(_:didReceive:)
intempt.trackPushReceived(userInfo) // didReceiveRemoteNotification, incl. silent
```

Pass the **raw `Data`**. Do not stringify it first: the widespread
`token.description` idiom has produced the literal `"32 bytes"` since iOS 13,
and `setPushToken` returns `false` rather than registering that. The token is
sent as `apns_token_<sourceId>` on an *App Install/Upgrade* event, which is how
the destinations job finds the device.

APNs only. There is no Firebase or FCM dependency at any layer.

## Property types

`IntemptType` accepts `String`, `Int`, `UInt`, `Double`, `Float`, `Bool`,
`Date`, `URL`, `NSNull`, `NSNumber`, and arrays/dictionaries of the same,
nested to any depth. Values that cannot survive the wire — `NaN`, `infinity` —
are rejected at the call boundary rather than serialized as the string `"nan"`.

## Data on disk

Events land in SQLite (WAL mode) under `Library/`, excluded from iCloud and
iTunes backup, with iOS data protection set to
`COMPLETEUNTILFIRSTUSERAUTHENTICATION` so a background flush cannot hang on a
locked screen. The queue is capped at 5,000 events; past that the oldest are
evicted, so an offline device cannot fill the user's disk.

A batch is deleted **only** after the server acknowledges it. Not before the
POST, and never as a blanket delete.

## Testing

```bash
swift test
```

## License

Apache License 2.0. See [LICENSE](LICENSE) and [NOTICE](NOTICE).
