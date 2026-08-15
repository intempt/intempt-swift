#!/usr/bin/env bash
# Mutation testing: plant a real defect, assert the suite goes red, restore.
#
# Coverage says a line executed. It does not say an assertion would have noticed
# the line being wrong — and a test that has never failed has never been tested.
# Every mutant below is a defect this SDK could plausibly ship: an off-by-one in
# a retry budget, a batch deleted before the server acknowledged it, a split on
# the wrong dot. If the suite stays green, that behaviour is unguarded.
#
# Not random mutation. Each one is chosen against a specific invariant, and each
# carries the reason it matters, so a survivor is immediately actionable.
#
# Usage: scripts/mutation-test.sh [--quick]
#   --quick   run only the test target that covers each mutant (much faster)
set -uo pipefail

cd "$(dirname "$0")/.."
QUICK="${1:-}"

# REFUSES to run with a dirty working tree.
#
# restore() is `git checkout -- <file>`, which discards uncommitted changes to
# that file. Running this over unstaged work silently destroys it — which it did
# to me: an extraction sitting uncommitted in EventNames.swift was reverted
# mid-run, and the commit that followed carried the call site without the
# function. Committed work is recoverable; unstaged work is not.
if ! git diff --quiet || ! git diff --cached --quiet; then
    echo "working tree is dirty — commit or stash first." >&2
    echo "this script restores mutated files with 'git checkout --', which would" >&2
    echo "discard uncommitted changes to any file it touches:" >&2
    git status --porcelain --untracked-files=no | sed 's/^/    /' >&2
    exit 2
fi

killed=0
survived=0
invalid=0
declare -a SURVIVORS

# file | search | replace | invariant it breaks
MUTANTS=(
"Sources/Intempt/IntemptCredentials.swift|maxSplits: 1|maxSplits: 9|the API key splits on the FIRST dot only; a secret containing a dot must not be truncated into extra parts"
"Sources/Intempt/Flush.swift|maxStrikes = 3|maxStrikes = 300|a payload the server keeps rejecting must be dropped after a bounded number of attempts, not retried forever"
"Sources/Intempt/Push.swift|count >= 32|count >= 1|a stringified token (\"32 bytes\") must be rejected; accepting it registers a device that can never be reached"
"Sources/Intempt/Constants.swift|[408, 429, 500, 502, 503, 504]|[408, 500, 502, 503, 504]|429 must be retryable; treating a rate limit as terminal discards the events"
"Sources/Intempt/IntemptDB.swift|ORDER BY time ASC|ORDER BY time DESC|eviction must drop the OLDEST rows; dropping newest throws away what just happened and keeps stale data"
"Sources/Intempt/EventNames.swift|isValueChange ? editField : action|isValueChange ? action : editField|a control value change is Edit Field and a press is Action; swapping them mislabels every interaction"
"Sources/Intempt/IdentityManager.swift|>= Self.sessionTimeout|> Self.sessionTimeout * 1000|the idle window is what ends a session; widening it means sessions never roll"
"Sources/Intempt/Flush.swift|db.setFlag(.events, ids: goodIds, to: true)|db.setFlag(.events, ids: goodIds, to: false)|a batch must be CLAIMED before it is sent; without the claim a concurrent flush sends the same rows twice"
"Sources/Intempt/IntemptDB.swift|SET flag = 0 WHERE flag = 1|SET flag = 1 WHERE flag = 0|startup must RELEASE claims stranded by a crash; inverting it strands every unsent row permanently"
"Sources/Intempt/IntemptInstance.swift|case .reject: optOut()|case .reject: break|consent(.reject) must ENFORCE, not merely record — the old SDK gated nothing (F-42)"
"Sources/Intempt/Flush.swift|self.db.setFlag(.events, ids: goodIds, to: false)\n                    self.strikes.removeValue|self.db.setFlag(.events, ids: goodIds, to: true)\n                    self.strikes.removeValue|a retryable failure must RELEASE the claim; leaving rows claimed makes them invisible to every later pass"
"Sources/Intempt/JSONHandler.swift|CFGetTypeID(num) == CFBooleanGetTypeID()|CFGetTypeID(num) != CFBooleanGetTypeID()|a Bool must serialise as a JSON boolean; CFBoolean bridges to NSNumber and would otherwise go out as 1"
"Sources/Intempt/Network.swift|request.setValue(credentials.basicAuthHeader, forHTTPHeaderField: \"Authorization\")|request.setValue(credentials.basicAuthHeader, forHTTPHeaderField: \"X-Authorization\")|the Basic auth header is what authenticates every request; a renamed header is a 401 on everything"
"Sources/Intempt/IdentityManager.swift|_sessionEventCount = 0|_sessionEventCount = 1|logOut must clear session state; a carried-over count attributes the previous user's activity to the next one"
"Sources/Intempt/Flush.swift|db.read(.consents, limit: 1, flag: false)|db.read(.consents, limit: 1, flag: true)|consents drain from the unclaimed set; reading claimed rows means a withdrawal is never transmitted"
)

restore() {
    git checkout -- "$1" 2>/dev/null || true
}

echo "mutation testing — $(( ${#MUTANTS[@]} )) mutants"
echo

for entry in "${MUTANTS[@]}"; do
    IFS='|' read -r file search replace why <<< "$entry"
    if [ -z "${why:-}" ]; then
        echo "  MALFORMED mutant (needs 4 pipe-separated fields): ${entry:0:60}" >&2
        invalid=$((invalid+1)); continue
    fi

    if [ ! -f "$file" ]; then
        echo "  SKIP     $file (not found)"
        continue
    fi
    if ! grep -qF "$search" "$file"; then
        echo "  SKIP     ${file##*/}: '$search' not present — the mutant is stale, fix it"
        continue
    fi

    trap 'restore "$file"' EXIT
    # Only the first occurrence, so the mutant stays a single defect.
    perl -0pi -e "s/\Q$search\E/$replace/" "$file"

    # A mutant that does not COMPILE is not a killed mutant — the suite never
    # ran. Counting it as killed inflates the score with defects no assertion
    # ever saw, which is the exact failure this whole script exists to prevent.
    if ! swift build --build-tests > /tmp/mutation-build.log 2>&1; then
        echo "  INVALID  ${file##*/}: $search -> $replace (does not compile)"
        invalid=$((invalid+1))
        restore "$file"
        trap - EXIT
        continue
    fi

    if swift test --parallel > /tmp/mutation-run.log 2>&1; then
        survived=$((survived+1))
        SURVIVORS+=("${file##*/}: $search -> $replace
             $why")
        echo "  SURVIVED ${file##*/}: $search -> $replace"
    else
        killed=$((killed+1))
        echo "  killed   ${file##*/}: $search -> $replace"
    fi

    restore "$file"
    trap - EXIT
done

total=$((killed+survived))
echo
echo "killed $killed / $total"
[ "$invalid" -ne 0 ] && echo "INVALID $invalid — mutants that did not compile; they prove nothing, fix them"

if [ "$survived" -ne 0 ] || [ "$invalid" -ne 0 ]; then
    echo
    echo "SURVIVING MUTANTS — the suite did not notice these defects:"
    for s in ${SURVIVORS[@]+"${SURVIVORS[@]}"}; do
        echo "  - $s"
    done
    exit 1
fi

echo "every planted defect was caught"
