# Conventions

**The cross-SDK surface is not decided here.** Every Intempt SDK conforms to
`intempt-swift/docs/SDK-API-CONTRACT.md`, which is the single authority on method names, argument
order, defaults and what is deliberately withheld. This file covers what is specific to Swift and
to this repo. Where the two disagree, the contract wins and this file is the bug.

## The rules that come from the contract

- **Flags are read by KEY; experiments and personalizations by `choose()` (D13, D20).** A flag read
  goes to `/flags/evaluate` (or `/flags/all`) and never to choose-api, which stops serving flags
  once audience-service `feature/feature-flag` ships. `choose()` is the only caller of choose-api.
- **`defaultValue` is REQUIRED, everywhere.** It is what a caller receives on a network failure, a
  timeout, an unknown key or a malformed response. An SDK that throws when the service is
  unreachable takes the application down with it, which is the opposite of what a kill switch is for.
- **A wrong-typed value falls back; it is never coerced.** A flag configured as a string and read as
  a boolean returns the caller's default, not `true`. Coercion makes a misconfiguration look like a
  deliberate value.
- **`variationDetail` never guesses a reason (INT-7454).** The server's reason is passed through;
  an answer without one this SDK knows reads `.unanswered`, a failure reads `.error` with an
  `errorCode`. Do not map `.unanswered` or `.error` onto `.off`.
- **Evaluation is REMOTE only.** No local rule engine, no flag store to poll, and no hashing utility:
  the server buckets, so no second implementation can disagree with it. `EXP-ASSIGN-004` (exact
  rollout boundaries) and `EXP-ASSIGN-005` (a person keeps their value across sign-in) are both
  properties of ONE derivation, and neither can hold for a second one the platform cannot see.
  `check-no-local-bucketing.mjs` enforces this in CI over `Sources`, `Tests` and `IntemptDemo`, and
  a new bucketing helper fails the build.
- **No flag call throws or traps (S11).** An empty or invalid key returns `defaultValue` with
  `FLAG_NOT_FOUND` and one warning per key; a context naming no visitor returns it with
  `TARGETING_KEY_MISSING`. A 5xx, a timeout and a malformed body resolve to `defaultValue` (or the
  last-known value, reason `.cached`). A missing default is not a runtime concern at all —
  `defaultValue` has no default, so omitting it does not compile.

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

`allFlags()` is one `/flags/all` request, which records no exposure (F32). The returned
`FlagValues` records the exposure itself: the first read of each served key sends `/flags/expose`
once for that map. `keys` and `count` read no value and record nothing; `dictionary` records every
served key, so use it only where every value is shown.

## Swift specifics

- **A JSON null body is ABSENT, not a served value.** `.map` alone produces `.some(.null)`, and a
  `?? defaultValue` upstream does not fire on that, so the null has to be flattened away explicitly.
  This was a real defect, found only when a test was written for it.
- `swift format lint --recursive --strict Sources Tests` gates every commit. Formatting is not a
  preference here; a violation fails the build.
