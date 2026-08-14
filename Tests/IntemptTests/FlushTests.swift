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

        XCTAssertEqual(
            session.requests.first?.url?.absoluteString,
            "https://api.intempt.com/v1/acme/projects/web/sources/42/track")
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

    /// A 401 is a misconfigured integration, not bad data. The events are still
    /// valid and must survive until the credentials are fixed.
    func testUnauthorizedKeepsEveryEvent() {
        seedEvents(db, count: 5)
        let flush = makeFlush(fallback: .status(401))

        XCTAssertEqual(flushSync(flush), 0)
        XCTAssertEqual(db.count(.events), 5)
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
        XCTAssertTrue(session.requests[1].url!.absoluteString.hasSuffix("/track"))
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

/// A batch the server will never accept must not block the queue forever, and
/// a batch rejected because the CREDENTIALS are wrong must never be dropped.
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

    /// Production has been observed returning a transient 400 to a payload it
    /// accepts moments later, so one rejection must not discard anything.
    func testASingleTerminalRejectionKeepsTheBatch() {
        seedEvents(db, count: 3)
        let flush = makeFlush(replies: [.serverError(400, "transient")])

        XCTAssertEqual(flushSync(flush), 0)
        XCTAssertEqual(db.count(.events), 3, "one 400 must not cost data")
    }

    func testRepeatedTerminalRejectionsEventuallyDropTheBatch() {
        seedEvents(db, count: 3)
        var now = Date(timeIntervalSince1970: 1_700_000_000)
        let flush = makeFlush(
            fallback: .serverError(400, "permanently malformed"), now: { now })
        let step = { now = now.addingTimeInterval(APIConstants.maxRetryBackoff + 1) }

        _ = flushSync(flush)
        XCTAssertEqual(db.count(.events), 3, "strike 1: kept")
        step()

        _ = flushSync(flush)
        XCTAssertEqual(db.count(.events), 3, "strike 2: kept")
        step()

        _ = flushSync(flush)
        XCTAssertEqual(
            db.count(.events), 0,
            "strike 3: dropped, or it blocks every event behind it forever")
    }

    /// The exemption that matters. A 401 is a fixable integration mistake and
    /// the events are perfectly valid — dropping them would be data loss caused
    /// by a typo in a key.
    func testUnauthorizedIsNeverDroppedNoMatterHowManyTimes() {
        seedEvents(db, count: 3)
        var now = Date(timeIntervalSince1970: 1_700_000_000)
        let flush = makeFlush(fallback: .status(401), now: { now })

        for attempt in 1...6 {
            _ = flushSync(flush)
            now = now.addingTimeInterval(APIConstants.maxRetryBackoff + 1)
            XCTAssertEqual(
                db.count(.events), 3,
                "attempt \(attempt): a credential failure must never cost data")
        }
        XCTAssertGreaterThanOrEqual(
            session.requestCount, 6, "each attempt must actually reach the server")
    }

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

    /// A success must clear the batch's strike entry.
    ///
    /// This is memory hygiene, not a behaviour change, and the test says so
    /// rather than pretending otherwise. Row ids are AUTOINCREMENT and never
    /// reused, so an entry left behind after its rows are deleted can never
    /// match another batch — it simply accumulates, one entry per failed batch,
    /// for the life of the process. An earlier version of this test used a
    /// second `Flush` instance and therefore proved nothing: mutation testing
    /// showed removing the clear left it green.
    func testSuccessClearsTheStrikeEntrySoItCannotAccumulate() {
        seedEvents(db, count: 2, prefix: "a")
        var now = Date(timeIntervalSince1970: 1_700_000_000)
        let flush = makeFlush(replies: [.serverError(400, "blip"), .ok()], now: { now })

        XCTAssertEqual(flushSync(flush), 0, "strike 1")
        XCTAssertEqual(flush.trackedStrikeCount, 1, "the failed batch is being tracked")

        now = now.addingTimeInterval(APIConstants.maxRetryBackoff + 1)
        XCTAssertEqual(flushSync(flush), 2, "then it succeeds")
        XCTAssertEqual(db.count(.events), 0)
        XCTAssertEqual(
            flush.trackedStrikeCount, 0,
            "the entry must be released; ids are never reused, so it could only accumulate")
    }

    /// A retryable failure is not a strike either — it clears the entry too.
    func testRetryableFailureDoesNotAccumulateStrikes() {
        seedEvents(db, count: 2)
        var now = Date(timeIntervalSince1970: 1_700_000_000)
        let flush = makeFlush(replies: [.serverError(400, "blip"), .status(503)], now: { now })

        _ = flushSync(flush)
        XCTAssertEqual(flush.trackedStrikeCount, 1)

        now = now.addingTimeInterval(APIConstants.maxRetryBackoff + 1)
        _ = flushSync(flush)
        XCTAssertEqual(
            flush.trackedStrikeCount, 0,
            "a 503 is not evidence the payload is bad, so the strike is dropped")
        XCTAssertEqual(db.count(.events), 2, "and nothing is deleted")
    }

    /// 413 means the batch is too large to ever be accepted as-is.
    func testPayloadTooLargeIsDroppedAfterTheLimit() {
        seedEvents(db, count: 4)
        var now = Date(timeIntervalSince1970: 1_700_000_000)
        let flush = makeFlush(fallback: .status(413), now: { now })

        for _ in 1...3 {
            _ = flushSync(flush)
            now = now.addingTimeInterval(APIConstants.maxRetryBackoff + 1)
        }
        XCTAssertEqual(db.count(.events), 0)
    }
}
