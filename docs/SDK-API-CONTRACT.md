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
| JavaScript | `intempt-js` | **out of scope — see below.** `intemptjs` is the same repository under its former name |
| Java | `intempt-java` | **read path only.** Feature flags and personalization; no capture, identity, consent or opt-out. Not published to Maven Central and carries no release tag |

Server SDKs conform on the shared capture surface — `track`, `identify`, `group`,
`alias`, `consent`, `optIn` / `optOut` — and diverge structurally everywhere a server has
no device, session or per-user state. Those divergences are enumerated under
[Server SDKs](#server-sdks) so nobody "fixes" them into conformance.

A divergence that is *gratuitous* rather than structural is a bug, and belongs in an
issue rather than in the table.

**Every shipped SDK appears in the table above, and a new SDK does not ship without an
entry in it.** The table is the inventory, not a summary of one — an SDK absent from it is
an SDK nobody has decided the shape of.

### Why JavaScript is out of scope, and what that costs

`intempt-js` predates this contract and ships a different shape: a three-state consent model
with its own status and clear methods, rather than the four opt-out methods every other
capture-class SDK exposes. Bringing it under the contract is a breaking change to the SDK
with the largest install base, and doing it badly is worse than the inconsistency.

Recorded as a deliberate exclusion rather than an oversight, so that the next person reading
this table does not "fix" it into conformance without that decision being taken. The cost is
real: a customer using both the web SDK and any other one meets two different opt-out APIs.

### Why Java is listed but not conforming

`intempt-java` carries the read path only. A capability present in three server SDKs and
absent from the fourth is a defect in the fourth, not a fifth category, so it is listed here
as incomplete rather than given a class of its own.

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

### `experiments()` is deliberately NOT in any SDK

**Decided 2026-08-15. There is no server-side support for experiment and
personalization assignment on mobile SDKs or server SDKs.** Assignment is an intemptjs
capability. No SDK should expose it, and this is not a mobile-only scope decision.

The endpoint answers, which is what made this easy to get wrong. Probed against the live
project:

```
POST /optimization/choose-api  ->  200 {"choices":[]}
```

A `200` with an empty set is indistinguishable from "this profile has no assignments yet",
so a client could ship the method, call it forever, and never branch on a result.

This reverses an earlier draft of this document, which specified `experiments()` because
the contract was drafted from `intempt-swift`, which implemented it. Writing a contract
from one implementation promotes that implementation's surface to a requirement.

Removal is required on every SDK that has it. Verified against each repository's default
branch on 2026-08-15:

| SDK | Action | State when checked |
|---|---|---|
| `intempt-swift` | remove `experiments()`, `ExperimentChoice`, `OptimizationType` | done |
| `intempt-reactnative` | remove the bridged method, spec entry and fixtures | done |
| `intempt-android` | **removal required** — `ModificationProvider`, `Intempt.experiment`, `Intempt.personalization` | still present in `core/Intempt.kt`, `core/types/interfaces.kt`, `modifications/Modifications.service.kt`, `Modification.component.kt`, `proguard-rules.pro`, with `ModificationsUnitTest.kt` and two README sections |
| `node` / `python` / `php` | must not be written with it | pages in draft |

An earlier revision of this section claimed Android had already removed these "as a
deliberate product decision, documented in its `CLAUDE.md`". That was wrong on both
counts — `intempt-android` has no `CLAUDE.md`, and the capability is live in its code —
and it mattered, because the action table told Android to do nothing. Swift and React
Native would have removed theirs while Android kept its, which is precisely the
divergence this document exists to prevent.

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

**4. Nothing hands the credential back.** Rules 1–3 govern what gets *printed*. A getter
is a different failure with the same consequence: nothing prints it, it is handed out on
request.

`intempt-android` shipped `QueueConfig.getAuthorization()` returning the base64 ingestion
credential in its published API surface. It is the second occurrence — `ConfigManagerService`
was the first — and it came back inside the vendored queue package where nobody was
looking. (Both live in the 3.0 work; `main` carries `ConfigManager.service.kt` and no queue
package, so this is not checkable against the default branch.) Every caller was already in
the same package, so package-private removed it at zero cost. It was public for no reason
at all.

### Grep the machine-readable surface, do not reason about it

Reading for this does not work. A reviewer only catches `getAuthorization` if they happen
to know it means "the key" while scanning a 448-line ABI dump. Grep the *declared* surface
instead:

```
apikey|api_key|secret|token|authorization|credential|password|bearer
```

| SDK | Surface to grep |
|---|---|
| Android | `app/api/app.api` (binary-compatibility-validator) |
| React Native | `lib/typescript/*.d.ts` (emitted, not source) |
| Swift | the public symbol list |

A hit is not automatically a defect — the credential is an *input* to `initialize()` on
every platform, and that is unavoidable. What matters is direction: **inputs are fine,
getters are not.**

**One honest limit, and state it in the test.** A guard test reading a checked-in dump
does not catch a source-level regression on its own — the dump is stale until regenerated.
What protects is a two-step chain, and both halves need verifying separately:

1. the ABI check fails on the drift, and runs in CI
2. the guard test fails on the regenerated dump

Android verified both — `apiCheck` exits 1 on `+ public fun getAuthorization`, and
planting an accessor line turned 1 of 5 tests red. Without step 1, step 2 is a green test
that proves less than it appears to.

Each SDK carries a guard test asserting that a config or credential dump does not contain
the secret. Plant the secret in a dump and watch the test fail before trusting it.

### Known state

| SDK | State |
|---|---|
| Swift | conformant — credentials type is internal, redacts through both paths, errors carry length only |
| Android | **latent gap** — `IntemptConfigs` is an `internal data class` with `val apiKey`, so the generated `toString()` prints it. Not currently logged, and absent from `app.api`, so nothing leaks today. One future `logger.debug("configs: $configs")` changes that |
| PHP | being fixed — `public readonly string $apiKey` printed the secret through `print_r()` |
| Python | being fixed — `api_key` on the resolved config printed through `repr()` |
| Node | clean, but by luck of its type shape rather than by design |
| React Native | conformant — grepped `lib/typescript/*.d.ts`: `apiKey` appears only as an input to `init()`, no getters. The JavaScript layer never retains it; `IntemptInstance` holds only the instance name |

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
