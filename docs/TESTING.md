# Testing

## Gates, as CI actually runs them

| Gate | Command |
|---|---|
| Tests | `swift test` |
| Mutation | `./scripts/mutation-test.sh` — **see the script for its threshold** |

**The mutation gate is the real bar, not coverage.** Coverage says a line executed; mutation says an
assertion would have noticed if that line were wrong. A test asserting a value that was already true
before the code ran executes the line and kills no mutant.

## Rules

- **A test that has never failed has never been tested.** Before trusting a new one, break the line
  it covers and watch it go red.
- **Assert a deliberate absence too.** A branch meant to do nothing — an ignored header, a producer
  that must not earn a widening — is exactly what a mutant flips without any existing test noticing.
- **Read the score from CI, never locally.** Local toolchains drift from CI's, and a timed-out mutant
  is counted as killed, so a loaded machine reports a higher score than the truth.
- **The demo app compiling is part of the build.** `scripts/typecheck-demo.sh` and
  `typecheck-platforms.sh` are gates, because a suite that passes while the sample no longer compiles
  ships broken to the person evaluating the SDK.
