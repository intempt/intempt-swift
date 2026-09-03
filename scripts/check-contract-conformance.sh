#!/usr/bin/env bash
# Asserts the public surface still matches docs/SDK-API-CONTRACT.md.
#
# The contract is a description, and nothing enforced it. Three SDKs conform to
# it and a React Native bridge is generated against it, so a rename here does
# not break a Swift build — it breaks the bridge at runtime, on someone else's
# machine, later. This turns that into a failed job.
#
# Deliberately checks NAMES ONLY. Parameter labels and defaults are documented
# in the contract but drift for legitimate platform reasons; a name that
# disappears is never legitimate.
set -euo pipefail

SOURCES="Sources/Intempt"
fail=0

# Every symbol the contract names as part of the shared surface.
INSTANCE_METHODS=(
    initialize mainInstance instance
    track identify group record
    productAdd productView productOrdered
    consent
    getProfileId getSessionId
    logOut reset
    optIn optOut hasOptedOut isOptedIn
    flush
    products
    setPushToken trackPushOpen trackPushReceived
    variation allFlags
    boolVariation stringVariation numberVariation jsonVariation
    waitForInitialization
)

AUTOCAPTURE_MEMBERS=(configure start stop isRunning)

TYPES=(
    IntemptInstance AutocaptureOptions AutomaticEventOptions
    ConsentAction ProductRecommendation IntemptType IntemptError
    FlagContext
)

# Removed capabilities must STAY removed. Without this the check only guards
# against deletion, and a well-meaning re-add would pass.
# `variationDetail` and `FlagDetail` are WITHHELD, not missing: they would carry a reason the
# serving response does not send, so every reason would read `off` including for someone who was
# targeted and served. That decision was a comment until this line; now it is a gate.
FORBIDDEN=(experiments ExperimentChoice OptimizationType variationDetail FlagDetail)

echo "contract conformance"

for m in "${INSTANCE_METHODS[@]}"; do
    if grep -qrE "public (static )?(func|var) ${m}\b" "$SOURCES"; then
        printf '  ok       %s\n' "$m"
    else
        printf '  MISSING  %s\n' "$m"; fail=1
    fi
done

for m in "${AUTOCAPTURE_MEMBERS[@]}"; do
    if grep -qE "public (func|var|private\(set\) var) ${m}\b" "$SOURCES/Autocapture.swift"; then
        printf '  ok       autocapture.%s\n' "$m"
    else
        printf '  MISSING  autocapture.%s\n' "$m"; fail=1
    fi
done

for t in "${TYPES[@]}"; do
    if grep -qrE "public (final )?(class|struct|enum|protocol) ${t}\b" "$SOURCES"; then
        printf '  ok       %s\n' "$t"
    else
        printf '  MISSING  %s (type)\n' "$t"; fail=1
    fi
done

for f in "${FORBIDDEN[@]}"; do
    if grep -qrE "public (static )?(func|var|struct|enum|class) ${f}\b" "$SOURCES"; then
        printf '  READDED  %s — removed from the contract; see the Accepted divergences section\n' "$f"; fail=1
    else
        printf '  ok       %s absent\n' "$f"
    fi
done

if [ "$fail" -ne 0 ]; then
    echo
    echo "The public surface no longer matches docs/SDK-API-CONTRACT.md."
    echo "Either restore the symbol, or amend the contract in the same change —"
    echo "the React Native bridge is generated against it and fails at runtime, not build time."
    exit 1
fi

echo "public surface matches the contract"
