import XCTest

@testable import Intempt

/// The delivery path. Every test here exists because the old Obj-C SDK or
/// upstream mixpanel-swift got the case wrong, or because nothing proved it.
final class FlushTests: IntemptTestCase {

    private var db: IntemptDB!
    private var session: MockSession!

    override func setUp() {
        super.setUp()
        db = makeDB()
        session = MockSession()
    }

    private func makeFlush(
        replies: [MockSession.Reply] = [],
        fallback: MockSession.Reply = .ok(),
        now: @escaping () -> Date = Date.init
    ) -> Flush {
        session = MockSession(replies: replies, fallback: fallback)
        return Flush(
            db: db,
            network: Network(session: session),
            credentials: try! IntemptCredentials(apiKey: "pfx.secret"),
            orgId: "acme", projectId: "web", sourceId: "42",
            policy: RetryPolicy(now: now, jitter: { 0 }))
    }

    /// Runs a flush and returns the number of events it reported sending.
    private func flushSync(_ flush: Flush, timeout: TimeInterval = 3) -> Int {
        var sent: Int?
        flush.flushNow { sent = $0 }
        waitUntil("flush completes", timeout: timeout) { sent != nil }
        return sent ?? -1
    }

    // MARK: - Claim / release

    /// A batch must be CLAIMED before it goes on the wire, not after it comes
    /// back. The claim is the only thing stopping a second flush — a timer tick,
    /// a foreground transition, an explicit flush() — from reading the same rows
    /// and sending them again.
    ///
    /// Mutation testing found this unguarded: flipping the claim to `false`
    /// passed every other test in this file, because nothing observed the
    /// database while a request was in flight.
    func testBatchIsClaimedBeforeTheRequestIsSent() {
        seedEvents(db, count: 3)
        let flush = makeFlush()
        session.deferCompletions = true

        flush.flushNow { _ in }
        waitUntil("request issued") { self.session.requestCount == 1 }

        // The rows are on the wire. Nothing else may pick them up.
        XCTAssertTrue(
            db.read(.events, limit: 100, flag: false).isEmpty,
            "rows in flight must be claimed, or a concurrent flush sends them twice")
        XCTAssertEqual(
            db.read(.events, limit: 100, flag: true).count, 3,
            "and they must still be present, claimed, until the server acknowledges")

        session.releaseDeferred()
        waitUntil("queue drains") { self.db.count(.events) == 0 }
    }

    /// The claim must not outlive a failure. A retryable outcome releases it, or
    /// the rows are invisible to `read(flag: false)` forever after.
    func testClaimIsReleasedWhenTheSendFails() {
        seedEvents(db, count: 3)
        let flush = makeFlush(replies: [.status(503)])

        _ = flushSync(flush)

        XCTAssertEqual(
            db.read(.events, limit: 100, flag: false).count, 3,
            "a failed batch must be released, not stranded claimed")
    }

    // MARK: - Happy path

    func testEmptyQueueSendsNothing() {
        let flush = makeFlush()
        XCTAssertEqual(flushSync(flush), 0)
        XCTAssertEqual(session.requestCount, 0, "an empty queue must not produce a request")
    }

    func testSingleBatchIsSentAndDeleted() {
        seedEvents(db, count: 3)
        let flush = makeFlush()

        XCTAssertEqual(flushSync(flush), 3)
        XCTAssertEqual(session.requestCount, 1)
        XCTAssertEqual(db.count(.events), 0, "acknowledged events must be deleted")
    }

    func testBatchBodyIsTheTrackEnvelope() {
        seedEvents(db, count: 2)
        let flush = makeFlush()
        _ = flushSync(flush)

        let body = session.bodies.first
        XCTAssertNotNil(body)
        XCTAssertNotNil(body?["track"], "body must be wrapped as {\"track\":[…]}")
        XCTAssertEqual(trackedNames(in: body!), ["e0", "e1"])
    }

    func testRequestGoesToTheSourceScopedTrackEndpoint() {
        seedEvents(db, count: 1)
        let flush = makeFlush()
        _ = flushSync(flush)

        // `?ip=1` states that the platform may derive country/region/city from the address the
        // request already arrives on. The device never reads or sends its own address.
        XCTAssertEqual(
            session.requests.first?.url?.absoluteString,
            "https://api.intempt.com/v1/acme/projects/web/sources/42/track?ip=1")
    }

    // MARK: - Batching

    /// A queue larger than one batch must drain across multiple requests in one
    /// flush, oldest first, with no gaps and no duplicates.
    func testLargeQueueDrainsAcrossMultipleBatches() {
        let expected = seedEvents(db, count: 120)
        let flush = makeFlush()

        XCTAssertEqual(flushSync(flush, timeout: 10), 120)
        XCTAssertEqual(session.requestCount, 3, "120 events at 50/batch = 3 requests")
        XCTAssertEqual(db.count(.events), 0)

        let sentNames = session.bodies.flatMap { trackedNames(in: $0) }
        XCTAssertEqual(sentNames, expected, "order preserved, nothing dropped or duplicated")
    }

    func testBatchSizeIsCapped() {
        seedEvents(db, count: 60)
        let flush = makeFlush()
        _ = flushSync(flush, timeout: 10)

        XCTAssertEqual(trackedNames(in: session.bodies[0]).count, APIConstants.maxBatchSize)
        XCTAssertEqual(trackedNames(in: session.bodies[1]).count, 10)
    }

    // MARK: - Failure handling (the destructive-delete regressions)

    /// F-34, restated at the flush level: a 500 must not delete anything.
    func testServerErrorKeepsEveryEvent() {
        seedEvents(db, count: 5)
        let flush = makeFlush(fallback: .status(500))

        XCTAssertEqual(flushSync(flush), 0)
        XCTAssertEqual(db.count(.events), 5, "a 500 must never destroy the queue")
    }

    func testTransportFailureKeepsEveryEvent() {
        seedEvents(db, count: 5)
        let flush = makeFlush(fallback: .offline())

        XCTAssertEqual(flushSync(flush), 0)
        XCTAssertEqual(db.count(.events), 5)
    }

    /// R-retry (D9, INT-7438): the backend never accepts an event it answered
    /// 401 for, so the batch is dropped on the first answer, as on android.
    func testUnauthorizedDropsTheBatchOnTheFirstAnswer() {
        seedEvents(db, count: 5)
        let flush = makeFlush(fallback: .status(401))

        XCTAssertEqual(flushSync(flush), 0, "a dropped batch is not reported as sent")
        XCTAssertEqual(db.count(.events), 0)
        XCTAssertEqual(session.requestCount, 1)
        XCTAssertEqual(flush.consecutiveFailures, 0, "a drop does not open a backoff window")
    }

    /// The claim must be released on failure, or the rows are flagged forever
    /// and every later flush reads an empty un-flagged set.
    func testFailedBatchIsRetriedOnTheNextFlush() {
        seedEvents(db, count: 3)

        // First flush fails, second succeeds. Same clock so no backoff gate:
        // one failure does not open a window.
        let flush = makeFlush(replies: [.status(503), .ok()])

        XCTAssertEqual(flushSync(flush), 0)
        XCTAssertEqual(db.count(.events), 3)

        XCTAssertEqual(flushSync(flush), 3, "the kept batch must be re-sent")
        XCTAssertEqual(db.count(.events), 0)
    }

    /// Partial drain: batch 1 succeeds, batch 2 fails. Exactly the first batch
    /// may be deleted. The old SDK's blanket delete destroyed both.
    func testPartialDrainDeletesOnlyTheAcknowledgedBatch() {
        seedEvents(db, count: 80)
        let flush = makeFlush(replies: [.ok(), .status(503)])

        XCTAssertEqual(flushSync(flush, timeout: 10), 50)
        XCTAssertEqual(db.count(.events), 30, "only the acknowledged 50 may be deleted")

        // And the 30 survivors are the right ones.
        let flush2 = makeFlush()
        XCTAssertEqual(flushSync(flush2, timeout: 10), 30)
        XCTAssertEqual(trackedNames(in: session.bodies[0]).first, "e50")
    }

    // MARK: - Backoff gate

    func testBackoffWindowSuppressesTheNextFlush() {
        seedEvents(db, count: 3)
        var clock = Date(timeIntervalSince1970: 1_700_000_000)
        let flush = makeFlush(fallback: .status(503), now: { clock })

        _ = flushSync(flush)  // failure 1 — no window yet
        _ = flushSync(flush)  // failure 2 — window opens
        let countAfterTwo = session.requestCount

        _ = flushSync(flush)
        XCTAssertEqual(
            session.requestCount, countAfterTwo,
            "inside the backoff window no request may be made")

        clock = clock.addingTimeInterval(APIConstants.maxRetryBackoff + 1)
        _ = flushSync(flush)
        XCTAssertGreaterThan(session.requestCount, countAfterTwo, "window expired, retry allowed")
    }

    /// Retryable failures must stop the drain rather than marching through
    /// every remaining batch against a server that is plainly down.
    func testDrainStopsAtTheFirstFailureInsteadOfHammering() {
        seedEvents(db, count: 500)
        let flush = makeFlush(fallback: .status(503))

        _ = flushSync(flush, timeout: 10)
        XCTAssertEqual(session.requestCount, 1, "one failure ends the drain; 10 batches is abuse")
    }

    // MARK: - Concurrency

    /// Two overlapping flushes must coalesce into one drain.
    ///
    /// 120 events, not 40, and that matters: with a single batch's worth the
    /// claim flag alone makes the second flush find nothing, so the assertion
    /// holds whether coalescing works or not. Mutation testing caught exactly
    /// that — removing the `inFlight` guard left this test green. With three
    /// batches queued, an uncoalesced second flush claims batch 2 in parallel
    /// and the request count betrays it.
    func testConcurrentFlushesDoNotDoubleSend() {
        seedEvents(db, count: 120)
        let flush = makeFlush()
        session.deferCompletions = true

        var done = 0
        flush.flushNow { _ in done += 1 }
        flush.flushNow { _ in done += 1 }

        waitUntil("first request issued") { self.session.requestCount >= 1 }
        XCTAssertEqual(
            session.requestCount, 1,
            "the second flush must coalesce, not issue a parallel request")

        session.deferCompletions = false
        session.releaseDeferred()
        waitUntil("both completions fire") { done == 2 }

        let sentNames = session.bodies.flatMap { trackedNames(in: $0) }
        XCTAssertEqual(Set(sentNames).count, sentNames.count, "no event sent twice")
    }

    /// A crash mid-flight leaves rows claimed. On the next launch they must be
    /// released, or they are stranded in the store forever.
    func testStaleClaimsAreReleasedOnStartup() {
        seedEvents(db, count: 3)
        let ids = db.read(.events, limit: 10, flag: false).map(\.id)
        db.setFlag(.events, ids: ids, to: true)
        XCTAssertTrue(db.read(.events, limit: 10, flag: false).isEmpty, "all rows claimed")

        // Constructing Flush models process start.
        let flush = makeFlush()
        XCTAssertEqual(flushSync(flush), 3, "stale claims must be recovered, not stranded")
    }

    // MARK: - Poison pill

    /// An undecodable row must be dropped, not retried forever. Upstream keeps
    /// it at the head of the queue and every batch fails on it — one corrupt
    /// row blocks all delivery permanently.
    func testUndecodableRowIsDroppedInsteadOfBlockingTheQueue() {
        db.insert(.events, data: Data("this is not json".utf8))
        seedEvents(db, count: 2)

        let flush = makeFlush()
        XCTAssertEqual(flushSync(flush), 2, "the two good events must still be delivered")
        XCTAssertEqual(db.count(.events), 0, "the poison row must be gone, not stranded")
        XCTAssertEqual(trackedNames(in: session.bodies[0]), ["e0", "e1"])
    }

    // MARK: - Consent

    /// Consent goes to its own endpoint, unbatched, and is flushed before
    /// events: a withdrawal reaching the server matters more than analytics.
    func testConsentIsSentToItsOwnEndpointBeforeEvents() {
        db.insert(.consents, data: JSONHandler.encodeAPIData(["action": "reject"])!)
        seedEvents(db, count: 1)

        let flush = makeFlush()
        _ = flushSync(flush)

        XCTAssertEqual(session.requestCount, 2)
        XCTAssertTrue(
            session.requests[0].url!.absoluteString.hasSuffix("/consents/data"),
            "consent must be sent first, to its own endpoint")
        XCTAssertTrue(session.requests[1].url!.absoluteString.contains("/track"))
        XCTAssertEqual(db.count(.consents), 0)
    }

    func testConsentBodyIsNotWrappedInTheTrackEnvelope() {
        db.insert(.consents, data: JSONHandler.encodeAPIData(["action": "accept"])!)
        let flush = makeFlush()
        _ = flushSync(flush)

        let body = session.bodies[0]
        XCTAssertNil(body["track"], "consent is not a track envelope")
        XCTAssertEqual(body["action"] as? String, "accept")
    }

    func testFailedConsentIsKept() {
        db.insert(.consents, data: JSONHandler.encodeAPIData(["action": "reject"])!)
        let flush = makeFlush(fallback: .status(503))
        _ = flushSync(flush)
        XCTAssertEqual(db.count(.consents), 1, "a withdrawal must never be lost")
    }

    // MARK: - Timer

    func testTimerFlushesWithoutAnExplicitCall() {
        seedEvents(db, count: 2)
        let flush = makeFlush()
        flush.flushInterval = 0.05
        flush.startTimer()

        waitUntil("timer drives a flush") { self.session.requestCount >= 1 }
        XCTAssertEqual(db.count(.events), 0)
        flush.stopTimer()
    }

    func testZeroIntervalDisablesTheTimer() {
        seedEvents(db, count: 2)
        let flush = makeFlush()
        flush.flushInterval = 0
        flush.startTimer()

        // Give a real timer every chance to fire.
        let deadline = Date().addingTimeInterval(0.4)
        while Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        XCTAssertEqual(session.requestCount, 0, "interval 0 means no automatic flush")
        XCTAssertEqual(db.count(.events), 2)
    }

    func testStopTimerHalts() {
        seedEvents(db, count: 2)
        let flush = makeFlush()
        flush.flushInterval = 0.05
        flush.startTimer()
        flush.stopTimer()

        let deadline = Date().addingTimeInterval(0.3)
        while Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        XCTAssertEqual(session.requestCount, 0)
    }

    /// Setting the interval while running must re-arm, not leave the old timer.
    func testChangingIntervalRearmsTheTimer() {
        seedEvents(db, count: 2)
        let flush = makeFlush()
        flush.flushInterval = 600
        flush.startTimer()
        flush.flushInterval = 0.05

        waitUntil("re-armed timer fires") { self.session.requestCount >= 1 }
        flush.stopTimer()
    }
}

// MARK: - Terminal rejection policy

/// Android parity (Beso, 2026-11-11; R-retry, D9/INT-7438): a non-retryable
/// answer drops a batch at once and a consent after three in a row; 403, 404,
/// 408, 429 and 5xx keep both.
///
/// Every test here drives a controllable clock. The backoff gate opens after
/// two consecutive failures, so with a real clock the third flush is suppressed
/// and never reaches the server — the strike counter would never advance and
/// these tests would pass for the wrong reason.
extension FlushTests {

    /// Runs `count` flushes, stepping past the backoff window between each.
    private func flushRepeatedly(
        _ flush: Flush, _ count: Int, clock: () -> Void
    ) {
        for _ in 0..<count {
            _ = flushSync(flush)
            clock()
        }
    }

    /// Android's `HttpStatusPolicy.shouldDrop`: every status at 300 or above
    /// that is not retryable drops the batch on the first answer.
    func testNonRetryableStatusesDropTheBatchOnTheFirstAnswer() {
        for status in [300, 301, 400, 401, 402, 405, 409, 413, 422, 451, 499, 600, 999] {
            db.deleteAll(.events)
            seedEvents(db, count: 3)
            let flush = makeFlush(replies: [.status(status)])

            _ = flushSync(flush)
            XCTAssertEqual(db.count(.events), 0, "\(status) must drop on the first answer")
        }
    }

    /// Android's `HttpStatusPolicy.isRetryable`: 403, 404, 408, 429 and every
    /// 5xx keep the batch, 501 and 505 included.
    func testRetryableStatusesKeepTheBatch() {
        for status in [403, 404, 408, 429, 500, 501, 502, 503, 504, 505, 599] {
            db.deleteAll(.events)
            seedEvents(db, count: 3)
            let flush = makeFlush(replies: [.status(status)])

            XCTAssertEqual(flushSync(flush), 0)
            XCTAssertEqual(db.count(.events), 3, "\(status) must keep the batch")
            XCTAssertEqual(flush.consecutiveFailures, 1, "\(status) is a failure for the backoff")
        }
    }

    /// A dropped batch must not block the one behind it.
    func testTheBatchBehindADroppedOneIsSentInTheSamePass() {
        seedEvents(db, count: APIConstants.maxBatchSize + 10)
        let flush = makeFlush(replies: [.serverError(400, "malformed")], fallback: .ok())

        XCTAssertEqual(flushSync(flush), 10, "the second batch goes out in the same pass")
        XCTAssertEqual(db.count(.events), 0)
        XCTAssertEqual(session.requestCount, 2)
    }

    func testABatchDropIsLoggedAtErrorWithTheServersMessage() {
        let sink = CollectingLogger()
        IntemptLogger.shared.addLogging(sink)
        IntemptLogger.shared.enable(.error)
        defer {
            IntemptLogger.shared.removeAllLogging()
            IntemptLogger.shared.disableAllLevels()
        }
        seedEvents(db, count: 2)
        let flush = makeFlush(replies: [.serverError(422, "Invalid feed id: nonexistent")])

        _ = flushSync(flush)
        XCTAssertTrue(
            sink.messages.contains { $0.contains("dropping 2 event(s)") && $0.contains("Invalid feed id") },
            "the drop names the server's reason, at error level: \(sink.messages)")
    }

    /// 403 stays retryable (INT-5897, pending K1): a gateway that answers 403
    /// during a deploy must not delete every batch.
    func testForbiddenIsAlsoNeverDropped() {
        seedEvents(db, count: 2)
        var now = Date(timeIntervalSince1970: 1_700_000_000)
        let flush = makeFlush(fallback: .status(403), now: { now })

        for _ in 1...5 {
            _ = flushSync(flush)
            now = now.addingTimeInterval(APIConstants.maxRetryBackoff + 1)
        }
        XCTAssertEqual(db.count(.events), 2)
        XCTAssertGreaterThanOrEqual(session.requestCount, 5)
    }

    // MARK: - Consent rejections (INT-5956)

    private func seedConsent(_ action: String, at time: Date = Date()) {
        db.insert(.consents, data: JSONHandler.encodeAPIData(["action": action])!, at: time)
    }

    private func consentRequests() -> [[String: Any]] {
        zip(session.requests, session.bodies)
            .filter { $0.0.url!.absoluteString.hasSuffix("/consents/data") }
            .map(\.1)
    }

    /// A consent the server rejects as malformed used to be resent on every
    /// flush and every launch, forever: the batch strike-drop never applied to
    /// consents. The duration-as-validUntil defect produced exactly such a
    /// record for every consent the SDK sent.
    func testRepeatedConsentRejectionsEventuallyDropTheRecord() {
        seedConsent("accept")
        var now = Date(timeIntervalSince1970: 1_700_000_000)
        let flush = makeFlush(
            fallback: .serverError(400, "Field validUntil is out of range"), now: { now })
        let step = { now = now.addingTimeInterval(APIConstants.maxRetryBackoff + 1) }

        _ = flushSync(flush)
        XCTAssertEqual(db.count(.consents), 1, "strike 1: kept")
        step()

        _ = flushSync(flush)
        XCTAssertEqual(db.count(.consents), 1, "strike 2: kept")
        step()

        _ = flushSync(flush)
        XCTAssertEqual(db.count(.consents), 0, "strike 3: dropped, or it is resent forever")
        XCTAssertEqual(flush.trackedConsentStrikeCount, 0, "the dropped record's entry is released")
        XCTAssertEqual(consentRequests().count, 3)
    }

    func testTheDropIsLoggedAtErrorWithTheServersMessage() {
        let sink = CollectingLogger()
        IntemptLogger.shared.addLogging(sink)
        IntemptLogger.shared.enable(.error)
        defer {
            IntemptLogger.shared.removeAllLogging()
            IntemptLogger.shared.disableAllLevels()
        }
        seedConsent("accept")
        var now = Date(timeIntervalSince1970: 1_700_000_000)
        let flush = makeFlush(
            fallback: .serverError(422, "Field validUntil is out of range"), now: { now })

        for _ in 1...3 {
            _ = flushSync(flush)
            now = now.addingTimeInterval(APIConstants.maxRetryBackoff + 1)
        }

        XCTAssertEqual(db.count(.consents), 0)
        XCTAssertTrue(
            sink.messages.contains { $0.contains("dropping consent record") && $0.contains("validUntil") },
            "the drop names the server's reason, at error level: \(sink.messages)")
    }

    /// Consents drain oldest first, one at a time, and a terminal failure ends
    /// the pass. A poisoned head therefore blocked every consent behind it —
    /// a later withdrawal included — until it was dropped.
    func testAConsentBehindARejectedOneIsSentOnceTheHeadIsDropped() {
        seedConsent("accept")
        seedConsent("reject")
        var now = Date(timeIntervalSince1970: 1_700_000_000)
        let flush = makeFlush(
            replies: [
                .serverError(400, "malformed"), .serverError(400, "malformed"),
                .serverError(400, "malformed"),
            ],
            fallback: .ok(), now: { now })

        for _ in 1...3 {
            _ = flushSync(flush)
            now = now.addingTimeInterval(APIConstants.maxRetryBackoff + 1)
        }
        XCTAssertEqual(db.count(.consents), 1, "only the rejected head is dropped")
        XCTAssertEqual(
            consentRequests().map { $0["action"] as? String }, ["accept", "accept", "accept"],
            "nothing behind the head is sent while it is still being retried")

        _ = flushSync(flush)
        XCTAssertEqual(db.count(.consents), 0, "the withdrawal behind it now reaches the server")
        XCTAssertEqual(consentRequests().last?["action"] as? String, "reject")
    }

    /// Android's retryable set keeps the record and is no strike. The age
    /// limit, not the strike count, bounds these.
    func testAConsentIsNeverDroppedForARetryableStatus() {
        for status in [403, 404, 408, 429, 500, 501, 503, 505] {
            db.deleteAll(.consents)
            seedConsent("reject")
            var now = Date(timeIntervalSince1970: 1_700_000_000)
            let flush = makeFlush(fallback: .status(status), now: { now })

            for attempt in 1...5 {
                _ = flushSync(flush)
                now = now.addingTimeInterval(APIConstants.maxRetryBackoff + 1)
                XCTAssertEqual(
                    db.count(.consents), 1,
                    "\(status), attempt \(attempt): a withdrawal must never be lost")
            }
            XCTAssertGreaterThanOrEqual(
                consentRequests().count, 5, "\(status): each attempt must reach the server")
            XCTAssertEqual(flush.trackedConsentStrikeCount, 0, "\(status) is not a strike")
        }
    }

    /// Strikes are consecutive: a success or a retryable failure in between
    /// starts the count again, as it does for a batch.
    func testAnInterruptedRunOfRejectionsStartsTheCountAgain() {
        seedConsent("reject")
        var now = Date(timeIntervalSince1970: 1_700_000_000)
        let flush = makeFlush(
            replies: [
                .serverError(400, "blip"), .serverError(400, "blip"), .status(503),
                .serverError(400, "blip"), .serverError(400, "blip"),
            ],
            fallback: .ok(), now: { now })

        for _ in 1...5 {
            _ = flushSync(flush)
            now = now.addingTimeInterval(APIConstants.maxRetryBackoff + 1)
            XCTAssertEqual(db.count(.consents), 1, "never three rejections in a row, so kept")
        }
        XCTAssertEqual(flush.trackedConsentStrikeCount, 1)

        _ = flushSync(flush)
        XCTAssertEqual(db.count(.consents), 0, "then accepted and deleted")
        XCTAssertEqual(flush.trackedConsentStrikeCount, 0)
    }

    /// A retryable reply in between breaks the run too: it is no rejection of
    /// the record, so the count starts again after it.
    func testARetryableReplyStartsTheCountAgain() {
        for status in [403, 404] {
            db.deleteAll(.consents)
            seedConsent("accept")
            var now = Date(timeIntervalSince1970: 1_700_000_000)
            let flush = makeFlush(
                replies: [
                    .serverError(400, "blip"), .serverError(400, "blip"), .status(status),
                    .serverError(400, "blip"), .serverError(400, "blip"),
                ],
                fallback: .ok(), now: { now })

            for attempt in 1...5 {
                _ = flushSync(flush)
                now = now.addingTimeInterval(APIConstants.maxRetryBackoff + 1)
                XCTAssertEqual(
                    db.count(.consents), 1,
                    "\(status), attempt \(attempt): never three rejections in a row, so kept")
            }
            XCTAssertEqual(flush.trackedConsentStrikeCount, 1, "\(status): two strikes since the break")

            _ = flushSync(flush)
            XCTAssertEqual(db.count(.consents), 0, "\(status): then accepted and deleted")
        }
    }

    /// R-retry: 401 and 402 are rejections of a consent like any other
    /// non-retryable status, and mixed ones still count as one run.
    func testUnauthorizedAndPaymentRequiredAreConsentRejections() {
        seedConsent("reject")
        var now = Date(timeIntervalSince1970: 1_700_000_000)
        let flush = makeFlush(
            replies: [.status(401), .status(402), .serverError(400, "malformed")],
            fallback: .ok(), now: { now })

        for _ in 1...2 {
            _ = flushSync(flush)
            now = now.addingTimeInterval(APIConstants.maxRetryBackoff + 1)
            XCTAssertEqual(db.count(.consents), 1, "kept until the third rejection")
        }
        _ = flushSync(flush)
        XCTAssertEqual(db.count(.consents), 0, "the third rejection in a row drops it")
        XCTAssertEqual(
            flush.consecutiveFailures, 0,
            "the server is answering, so the consents behind it are not backed off")
    }

    // MARK: - Consent age (android CONSENT_MAX_AGE_DAYS)

    /// A consent kept by retryable answers must not park the queue head
    /// forever: past the age limit it is dropped without being sent.
    func testAConsentOlderThanTheAgeLimitIsDroppedWithoutBeingSent() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        seedConsent("accept", at: now.addingTimeInterval(-QueueConstants.consentMaxAge - 1))
        seedConsent("reject", at: now)
        let flush = makeFlush(fallback: .ok(), now: { now })

        _ = flushSync(flush)
        XCTAssertEqual(db.count(.consents), 0)
        XCTAssertEqual(
            consentRequests().map { $0["action"] as? String }, ["reject"],
            "the expired head is dropped and the one behind it is sent")
    }

    func testAConsentJustInsideTheAgeLimitIsStillSent() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        seedConsent("accept", at: now.addingTimeInterval(-QueueConstants.consentMaxAge + 60))
        let flush = makeFlush(fallback: .ok(), now: { now })

        _ = flushSync(flush)
        XCTAssertEqual(consentRequests().count, 1)
        XCTAssertEqual(db.count(.consents), 0)
    }

    func testTheConsentAgeLimitIsThirtyDays() {
        XCTAssertEqual(QueueConstants.consentMaxAge, 30 * 24 * 60 * 60)
    }
}
