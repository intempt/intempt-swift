# Changelog

All notable changes to the Intempt Swift SDK are documented here. This project
follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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
