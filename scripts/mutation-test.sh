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
"Sources/Intempt/RetryPolicy.swift|case .transport: return .keepForNextFlush|case .transport: return .drop(.dropped)|a batch that never reached the server must be KEPT for the next flush; dropping it loses every event recorded offline (INT-7436)"
"Sources/Intempt/Flush.swift|if self.transportReported.insert(head).inserted {|if true {|a kept batch is reported once, not on every flush an offline device attempts (INT-7444)"
"Sources/Intempt/Flush.swift|> QueueConstants.consentMaxAge|> QueueConstants.consentMaxAge * 1000|a consent kept while offline must be dropped after 30 days, or it parks the queue head forever"
"Sources/Intempt/Push.swift|count >= 32|count >= 1|a stringified token (\"32 bytes\") must be rejected; accepting it registers a device that can never be reached"
"Sources/Intempt/Constants.swift|deliveryResendStatuses: Set<Int> = [429, 503]|deliveryResendStatuses: Set<Int> = [503]|429 earns the one resend; treating a rate limit as final drops events the server asked to have resent (INT-7436)"
"Sources/Intempt/RetryPolicy.swift|APIConstants.deliveryResendStatuses.contains(status)|APIConstants.retryableStatuses.contains(status)|event and consent delivery resend only 429/503; a resent 500 may duplicate a batch the server already processed (INT-7436, R6)"
"Sources/Intempt/Constants.swift|[408, 429, 500, 502, 503, 504]|[429, 503]|push webhooks and feeds keep their pre-send-once retry set; narrowing the shared set silently stops push retries on a 500 (R6)"
"Sources/Intempt/Network.swift|NSURLErrorServerCertificateUntrusted,|NSURLErrorTimedOut,|a TLS handshake failure never reached the server; dropping it loses a batch the server never saw (R5)"
"Sources/Intempt/Flush.swift|reportConsentDropped(\"undecodable\")|_ = 0|a consent dropped before any request must still reach onDeliveryFailure; a silent consent loss is a compliance failure (R2)"
"Sources/Intempt/IntemptDB.swift|ORDER BY time ASC|ORDER BY time DESC|eviction must drop the OLDEST rows; dropping newest throws away what just happened and keeps stale data"
"Sources/Intempt/EventNames.swift|isValueChange ? editField : action|isValueChange ? action : editField|a control value change is Edit Field and a press is Action; swapping them mislabels every interaction"
"Sources/Intempt/IdentityManager.swift|>= Self.sessionTimeout|> Self.sessionTimeout * 1000|the idle window is what ends a session; widening it means sessions never roll"
"Sources/Intempt/Flush.swift|db.setFlag(.events, ids: goodIds, to: true)|db.setFlag(.events, ids: goodIds, to: false)|a batch must be CLAIMED before it is sent; without the claim a concurrent flush sends the same rows twice"
"Sources/Intempt/IntemptDB.swift|SET flag = 0 WHERE flag = 1|SET flag = 1 WHERE flag = 0|startup must RELEASE claims stranded by a crash; inverting it strands every unsent row permanently"
"Sources/Intempt/IntemptInstance.swift|case .reject: optOut()|case .reject: break|consent(.reject) must ENFORCE, not merely record — the old SDK gated nothing (F-42)"
"Sources/Intempt/Flush.swift|self.db.setFlag(.events, ids: goodIds, to: false)|self.db.setFlag(.events, ids: goodIds, to: true)|a retryable failure must RELEASE the claim; leaving rows claimed makes them invisible to every later pass"
"Sources/Intempt/JSONHandler.swift|CFGetTypeID(num) == CFBooleanGetTypeID()|CFGetTypeID(num) != CFBooleanGetTypeID()|a Bool must serialise as a JSON boolean; CFBoolean bridges to NSNumber and would otherwise go out as 1"
"Sources/Intempt/Network.swift|request.setValue(credentials.basicAuthHeader, forHTTPHeaderField: \"Authorization\")|request.setValue(credentials.basicAuthHeader, forHTTPHeaderField: \"X-Authorization\")|the Basic auth header is what authenticates every request; a renamed header is a 401 on everything"
"Sources/Intempt/Flush.swift|db.read(.consents, limit: 1, flag: false)|db.read(.consents, limit: 1, flag: true)|consents drain from the unclaimed set; reading claimed rows means a withdrawal is never transmitted"
# Flags and choose (F32/F15/F30, SDK-ALIGN). Each is a rule intempt-node's flag evaluator holds
# and this SDK now ports; the killing test is named in FlagsTests, FlagStreamTests, ChooseTests or
# FlagSurfaceTests.
"Sources/Intempt/Flags.swift|!key.isEmpty && key.unicodeScalars.allSatisfy(allowedKeyCharacters.contains)|!key.isEmpty|a key the server's ^[a-zA-Z0-9_-]*$ pattern rejects must not be sent; requestToMono refuses the whole body, and the caller cannot tell that refusal from \"no flag configured\""
"Sources/Intempt/Flags.swift|if disableExposure {|if !disableExposure {|a disableExposure read must go to /flags/all, which records nothing; /flags/evaluate records the exposure the caller asked to skip"
"Sources/Intempt/Flags.swift|== .null ? nil :|== .string(\"never\") ? nil :|a JSON null value is ABSENT: off, killed and not-targeted answers must return the caller's default with the server's reason"
"Sources/Intempt/Flags.swift|case .cached, .unanswered, .error: return .unanswered|case .cached, .unanswered: return .unanswered|an SDK-local reason arriving on the wire must not be trusted as an answer"
"Sources/Intempt/Flags.swift|guard let raw, let reason = FlagReason(rawValue: raw) else { return .unanswered }|guard let raw, let reason = FlagReason(rawValue: raw) else { return .off }|an answer without a known reason must not read as a deliberate off state (EXP-SERVE-001, F6 #4)"
"Sources/Intempt/Flags.swift|if let declared, declared != rawValue { return false }|if let declared, declared == \"never\" { return false }|the server's declared valueType decides a typed read (F30 #3); a boolean served for a string flag is a TYPE_MISMATCH"
"Sources/Intempt/Flags.swift|if notFound { forget(id) }|if false { forget(id) }|a deleted flag (404) must not come back from the cache during a later outage"
"Sources/Intempt/Flags.swift|[.timeout, .network, .server, .parse]|[.timeout, .network, .server, .parse, .auth]|a misconfigured key (401/403) is not an outage; serving the last-known value hides it"
"Sources/Intempt/Flags.swift|guard stream.connected else { return nil }|guard true else { return nil }|an answer is served from memory only while the stream is connected; without it nothing reports a change or a kill"
"Sources/Intempt/Flags.swift|if entry.started < connectedAt|if entry.started < Date.distantPast|an answer from before the current connection may have missed a change while the stream was down"
"Sources/Intempt/Flags.swift|now.timeIntervalSince(entry.at) > Flags.freshTTL|now.timeIntervalSince(entry.at) > Flags.cacheTTL|the fresh window is 60 s (F15); the 24 h window is only for a failed read"
"Sources/Intempt/Flags.swift|cache = cache.filter|cache = cache.filter { _ in true }; _ = cache.filter|a flags_changed event must drop those keys at once, or a kill waits out the 60 s window"
"Sources/Intempt/Flags.swift|for read in pending.values where|for read in pending.values.prefix(0) where|a change landing while a read is in flight must keep that answer from being trusted as fresh"
"Sources/Intempt/Flags.swift|if let sessionId, !sessionId.isEmpty { body[\"sessionId\"] = sessionId }|_ = sessionId|the exposure carries the sessionId, as choose-api records it (F32, ffc4df6)"
"Sources/Intempt/Flags.swift|if let keys { body[\"keys\"] = keys }|body[\"keys\"] = keys ?? [String]()|allFlags OMITS keys; an empty list filters the answer to nothing and reads as \"no flags exist\""
"Sources/Intempt/FlagValues.swift|let variationId = unexposed.removeValue(forKey: key)|let variationId = unexposed[key]|the first read of a prefetched key exposes it ONCE per map; every read after it must send nothing"
"Sources/Intempt/FlagStream.swift|delay = min(delay * 2, FlagStream.backoffMax)|delay = delay * 2|the reconnect backoff doubles to a 60 s cap; uncapped, one long outage leaves the stream down for hours after it ends"
"Sources/Intempt/FlagTransport.swift|post(.flags(org: orgId, project: projectId, route: route), body, completion: completion)|post(.chooseApi(org: orgId, project: projectId), body, completion: completion)|flags are never read through choose-api (D20); once it stops serving them every read would be the default"
"Sources/Intempt/FlagTransport.swift|static let timeout: TimeInterval = 2|static let timeout: TimeInterval = 10|flag and choose reads time out after 2 s (S11, D19): they block a render"
"Sources/Intempt/FlagTransport.swift|case 429, 500...: return (.server, status)|case 500...: return (.server, status)|429 is the service's capacity, not a malformed request: the same mapping as every other SDK"
"Sources/Intempt/Choose.swift|if disableExposure { body[\"exposure\"] = false }|if false { body[\"exposure\"] = false }|choose(disableExposure:) must evaluate without recording or spending a once display"
"Sources/Intempt/Choose.swift|if let names { body[\"names\"] = names }|body[\"names\"] = names ?? [String]()|choose OMITS names when the caller gives none; an empty list filters the serving query to nothing"
"Sources/Intempt/Personalization.swift|return \"mobile\"|return \"tv\"|deviceClass must stay inside ExperienceDevice (all/desktop/mobile); \"tv\" is what this SDK actually sent from tvOS, and an unmappable value fails to bind the WHOLE request so every flag read silently returns the default"
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
        echo "  STALE    ${file##*/}: '$search' not present — the code moved and this mutant tests nothing"
        invalid=$((invalid+1))
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
