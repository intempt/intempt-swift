# Conventions

**The cross-SDK surface is not decided here.** Every Intempt SDK conforms to
`intempt-swift/docs/SDK-API-CONTRACT.md`, which is the single authority on method names, argument
order, defaults and what is deliberately withheld. This file covers what is specific to Swift and
to this repo. Where the two disagree, the contract wins and this file is the bug.

## The rules that come from the contract

- **A caller asks for a KEY, never a mode.** The platform resolves whether a key is an experiment, a
  personalization or a flag; its serving query filters on channel and status and never on mode. A
  method name that encodes the mode forces an integrator to know the answer before they can ask the
  question, and grows combinatorially with every mode added.
- **`defaultValue` is REQUIRED, everywhere.** It is what a caller receives on a network failure, a
  timeout, an unknown key or a malformed response. An SDK that throws when the service is
  unreachable takes the application down with it, which is the opposite of what a kill switch is for.
- **A wrong-typed value falls back; it is never coerced.** A flag configured as a string and read as
  a boolean returns the caller's default, not `true`. Coercion makes a misconfiguration look like a
  deliberate value.
- **`variationDetail` is NOT exposed.** It would carry a reason, and the serving response does not
  send one — so it could only report "off" for a person who was in fact targeted and served, which
  is the single thing such a method exists to tell you. It stays internal until the platform sends a
  reason. Do not re-add it, and do not document it on a docs page either.
- **Evaluation is REMOTE only.** No local rule engine, no flag store to poll, and no hashing utility:
  the server buckets, so no second implementation can disagree with it. `EXP-ASSIGN-004` (exact
  rollout boundaries) and `EXP-ASSIGN-005` (a person keeps their value across sign-in) are both
  properties of ONE derivation, and neither can hold for a second one the platform cannot see.
  `check-no-local-bucketing.mjs` enforces this in CI over `Sources`, `Tests` and `IntemptDemo`, and
  a new bucketing helper fails the build.
- **A validation mistake is loud in DEBUG; a service problem is absorbed everywhere.** A blank key
  is a programming error the caller can fix, so it trips `assertionFailure` at the call site — and
  `assertionFailure` is compiled out under `-O`, so in a shipped build the call yields
  `defaultValue` with no signal. That is the deliberate trade: trapping someone's app over a flag
  key is worse than the flag reading its default. This rule used to say "throws", which the code
  has never done and should not; say what it does. A 5xx, a timeout and a malformed body are
  absorbed in every configuration and resolve to `defaultValue`. A missing default is not a
  runtime concern at all — `defaultValue` has no default, so omitting it does not compile.

## Credentials

**What this SDK does today.** Every request, `choose-api` included, sends
`Authorization: Basic base64(prefix:secret)` built from whatever key reached `Intempt.initialize`
(`Sources/Intempt/Network.swift`, `Sources/Intempt/IntemptCredentials.swift`). On a phone that is
the public source key. There is no second credential, no Bearer path and no per-endpoint key.
Never log it and never put it in a URL.

**What the credential model SHOULD be is an open decision, and it is not settled here.** D4 in
`brain/product/specs/experiences/experiences-spec.md:316` — *"Does the server evaluation endpoint
require a credential?"* — is recorded as open with **no recommendation**, and the spec says it
blocks the audience-service work. `EXP-SERVE-004` (C) asks for a server credential on the
SDK-surface evaluation path; review asked for that requirement to be removed and the call made
with an API key instead. The two are not compatible and this file has no standing to pick one.

An earlier revision of this section asserted the strict reading as settled fact. Taken literally
by an iOS integrator it says to embed a server credential in a shipped app binary, where it is
extractable — so it was both a resolution of somebody else's open decision and, if followed, a
credential-exposure defect. Do not restore it. When D4 is ruled, update this section to whatever
was ruled and change the code in the same commit if the two differ.

## Reading every flag at once

`allFlags()` is one request instead of N, and that is its cost as well as its point.
`ExperienceChooserService.chooseApi` calls `ChooserHelper.display(...)` for **every** experience it
retrieves, before variant choice, and `display` records the display. For an experience configured
with the `ONCE` display mode, `allowOnce` succeeds only while the stored value is empty — so a
single `allFlags()` burns the once-only display for every qualifying experience at once, including
ones the app never renders. A later `variation(key:)` for one of those keys falls through to
`Mono.empty()`, drops out of `choices`, and returns the caller's `defaultValue` permanently, which
looks exactly like "not enrolled". It also inflates the exposure counts `EXP-SERVE-003` makes
load-bearing for results.

Prefer `variation(key:)` per key on any project that uses `ONCE`. The real fix is a non-recording
read mode on the serving endpoint; that is an audience-service change, not an SDK one.

## Swift specifics

- **A JSON null body is ABSENT, not a served value.** `.map` alone produces `.some(.null)`, and a
  `?? defaultValue` upstream does not fire on that, so the null has to be flattened away explicitly.
  This was a real defect, found only when a test was written for it.
- `swift format lint --recursive --strict Sources Tests` gates every commit. Formatting is not a
  preference here; a violation fails the build.
