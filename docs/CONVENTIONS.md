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
  the server buckets, so no second implementation can disagree with it. `check-no-local-bucketing.mjs`
  enforces this in CI and a new bucketing helper fails the build.
- **A validation mistake throws; a service problem does not.** A blank key or a missing default is a
  programming error the caller can fix, so it fails loudly at the call site. A 5xx is absorbed.

## Credentials

The evaluation endpoint requires a **server** credential, sent as HTTP **Basic** — not Bearer. A
public key holds users and accounts and nothing else, and the response describes how every
experience in the project targets, so a public key is refused there. Never log it, never put it in a
URL.

## Swift specifics

- **A JSON null body is ABSENT, not a served value.** `.map` alone produces `.some(.null)`, and a
  `?? defaultValue` upstream does not fire on that, so the null has to be flattened away explicitly.
  This was a real defect, found only when a test was written for it.
- `swift format lint --recursive --strict Sources Tests` gates every commit. Formatting is not a
  preference here; a violation fails the build.
