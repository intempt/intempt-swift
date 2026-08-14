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

Swift Package Manager:

```swift
dependencies: [
    .package(url: "https://github.com/intempt/intempt-swift.git", from: "1.0.0")
]
```

## Quick start

```swift
import Intempt

let intempt = try Intempt.initialize(
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
intempt.experiments(names: [String]) { result in
    // [String: ExperimentVariant]
}

intempt.products(feedId: String, count: Int) { result in
    // [ProductRecommendation]
}
```

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

### Autocapture (iOS)

```swift
intempt.autocapture.screens = true    // UIViewController appearances
intempt.autocapture.touches = true    // taps, with view identity
intempt.autocapture.controls = true   // UIControl value changes
intempt.autocapture.lifecycle = true  // launch, foreground, background, update
intempt.autocapture.start()
```

Off by default. Nothing is swizzled until `start()` is called.

### Push (APNs)

```swift
intempt.setPushToken(deviceToken)                  // from didRegisterForRemoteNotifications
intempt.trackPushOpen(userInfo)                    // from didReceiveRemoteNotification
```

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
