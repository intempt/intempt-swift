# SDK API contract

The public method surface every Intempt client SDK conforms to.

`CONTRACT.md`, beside this file, defines the **wire** — what goes over HTTP, verified
against production. This file defines the **surface** — what an integrator calls. Both
live here because the Swift SDK's shape is canonical, decided 2026-08-15.

## Status

| Platform | Repo | Conforms |
|---|---|---|
| Swift | `intempt-swift` | canonical — this document describes it |
| Android | `intempt-android` | in progress, 3.0 clean break |
| React Native | `intempt-reactnative` | in progress, bridges both |
| Node | `intempt-node` | client surface only; see Server SDKs |
| Python | `intempt-python` | client surface only; see Server SDKs |
| PHP | `intempt-php` | client surface only; see Server SDKs |
| JavaScript | `intemptjs` | out of scope, predates the contract |

Server SDKs conform on the shared capture surface — `track`, `identify`, `group`,
`alias`, `consent`, `optIn` / `optOut` — and diverge structurally everywhere a server has
no device, session or per-user state. Those divergences are enumerated under
[Server SDKs](#server-sdks) so nobody "fixes" them into conformance.

A divergence that is *gratuitous* rather than structural is a bug, and belongs in an
issue rather than in the table.

## Why the Swift shape

Not because it was written first — it was written last. Three reasons:

1. It is typed where Android is stringly. `IntemptType` accepts `String`, `Int`, `UInt`,
   `Bool`, `Date`, `URL`, `Double`, `Float`, `NSNull`, `NSNumber`, `Array` and
   `Dictionary`. Android accepts `Map<String, String>`, so a JavaScript caller passing
   `{count: 3, active: true}` silently ships `"3"` and `"true"`.
2. It returns success. Every capture method returns `Bool`. Android returns `Unit`, so a
   caller cannot tell an accepted event from a dropped one.
3. It is explicit where Android is implicit — named instances, a settable flush interval,
   an error type with cases rather than swallowed exceptions.

Where Swift is wrong, the contract wins and Swift changes. Two cases exist today:
`record()` argument order, frozen below, and `experiments()`, which Swift implements and
should not — see [Personalization](#personalization).

**Canonical does not mean correct.** Swift is the starting shape because it is the newest
and best-specified, not because it wins ties. Two of the decisions in this document went
against it: `isOptedIn` on naming, and removing `experiments()` on product scope, where
Android's deliberate removal was right and drafting from Swift had quietly overruled it.

## Initialisation

```
initialize(apiKey, orgId, projectId, sourceId, instanceName = "default") -> Instance
```

Throws on a malformed API key (not `prefix.secret`) and on any blank identifier.

Credentials are passed at runtime. A platform MAY additionally support a config file —
Android reads `assets/intempt-config.json` and that path is retained — but a file MUST
NOT be the only way in. React Native cannot ship native asset files on behalf of its
users, and an SDK that can only be configured from disk cannot be wrapped.

Instances are named and multiple instances coexist. A singleton is not conformant: it
makes two projects in one app impossible and makes tests share state.

```
mainInstance() -> Instance?          // the "default" instance
instance(named:) -> Instance?
```

## Capture

Every method returns a boolean: was the event accepted into the queue. False means
dropped — opted out, invalid property, encoding failure, storage unavailable. It does
**not** mean delivered.

```
track(eventTitle, data?) -> Bool
identify(userId, eventTitle = "Identify", userAttributes?, data?) -> Bool
group(accountId, eventTitle = "Identify", accountAttributes?) -> Bool
alias(userId, anotherUserId) -> Bool
record(eventTitle, userId?, accountId?, data?, userAttributes?, accountAttributes?) -> Bool
```

`record()` argument order is **frozen as written above**. Android currently orders it
`(eventTitle, accountId, userId, accountAttributes, userAttributes, data)` — identifiers
swapped and attributes reversed. Both orders are defensible; having two is not. Swift's
wins because `userId` before `accountId` matches every other method's ordering, where the
user-level identifier precedes the account-level one.

All attribute and data maps take typed values, not strings.

### Commerce

```
productAdd(productId, quantity) -> Bool
productView(productId) -> Bool
productOrdered(products: [(productId, quantity)]) -> Bool
```

`productOrdered` takes a typed pair list, not an untyped map list. Android's
`List<Map<String, Any>>` admits a map with neither key and fails at runtime.

### Consent

```
consent(action: ConsentAction, validUntil, email?, message?, category?) -> Bool
```

`ConsentAction` is an enum — `accept` or `reject` — not a string. A typo in a string
consent action is a silent compliance failure, which is the worst class of bug this SDK
can have.

Three behaviours are contractual, not implementation detail:

- Consent transmits **even when opted out**. A withdrawal must reach the server.
- It goes to `/consents/data`, unbatched, outside the `/track` envelope.
- `reject` triggers `optOut()`; `accept` triggers `optIn()`.

## Identity and lifecycle

```
getProfileId() -> String
getSessionId() -> String
logOut()          // rotate anonymous identity, keep the queue
reset()           // new anonymous identity AND empty queue
```

`logOut()` and `reset()` are distinct and both required. `logOut()` exists so the next
user of a shared device cannot inherit the previous identity. `reset()` additionally
discards queued events.

## Opt in / out

```
optIn()
optOut()
hasOptedOut() -> Bool
isOptedIn() -> Bool
```

These names are contractual. Android's `Tracking.start()` / `Tracking.stop()` /
`isTrackingEnabled()` are not conformant.

`isOptedIn()` is the agreed name, decided 2026-08-15. An earlier draft of this document
said `isUserOptIn()`, following Swift. It is being changed **against** the canonical SDK
on purpose: `isOptedIn` is the correct English — a past participle, "is the user opted in"
— where `isUserOptIn` reads as a noun phrase, and it is the odd one out against every
comparable SDK. Three of the five SDKs already ship `isOptedIn` and none of the three has
published, so the cost is symmetric and the decision was made on the name being better
rather than on which side was cheaper to move. Swift and Android change.

`optOut()` MUST discard already-queued events, not merely set a flag. Setting a flag
leaves events collected before the objection to be uploaded after it. Queued **consent**
records are deliberately preserved — they are the evidence of the user's decision.

## Delivery

```
flush(completion: (Int) -> Void)?     // completion receives events delivered
flushInterval                          // seconds, settable; 0 disables the timer
```

`flush()` must be reachable on the instance. Android has one on
`com.intempt.core.queue.DeliveryMessages`, which is the transport, not the public API.

## Personalization

```
products(feedId, count = 10, fields = defaultFeedFields, productId?) -> Result<[ProductRecommendation]>
```

`products()` is settled. Android already has the same capability under a different name —
`recommendation(id, quantity, fields, productId)` against `/feeds/{id}/data` — so this is
a rename, not new work.

### `experiments()` is deliberately NOT in the mobile SDKs

**Decided 2026-08-15. Experiment and personalization assignment is an intemptjs
capability.** It does not belong in a mobile client SDK, and no mobile SDK should add it.

This reverses an earlier draft of this document, which specified `experiments()` because
the contract was drafted from `intempt-swift`, which implements it. That was the drafting
error: `intempt-android` had already removed `ModificationProvider`, `Intempt.experiment`
and `Intempt.personalization` as a deliberate product decision, documented in its
`CLAUDE.md`, and writing the contract from one implementation quietly overruled it.

So the removal direction is Swift, not Android:

| SDK | Action |
|---|---|
| `intempt-android` | none — already removed. `recommendation()` stays |
| `intempt-swift` | remove `experiments()`, `ExperimentChoice`, `OptimizationType` |
| `intempt-reactnative` | remove the bridged method, spec entry and fixtures |

Recommendation feeds are **unaffected** and stay on every platform — see `products()`
above. The two were conflated because Android's `ModificationProvider` and its feed call
sat next to each other; they are different capabilities against different endpoints.

`products()` defaults `fields` to a compact set on purpose. An unfielded request returns
every catalog column including raw ML embedding vectors — measured at **443x** the
payload for the same 10 products, 503 bytes against 222,919. Widen deliberately, never by
omission. A platform MUST NOT default this to "all fields".

## Automatic events

```
automaticEvents: { sessions, versionChanges, appStateChanges }
```

Runtime-settable, not config-file-only. Defaults: `sessions` on, the other two off. An
SDK that silently emits events the integrator never asked for is how an event-volume bill
surprises someone.

| Option | Default | Emits |
|---|---|---|
| `sessions` | on | Session start / end, carrying device facts as user attributes |
| `versionChanges` | off | Application Installed / Application Updated, once per version |
| `appStateChanges` | off | Application Opened / Application Backgrounded, every transition |

## Autocapture

Distinct from automatic events, and repeatedly confused with them. Automatic events are
lifecycle facts the SDK knows without instrumentation. **Autocapture is UI instrumentation
— it hooks the view layer.**

```
autocapture.configure({ screenViews, controlInteractions })
autocapture.start()
autocapture.stop()
autocapture.isRunning -> Bool
```

Three rules, all contractual:

1. **Opt-in, and inert until started.** `configure()` sets options; nothing is installed
   until `start()`. On Apple this swizzles UIKit, which is not something an SDK may do
   because it was merely initialised.
2. **One interaction, one event.** A control press already emits its own event. Counting
   it again as a generic touch double-counts every button in the app. Any platform
   mapping must preserve this.
3. **Platform granularity is an annex, not the contract.** The contract names concepts
   both platforms have — screen views and control interactions. Finer options stay
   platform-specific and are listed below rather than forced onto a platform that has no
   equivalent distinction.

### Platform annex

| Platform | Options | Notes |
|---|---|---|
| Swift | `screens`, `taps`, `controlChanges`, `screenExits`, `rawTouches` | UIKit-shaped. `taps` and `rawTouches` are deliberately separate — see rule 2 |
| Android | `isTouchEnabled`, `isTextCaptureEnabled`, `isAutoCaptureEnabled` | Config asset only. **No runtime setter exists, not even an internal one** — making these settable is a Dagger-graph change, not a property, so it will not land alongside the capture surface |
| React Native | maps to `screenViews`, `controlInteractions` only | `rawTouches` has no cross-platform meaning |

Android's autocapture options being config-file-only is a conformance gap, the same one
credentials have. A React Native app enabling screen tracking from JavaScript and getting
it on exactly one platform is the divergence this contract exists to catch.

## Errors

One error type across platforms, with these cases:

| Case | Meaning |
|---|---|
| `malformedAPIKey(length)` | key is not `prefix.secret` |
| `missingConfiguration(field)` | blank orgId / projectId / sourceId |
| `invalidPropertyValue(key)` | value not representable |
| `missingIdentity` | required identifier absent for the event type |
| `encodingFailed` | payload would not serialize |
| `terminal(status)` | will never succeed on retry |
| `retryable(status, retryAfter?)` | retry with backoff |
| `transport(description)` | network layer failed |
| `storageUnavailable(reason)` | queue could not persist |
| `server(status, messages)` | server rejected with detail |

The terminal/retryable split is contractual. `401` is terminal — a bad credential cannot
succeed on retry — but queued events are **kept**, because the data is valid and the
integration is what is broken. Deleting them on 401 is total silent data loss, and it has
already happened once in the Android transport.

## Bridging rules for React Native

The wrapper adds constraints the native SDKs do not have.

- **No native-only types in the signature.** Android's `doNotCaptureText(View)` takes an
  Android `View` and cannot cross the bridge. It stays Android-only and is absent from the
  JS surface. It is the only sanctioned exception.
- **Every method returns a Promise**, including the ones returning `Bool` natively. The
  boolean becomes the resolved value.
- **`Date` and `URL` degrade.** JavaScript has neither on the bridge. Dates cross as ISO
  8601 strings, URLs as strings, and the native side re-types them before enqueueing.
- **A method absent on one platform rejects**, with `unsupported_on_<platform>` and the
  method name. It does not resolve silently, and it does not throw at import time.

## Conformance

Conformance is a test, not a review.

A shared fixture corpus of `(method, arguments) -> expected wire payload` is committed
once and consumed by every SDK repo. Each asserts its own output against it. Divergence
fails CI in whichever repo drifted.

Android additionally exposes `app/api/app.api` via binary-compatibility-validator — a
machine-readable declared surface. The corpus diffs it against this document mechanically,
so a conformance gap is a red build rather than something someone notices in review.

Two rules for the corpus, both learned the hard way:

- Assert on **delivery**, not only on payload shape. A transport that posts `headers =
  null`, 401s on every batch and deletes the queue produces perfectly correct payloads
  while losing 100% of events.
- A fixture that has never failed has never been tested. Break the line it covers and
  watch it go red before trusting it.

## Accepted divergences

| Platform | Divergence | Why accepted |
|---|---|---|
| Android | `doNotCaptureText(View)` | Native view type, no cross-platform meaning |
| Android | `assets/intempt-config.json` | Retained as a fallback, not the only path |
| Swift | `rawTouches` autocapture option | UIKit-specific; no Android equivalent |
| React Native | No `doNotCaptureText` | Takes a native `View`; cannot cross the bridge |
| JavaScript | Entire surface | Predates the contract |

### Server SDKs

Node, Python and PHP are server SDKs. The divergences below are **structural** — they
follow from having no device, no session and no per-user state — and are recorded here so
nobody "fixes" them into conformance.

| Divergence | Why it is correct |
|---|---|
| `reset()` absent | One client instance is shared across every request and thread; each call carries its own identifier. There is nothing to reset. A no-op `reset()` would imply per-user state that does not exist |
| `getProfileId()` absent | `profileId` is device-minted. A server inventing one creates an orphan profile |
| `getSessionId()` absent | No session on a server |
| `masterId` absent | Assigned after identity resolution, with no server read path |
| `record()` absent (Node) | Present only on the deprecated 1.x shim |
| `consent.grant()` / `consent.revoke()` | Grant and revoke are genuinely different writes. The collapsed `consent(action:)` shape is what 1.x moved away from |
| `trackBatch`, `close`, `buffered`, `setConfig` | Server concerns — connection lifetime and batching — with no client analogue |

`optIn()` / `optOut()` / `isOptedIn()` are shared, and the server SDKs already have the
agreed name — see [Opt in / out](#opt-in--out). This was the one divergence in this
section where a server imposed nothing, which is why it was resolved by renaming the
clients rather than by blessing a split.

## Credential handling

The API key is `prefix.secret`. Three rules, all contractual, because three of the five
SDKs got this wrong independently — which makes it a contract problem rather than five
separate bugs.

**1. The parsed credential type is not public.** An integrator has no reason to read it
back, and every public accessor is a path to a log line.

**2. A credential type must redact itself in every printing path the language has.** Not
just the obvious one. Swift needed `CustomStringConvertible` *and* `CustomReflectable`,
because `dump()` and any Mirror-based logger walk stored properties directly and skip
`description` entirely — a test caught that after the first fix looked complete.

The equivalent per language:

| Language | Redact | Because |
|---|---|---|
| Swift | `CustomStringConvertible` + `CustomReflectable` | `dump()` bypasses `description` |
| Kotlin | override `toString()` on any `data class` holding it | the generated `toString()` prints every property |
| PHP | avoid `public readonly` on the key; `__debugInfo()` | `print_r()` and `var_dump()` walk public properties |
| Python | `__repr__` | `repr()` on a config object prints the key |

**3. An error never carries key material.** `malformedAPIKey(length:)` carries the length,
not the key. An `Error` carrying the raw key ends up in integrator logs and crash
reporters — outside our control forever.

Each SDK carries a guard test asserting that a config or credential dump does not contain
the secret. Plant the secret in a dump and watch the test fail before trusting it.

### Known state

| SDK | State |
|---|---|
| Swift | conformant — credentials type is internal, redacts through both paths, errors carry length only |
| Android | **latent gap** — `IntemptConfigs` is an `internal data class` with `val apiKey`, so the generated `toString()` prints it. Not currently logged, and absent from `app.api`, so nothing leaks today. One future `logger.debug("configs: $configs")` changes that |
| PHP | being fixed — `public readonly string $apiKey` printed the secret through `print_r()` |
| Python | being fixed — `api_key` on the resolved config printed through `repr()` |
| Node | clean, by luck of its type shape rather than by design |

### Beyond the SDK's control, but state it

Some runtimes copy call arguments into stack traces, so the integrator's own
`Intempt(apiKey: …)` frame carries the key into every later exception. PHP does this
unless `zend.exception_ignore_args=1`. An SDK cannot fix it from inside; it can measure it
and document the mitigation as fact rather than as advice. Worth checking whether any JVM
or Apple crash reporter does the equivalent.

## Licensing

**Not uniform, and not safe to assume.** Each SDK's licence follows what it derives from.

| SDK | Licence | Because |
|---|---|---|
| `intempt-swift` | Apache 2.0 | vendors mixpanel-swift (Apache 2.0) |
| `intempt-android` | Apache 2.0 | vendors a Mixpanel substrate (Apache 2.0) |
| `intempt-reactnative` | Apache 2.0 | structure adapted from mixpanel-react-native (Apache 2.0) |
| `intempt-node` | **MIT** | mixpanel-node is MIT, so it could stay MIT |
| `intempt-python` | Apache 2.0 | derives from mixpanel-python (Apache 2.0) |
| `intempt-php` | Apache 2.0 | derives from mixpanel-php (Apache 2.0) |

MIT is one-way compatible into Apache 2.0, never the reverse. Before any SDK borrows code
from another, check both licences — copying Apache-licensed code into the MIT Node SDK is
a licence violation, and the reverse is fine.

One inherited attribution to carry if anything ever derives from it:
`mixpanel-php/lib/ConsumerStrategies/SocketConsumer.php` carries an **MIT © 2013
Segment.io** notice inside an otherwise Apache 2.0 repository. That attribution travels
with the file.

## Changing this document

A change here is a change to every SDK. It needs the same review as a breaking API
change, because it is one. Add the divergence to the table above rather than editing a
signature, unless every platform is moving together.
