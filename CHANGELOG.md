# Changelog

All notable changes to the Intempt Swift SDK are documented here. This project
follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- **Push delivered / bounced / opened now reach Intempt.** `trackPushOpen` and
  `trackPushReceived` previously emitted only analytics events, and nothing consumed them:
  `IosSourceInitialization` provisions nine collections and none is a push collection, so
  both events were dropped after a 201. Both calls now also POST to
  `/webhooks/events/push-notification` — the same gateway route, the same
  `PushNotificationEvent` body and the same three statuses the Android SDK has always used.
  `trackPushOpen` reports `opened`; `trackPushReceived` reports `delivered`, or `bounced`
  when notifications are denied, mirroring `FirebaseService.notifySafely`'s
  `POST_NOTIFICATIONS` check. The analytics events still fire — this is additive.
  `destinationType` and `subject` are `apns`, matching `DestinationTypes.APNS` and
  `RSocketConnectorName.APNS`. A notification carrying no Intempt metadata makes no request.
  Requires single-metadata `feature/apns-destination-type` and destinations-processor #391,
  which is what puts the metadata in the payload.

  Reporting stops at `optOut()`. The webhook is not routed through `track`, so it carries its
  own gate — the body includes `masterId` and `accountId`, which identify a person.

  Failed reports are retried up to four times with a doubling delay, matching the Android
  SDK. A journey branches on these signals, so a dropped DELIVERED sends the wrong follow-up
  to a real person. A 4xx is not retried; it will be wrong again.

  iOS only wakes an app for a `content-available` or `mutable-content` notification, or one
  arriving in the foreground. Intempt's own sender sets neither, so today `delivered` and
  `bounced` fire only for foreground arrivals and a Notification Service Extension would not
  change that. `opened` is reported for every tap.

### Changed

- `Endpoint` gained `versionPrefix`, and `Network`'s default host is now the gateway root.
  The webhook routes are registered outside `/v1`, so a single host constant could not serve
  both families. `Endpoint.path` is unchanged and the existing wire assertions still hold.

## [0.3.0] — 2026-09-03

### Added

- **`useIPAddressForGeolocation` — an init-time opt-out for server-side geolocation.**
  `intempt/push-source-service#439` began deriving country, region and city at ingestion
  from the address the request already arrives on, on by default for every SDK. This adds
  the other half: a way to decline. `IntemptInstance.initialize(..., useIPAddressForGeolocation:
  false)` sends `?ip=0` on the track endpoint instead of `?ip=1`; the device never reads or
  sends its own address either way, and the platform discards the connection address after
  resolving it. Named after mixpanel-swift's option of the same name.
- **`PrivacyInfo.xcprivacy` now declares `NSPrivacyCollectedDataTypeCoarseLocation`.** The
  derived country/region/city is persisted and queryable, which is what Apple's privacy
  manifest rules mean by "collected", even though the IP itself is never stored.
  `PreciseLocation` is deliberately absent — nothing here touches CoreLocation.

### Removed

- **BREAKING:** `IntemptInstance.alias(userId:anotherUserId:)` and the `AliasModel` wire
  model. Linking two user identities is the CDP's job, not the caller's: identity
  resolution already converges two user ids the moment they share any identifier, so
  `alias` only reached the case where two ids never co-occur at all — an id-scheme
  migration, which belongs in a server-side backfill. A wrong call permanently fused two
  real people and there is no unmerge. `identify` is unchanged and remains the stitch
  trigger. `docs/CONTRACT.md` still lists the `alias` wire type because ingestion still
  accepts it; only the client surface is gone.

### Docs

- `docs/SDK-API-CONTRACT.md`'s SDK inventory now lists `intempt-java` and corrects the
  JavaScript SDK's repo name from `intemptjs` (former name) to `intempt-js`, with the
  reasons it stays out of the cross-SDK contract recorded rather than implied.

## [0.2.0] — 2026-08-31

A **minor** bump, not a patch: eleven new public declarations. The podspec sat at `0.1.1`
while CocoaPods trunk served only `0.1.0`, so `0.1.1` was never released and the surface
below would otherwise have shipped inside a patch version.

### Added

- **Feature flags, experiments and personalizations, read by key.** `variation`,
  `allFlags`, the four typed helpers (`boolVariation`, `stringVariation`,
  `numberVariation`, `jsonVariation`), `waitForInitialization` and
  `FlagContext`. Eight new public symbols, against
  `POST /{org}/projects/{project}/optimization/choose-api`. `defaultValue` is
  required everywhere: a network failure, a timeout, an unknown key or a
  malformed response all resolve to it rather than throwing. Evaluation is
  remote only — the server buckets, and `scripts/check-no-local-bucketing.mjs`
  fails the build on a second derivation.
- **`variationDetail` is deliberately WITHHELD** and stays internal until the
  serving response carries a `reason`. `ExperienceApiChoose` is
  `{name, group, body}` today, so every reason the method could return would
  read `off` — including for someone targeted and served. The conformance gate
  now enforces the absence rather than a comment describing it.
- **`docs/CONVENTIONS.md` and `docs/TESTING.md`**, and a CI job asserting bucket
  derivation stays server-only (`EXP-ASSIGN-004`, `EXP-ASSIGN-005`).

### Fixed

- **A JSON null body reached the caller as `JSONValue.null` instead of their
  default.** `.map` alone produces `.some(.null)`, which sails past `??`.
  `variation` and `allFlags` now share one `servedValue` helper so they cannot
  answer differently about the same key — they did, for one revision.
- **tvOS sent `device: "tv"`, which the service cannot deserialise.**
  `ExperienceDevice` is `all`/`desktop`/`mobile` with no `@JsonCreator`, so the
  whole request failed to bind and every flag read on tvOS returned the caller's
  default, silently. tvOS now reports `mobile`.
- **`sessionId` was never sent.** Without it `ChooserHelper` stores the literal
  `"default"`, so a `ONCE_PER_VISIT` experience was served once ever per profile
  rather than once per visit, and every Kafka `ExperienceChoose` from iOS was
  stamped `"default"`.
- **An unanswered evaluation reported `off`.** `EXP-SERVE-001` requires a caller
  to tell a deliberate off state from a request the service did not answer;
  `Flags.unanswered` aliased the two. `FlagReason` now carries a distinct,
  SDK-local `unanswered`.
- **A flag key the service refuses was sent anyway.**
  `ExperienceApiChooseRequest.names` is validated against `^[a-zA-Z0-9_-]*$` by
  `HandlerUtils.requestToMono`, so `variation("checkout.new")` spent a round trip
  to be refused and the caller could not tell that refusal from "no flag is
  configured" — both arrive as the default. `Flags.isValidKey` now rejects it
  locally. Deliberately not an `assertionFailure`: a dotted key is a naming
  mistake, not a structural bug, and aborting a debug build over one is worse
  than reading the default.
- **`scripts/check-no-local-bucketing.mjs` passed while scanning nothing.**
  `GUARD_SRC` defaulted to `src`, which no Swift package has, and a missing root
  yielded silently — so run without CI's environment the guard reported OK on a
  real breach. It now fails on a missing or empty root, defaults to this repo's
  own directories, and prints the file count it actually read. This was finding
  F1 of the `intempt-android` review, fixed there and not carried across; the
  script is vendored into every Intempt SDK, so the same hole exists wherever it
  landed with an empty allowlist.
- **`IntemptDemo` was outside the format gate.** `swift format lint` covered
  `Sources` and `Tests` only, which is why an indentation regression in the demo
  — the file an evaluator copies from — could go green.
- **`docs/CONTRACT.md` was wrong about `choose-api` in two ways** — it said the
  endpoint has no `names` array (it does, and it is the filter this whole
  surface depends on) and printed `choose-web`'s 200 body under a `choose-api`
  heading. Both cost an earlier reviewer a false CRITICAL against another SDK.

## [0.1.1] — 2026-08-18

### Added

- **Coverage measurement.** `swift test --enable-code-coverage` plus
  `scripts/coverage.sh`, reporting line/function/region coverage to the job log
  and the run summary. Reports without gating: `COVERAGE_MIN` turns enforcement
  on once a floor is chosen from a real figure. First run reports 88.95% line
  coverage.
- **Init-cost measurement.** `InitPerformanceTests` and a non-parallel `perf`
  CI job measuring cold init, warm init and one `track()` enqueue. First run
  reports 7.08 ms cold init and 0.22 ms median enqueue.

No changes to the shipped SDK. Every file under `Sources/` is byte-identical to
0.1.0 apart from the `sdkVersion` constant, so upgrading is a no-op for
behaviour. This release exists so the version reported by the SDK matches the
tag the measurement work landed under.

## [0.1.0] — 2026-08-16

### Added

Initial Swift SDK, replacing the deprecated Objective-C `IntemptTracker`. The
foundation is derived from mixpanel-swift (Apache 2.0) — see `NOTICE`.

- **Tracking** — `track`, `identify`, `group`, `alias`, `record`, and the three
  commerce events (`productView`, `productAdd`, `productOrdered`), all batched
  through a single `{"track":[…]}` envelope.
- **Storage** — SQLite in WAL mode, capped at 5,000 events, backup-excluded,
  with iOS data protection set for background access after first unlock.
- **Delivery** — timer-driven flush with exponential backoff (60s→600s,
  jittered), `Retry-After` honored as a floor, app-lifecycle triggers, and a
  background task assertion so a flush started on suspend can finish. A batch
  is claimed before the POST and deleted only on acknowledgement; stale claims
  from a crashed process are recovered at startup; undecodable rows and
  permanently-rejected batches are dropped rather than blocking the queue,
  while 401/403 never cost data.
- **Personalization** — `experiments` and `products` against
  `optimization/choose-api` and `feeds/{id}/data`.
- **Consent** — `consent(action:validUntil:)` transmitted to `consents/data`,
  with `.reject` enforcing the decision rather than merely recording it.
- **Autocapture (iOS)** — opt-in screen, touch and control capture via
  Objective-C runtime swizzling that is safe on inherited methods, refuses to
  double-install, and can be fully removed. Never records text-field contents,
  skips secure fields, and honours an `intempt-ignore` opt-out.
- **Push** — APNs device-token registration and push-open attribution.
- **Privacy** — `PrivacyInfo.xcprivacy` manifest declaring collected data types
  and required-reason API usage. No IDFA, no IDFV, no carrier lookup, no IP
  geolocation and no StoreKit observation: each was refused rather than
  omitted, because each imposes a consent prompt or a dependency on every
  embedding app.
- **Verification** — 285 tests including 10 that run end-to-end against
  production; a type-check gate across iOS, iOS Simulator, tvOS, watchOS and
  macOS; and a demo app with 15 XCUITests, the only place the UIKit code
  actually executes.

### Fixed relative to the deprecated Objective-C SDK

- Requests are no longer sent to `.../(null)/projects/(null)/...` when
  credentials are blank. `initialize` throws. The old SDK asserted, and
  `NSAssert` compiles out in Release.
- Server errors are no longer treated as success. The old SDK branched on
  `error != nil`, which `NSURLSession` leaves nil for 401, 403, 429 and 500 —
  so every server failure ran the destructive delete path.
- Events are no longer marked sent before the POST, and a success no longer
  blanket-deletes rows belonging to other in-flight batches.
- `consent(.reject)` now gates collection. The old SDK recorded the answer and
  enforced nothing.
- Mutable state is owned by a serial queue, eliminating the unsynchronized-ivar
  races in the old implementation.

### Fixed relative to upstream mixpanel-swift

Defects found while adapting, each covered by a test in
`Tests/IntemptTests/UpstreamComparisonTests.swift`:

- Deleting an empty id list produced `WHERE id IN )`, which failed to prepare,
  which triggered `recreate()`, which deleted the database. Deleting nothing is
  now a no-op.
- Any sqlite error — including a transient `SQLITE_BUSY` — destroyed the store.
  Failures are now classified: only `SQLITE_CORRUPT`/`SQLITE_NOTADB` recreate.
- Property validation stopped one level deep, so an invalid value nested inside
  an array-of-dictionaries reached the encoder. It now recurses.
- Non-finite doubles serialized to the string `"nan"`. They are rejected at the
  call boundary.
- Logging sinks were invoked while holding the lock that guards them, so a sink
  that logged deadlocked.
- Backoff state was coupled to the network class and read `Date()` internally,
  making the documented `Retry-After` behavior untestable. It is now an
  injectable value type with every branch covered.
