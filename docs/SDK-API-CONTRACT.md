# SDK API contract

The public method surface every Intempt client SDK conforms to.

`CONTRACT.md`, beside this file, defines the **wire** — what goes over HTTP, verified
against production. This file defines the **surface** — what an integrator calls. Both
live here because the Swift SDK's shape is canonical, decided 2026-08-15.

## Status

| Platform | Repo | Conforms |
|---|---|---|
| Swift | `intempt-swift` | canonical — this document describes it |
| Android | `intempt-android` | in progress, 3.0 clean break — flag surface NOT started, old shape still live |
| React Native | `intempt-reactnative` | in progress, bridges both — flag surface not started |
| Node | `intempt-node` | client surface only; see Server SDKs — four `choose*` methods still live, to be replaced |
| Python | `intempt-python` | client surface only; see Server SDKs — flag surface never written |
| PHP | `intempt-php` | client surface only; see Server SDKs — flag surface never written |
| Java | `intempt-java` | repo created 2026-08-25; already ships the flag types on this wire vocabulary. **Read path only** — feature flags and personalization; no capture, identity, consent or opt-out. Not published to Maven Central and carries no release tag |
| JavaScript | `intempt-js` | **out of scope — see below.** `intemptjs` is the same repository under its former name |

The flag-surface column of this table is a summary of
[Per-SDK state](#per-sdk-state-verified-2026-08-31-against-each-default-branch); that table is the
detail and the two are updated together. They disagreed for one revision, which is how a reader
ended up with two different answers about Android in one file.

Server SDKs conform on the shared capture surface — `track`, `identify`, `group`,
`consent`, `optIn` / `optOut` — and diverge structurally everywhere a server has
no device, session or per-user state. Those divergences are enumerated under
[Server SDKs](#server-sdks) so nobody "fixes" them into conformance.

A divergence that is *gratuitous* rather than structural is a bug, and belongs in an
issue rather than in the table.

**Every shipped SDK appears in the table above, and a new SDK does not ship without an
entry in it.** The table is the inventory, not a summary of one — an SDK absent from it is
an SDK nobody has decided the shape of.

## JavaScript is out of scope

`intempt-js` predates this contract and is excluded from it deliberately. The reasons, so
nobody reopens the question or "fixes" the SDK toward a shape it was never built for:

1. **It ships a three-state consent model, not an opt-in/opt-out pair.** Its surface is
   `accept` / `reject` with its own stored state, and its persistence is a cookie with a
   localStorage fallback — deliberate, because an origin-scoped store alone loses an
   opt-out across subdomains. Rewriting that as a two-state pair would change behaviour
   for every site already using it.
2. **It is the only SDK with autocapture of arbitrary page content.** The contract's
   capture rules assume a caller naming an event; `intemptjs` also captures what a person
   typed. That is a different privacy surface and needs its own rules, not these.
3. **It has the largest installed base and no major-version break planned.** The other
   SDKs adopted the contract at a clean break. This one has no such break scheduled, so
   conformance would be a breaking change with no version to carry it.

Excluded does not mean unowned. Its published documentation must describe the API it
actually ships, and its opt-out must persist — both are tracked as requirements against
`intempt-js` itself rather than against this contract. The cost is real: a customer using
both the web SDK and any other one meets two different opt-out APIs.

## The server SDK surface

The Status table marks the server SDKs "client surface only", which says what they are
*not* without ever saying what they *are*. This section says what they are.

It is deliberately **not** called "Server SDKs": [Accepted divergences](#accepted-divergences)
already contains a `### Server SDKs` heading listing what a server SDK structurally lacks,
and two headings of the same name would give one of them a `-1` anchor and silently
retarget the existing link at the top of this document. The two are complements — that one
records the absences, this one records the surface.

**Published server SDKs:** `intempt-node`, `intempt-python`, `intempt-php`.

`intempt-java` is **not in the published set.** It has no publish workflow, so no consumer
can depend on it, and it currently exposes flag reads only. It joins this table the day it
publishes; until then a capability missing from it is not a conformance defect.

### The shared server surface

Every published server SDK exposes these, in the naming convention of its language:

| Capability | Node / PHP | Python |
|---|---|---|
| Capture one event | `track` | `track` |
| Capture many | `trackBatch` | `track_batch` |
| Identify a person | `identify` | `identify` |
| Associate an account | `group` | `group` |
| Link two identities | `alias` | `alias` |
| Opt in / opt out / status | `optIn` `optOut` `isOptedIn` | `opt_in` `opt_out` `is_opted_in` |
| Read personalization | `recommend` | `recommend` |
| Change configuration | `setConfig` `config` | `set_config` `config` |
| Flush and shut down | `flush` `close` | `flush` `close` |

### What a server SDK does NOT have

No device, no session, no per-user state on the instance, therefore no automatic events,
no autocapture, no screen tracking, and no anonymous-identity rotation. A server SDK is
given the identity by its caller on every call. These absences are structural and must not
be "fixed" into conformance.

### Structural divergences that are permitted

| Divergence | Where | Why it is allowed |
|---|---|---|
| Consent and ecommerce as separate objects rather than instance methods | PHP, Node | Namespacing is idiomatic in both; Python puts them on the client for the same reason |
| Buffer inspection (`buffered`) | Python, PHP | Exposed where the language has no natural way to observe a queue otherwise |

### Divergences that are NOT permitted

A capability present in some published server SDKs and absent in others, where nothing
about the language explains the gap, is a defect in the ones missing it. Two exist today
and are open against the SDKs, not against this document:

| Capability | Present in | Absent from |
|---|---|---|
| `trackLines` | PHP | Node, Python |
| `transport` accessor | PHP, Node | Python |

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
initialize(apiKey, orgId, projectId, sourceId, instanceName = "default",
           useIPAddressForGeolocation = true) -> Instance
```

Throws on a malformed API key (not `prefix.secret`) and on any blank identifier.

`useIPAddressForGeolocation` decides whether Intempt derives country, region and city
from the address the request arrives on. It defaults to **on**, matching what ingestion
assumes when the flag is absent, so an unset switch and an unpatched server agree. Every
capture-class SDK MUST accept it: an SDK that ignores it ships a decorative opt-out.

The value MUST be readable back after initialisation. An SDK whose initialise is idempotent
returns the existing instance on a second call, so without a reader a caller has no way to
find out which value is in force — Swift exposes `public let useIPAddressForGeolocation`.

**An SDK whose initialise is idempotent MUST NOT silently discard this argument on a
later call.** Returning a cached instance and dropping the flag fails in the
privacy-unsafe direction, and "initialise at launch, initialise again after the consent
banner" is the ordinary shape. Log it at minimum; a settable property is better.

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

### Feature flags and assignment — `variation()`

**Decided 2026-08-24. Assignment IS exposed by every SDK, through the surface below.**

> **GOVERNANCE — NOT YET RECORDED ON BRAIN. This section reverses a standing product ruling,
> and an SDK repository is not where that reversal becomes true.**
>
> `brain/product/changes/2026-08-16-react-native-sdk-and-mobile-surface-scope.md:15-24` records:
> *"Experiments are not a mobile capability. … Resolved: experiment and personalization
> assignment is an intemptjs capability and belongs in no mobile SDK. Swift removes it."*
> Nothing on brain `origin/main` supersedes it. The v2.3→v2.6 spec work opened the `api` surface
> generically without revisiting the mobile question.
>
> The derivation below is sound on its own terms — `experiences-spec.md:54-57` and `:81-84` make
> a Feature flag `channel=api`, and `:65-67` says *"A mobile app is in the bottom row because
> there is no page for an editor to point at, not because it is a phone"* — so an iOS SDK
> reading by key genuinely is `api`-surface. **A sound derivation is still not a reversal of a
> recorded ruling.** `brain/engineering/changes/2026-08-16-cross-sdk-contract-and-react-native.md:29-32`
> notes this contract had *"quietly overruled a deliberate product decision"* once already, and
> the paragraph under "What stays removed" below warns about exactly this shape.
>
> **Owner: the PO.** Required before any SDK publishes this surface: a product change on brain
> recording the reversal. Until that lands, treat this section as an engineering proposal that
> the code happens to implement, not as settled product scope.
This supersedes the 2026-08-15 decision recorded here, which read *"There is no
server-side support for experiment and personalization assignment on mobile SDKs or
server SDKs. Assignment is an intemptjs capability. No SDK should expose it."*

That decision was correct about the wire as it stood, and its reasoning is worth keeping
because it is the acceptance criterion for the replacement. It rested on one observation:

```
POST /optimization/choose-api  ->  200 {"choices":[]}
```

A `200` with an empty set is indistinguishable from "this profile has no assignments
yet", so a client could ship the method, call it forever, and never branch on a result.

**The premise is being removed rather than argued with — but it has NOT been removed yet.**
The serving contract *is specified to* return an answer that is self-describing: every
evaluation carries a `reason`, and an off value is distinguishable from no answer. That is
the target, not the present tense. Today `ExperienceApiChoose` is `{name, group, body}`,
`git grep -n reason` over
`audience-service/src/main/java/com/intempt/cdp/audience/experience/` returns 0, and brain
records the gap at §8 item 37 under `EXP-SERVE-001`. Once a caller can tell "not enrolled"
from "no answer", the objection no longer holds and the capability belongs in the SDKs — a
feature flag that only one platform can read is not a feature flag.

Until then, `variation()` ships and `variationDetail()` does not. That split is what makes
the surface honest while the contract is pending: `variation` returns a VALUE, which is
correct whether or not a reason exists, and the caller's required `defaultValue` covers the
absent case. A reason is the only thing that cannot be answered honestly today, so the only
method withheld is the one whose entire job is to give one.

#### The surface

```
variation(key, context, defaultValue)         -> T
allFlags(context)                             -> Map<key, value>

variationDetail(key, context, defaultValue)   -> WITHHELD, see rule 3

boolVariation   (key, context, defaultValue: Bool)
stringVariation (key, context, defaultValue: String)
numberVariation (key, context, defaultValue: Number)
jsonVariation   (key, context, defaultValue: Object)

waitForInitialization(timeout)
```

Four rules, each of which is a correction to the shape being replaced:

1. **The caller asks for a key, never a mode.** The old surface put the mode in the method
   name — `choosePersonalizationsByNames`, `chooseExperimentsByGroups` — which forced an
   integrator to know whether a key was an experiment before reading it, and made the
   surface grow combinatorially with every new mode. The platform already resolves mode
   itself; its serving query filters on channel and status and never on mode.
2. **`defaultValue` is required, not optional.** It is what the call returns on a network
   failure, a timeout, an unknown key, or a malformed response. Optional is how `undefined`
   reaches production during an outage.
3. **`variationDetail` is WITHHELD until the platform sends a reason.** It was specified
   here as the half answering the 2026-08-15 objection, and the objection stands — but the
   evaluation response does not carry a reason today. A held-back person's experience is
   absent from it entirely rather than present with a cause, so every reason the method
   could return would read `off`, including for someone who WAS targeted and did receive
   the variant. Value says on, reason says off: a wrong answer, not a missing one, from
   the one method whose entire job is explaining why.

   No SDK exposes it. Each keeps the logic internal, because `variation` uses it for the
   value — which is correct either way — and each turns it public in the same change that
   adds `reason` to the serving contract.

   `variant` goes with it. It was the experience's selector GROUP, not the variant name,
   which the platform never carries to the response layer at all.
4. **No local evaluation.** Remote only. Rule-shaped local evaluation is deliberately out
   of scope on every platform.

Naming follows each language: `variation_detail` / `all_flags` in Python, camelCase
elsewhere.

#### Channel — a mobile SDK is treated as server

The serving channel is not "client vs server" in the runtime sense. It is whether a visual
editor can author the change:

- **`web`** — the browser channel. The change is authored visually against the DOM and
  applied without the caller branching. `intemptjs` is the only SDK on it.
- **`api`** — every other consumer. The caller receives a value and branches on it in code.

**A mobile SDK runs on a client device and still sits on the `api` channel**, because there
is no visual editor for a native surface. A flag or experience for iOS or Android cannot be
set up visually, so it is authored as a payload and read the way a server reads one.
`intempt-swift`, `intempt-android` and `intempt-reactnative` therefore consume `choose-api`
alongside the four server SDKs, and the flag key is surfaced to them for the same reason it
is surfaced to a server: the integrator writes the branch.

Seven of the eight SDKs below are `api`-channel. Only `intemptjs` is `web`. Reading mobile
as `web` because the code runs on a phone is the mistake this paragraph exists to prevent.

#### What stays removed

The 2026-08-15 removals stand. `experiments()`, `ExperimentChoice`, `OptimizationType`,
`ModificationProvider`, `Intempt.experiment` and `Intempt.personalization` are superseded
by the surface above, not restored. The old shape's `optimizationType` argument is dead on
the wire — it has **zero** references in the serving code and every SDK that still sends it
is sending a field nothing reads.

Two lessons this section has already paid for, kept because they still apply. **Writing a
contract from one implementation promotes that implementation's surface to a requirement** —
the 2026-08-15 revision specified `experiments()` only because Swift happened to implement
it. And an earlier revision asserted Android had already removed the old shape "as a
deliberate product decision"; it had not, and the action table consequently told Android to
do nothing while Swift and React Native removed theirs — the exact divergence this document
exists to prevent. Verify per repository, against its default branch, on the date stated.

#### Per-SDK state, verified 2026-08-31 against each default branch

| SDK | Old shape | Action |
|---|---|---|
| `intempt-swift` | removed 2026-08-15 | add the surface |
| `intempt-reactnative` | removed 2026-08-15 | add the surface, both native sides plus the bridge |
| `intempt-android` | **still live** in `core/Intempt.kt`, `core/types/interfaces.kt`, `modifications/Modifications.service.kt`, `Modification.component.kt`, `proguard-rules.pro`, `ModificationsUnitTest.kt` and two README sections; `Modifications.service.kt` puts `optimizationType` on the wire | remove the old shape, add the surface |
| `intempt-node` | **still live** — four `choose*` methods | replace |
| `intempt-python` | never written | add |
| `intempt-php` | never written | add |
| `intempt-java` | **repo exists** — created 2026-08-25, last push 2026-08-28, ships `FlagContext`, `FlagDetail`, `FlagReason` | it already carries `FlagReason{TARGETED("targeted"), HOLDOUT("holdout"), NOT_TARGETED("not_targeted"), OFF("off")}` — the same lowercase wire vocabulary as Swift, so there is no wire divergence. One SDK-local divergence to close: Java resolves an unrecognised reason to `OFF`, which is the alias `EXP-SERVE-001` forbids. Swift removed it on 2026-08-31 by adding a distinct SDK-local `unanswered`; Java should do the same |
| `intemptjs` | the only platform with assignment today | out of contract scope, tracked separately |

#### Gate

**No SDK PUBLISHES `variationDetail()` before the serving contract lands, and no SDK
publishes `variation()` without a required `defaultValue`.** A published method name cannot
be withdrawn from npm, PyPI, Packagist or Maven — that is what makes a release irreversible
in a way a merge is not. A `variationDetail` that returns a value without a real `reason`
reintroduces exactly the ambiguity this section exists to close, so it stays internal in
every SDK until the serving response carries one.

`variation()` is not held behind that gate. It answers with a value, which is correct
today, and the required `defaultValue` is what covers the absent case. An earlier revision
of this Gate said no SDK ships `variation()` at all before the contract lands, which
contradicted the paragraph 60 lines above it and would have blocked the surface on a
requirement `variation()` does not have.

**Merging is not shipping, and the distinction is load-bearing.** In this repo
`publish-cocoapods.yml` is `workflow_dispatch` only, deliberately, so landing on `main`
publishes nothing to CocoaPods. SPM resolves a branch, though, so `main` IS reachable to an
integrator the moment a change lands there — treat `main` as a soft release and the tag as
the hard one.

Recommendation feeds are unaffected and stay on every platform — see `products()` above.

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
