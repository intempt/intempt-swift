import XCTest

@testable import Intempt

/// The delivery path. Every test here exists because the old Obj-C SDK or
/// upstream mixpanel-swift got the case wrong, or because nothing proved it.
final class FlushTests: IntemptTestCase {

    private var db: IntemptDB!
    private var session: MockSession!
    private let recorded = Recorded()

    override func setUp() {
        super.setUp()
        db = makeDB()
        session = MockSession()
    }

    /// The resend wait is recorded and skipped, so a Retry-After of 60 s costs
    /// no wall clock; every failure reported to the listener is recorded too.
    private func makeFlush(
        replies: [MockSession.Reply] = [],
        fallback: MockSession.Reply = .ok()
    ) -> Flush {
        session = MockSession(replies: replies, fallback: fallback)
        let recorded = self.recorded
        let flush = Flush(
            db: db,
            network: Network(session: session),
            credentials: try! IntemptCredentials(apiKey: "pfx.secret"),
            orgId: "acme", projectId: "web", sourceId: "42",
            resendScheduler: { delay, work in
                recorded.append(delay: delay)
                work()
            })
        flush.onDeliveryFailure = { recorded.append(failure: $0) }
        return flush
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

    /// The claim must not outlive a failure. A kept batch releases it, or the
    /// rows are invisible to `read(flag: false)` forever after.
    func testClaimIsReleasedWhenTheSendFails() {
        seedEvents(db, count: 3)
        let flush = makeFlush(replies: [.offline()])

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

    /// F-34 still holds: a 500 is not a success and is not counted as sent. Since
    /// INT-7436 it is final, though: dropped and reported, never resent, because
    /// the server may already have processed the batch.
    func testServerErrorIsDroppedAndReportedNotResent() {
        seedEvents(db, count: 5)
        let flush = makeFlush(fallback: .status(500))

        XCTAssertEqual(flushSync(flush), 0, "a 500 is not a delivery")
        XCTAssertEqual(session.requestCount, 1, "a 500 is never resent")
        XCTAssertEqual(db.count(.events), 0)
        XCTAssertEqual(recorded.failures.map(\.kind), [.terminal])
        XCTAssertEqual(recorded.failures.first?.status, 500)
    }

    func testTransportFailureKeepsEveryEvent() {
        seedEvents(db, count: 5)
        let flush = makeFlush(fallback: .offline())

        XCTAssertEqual(flushSync(flush), 0)
        XCTAssertEqual(db.count(.events), 5)
    }

    /// A 401 used to be kept forever, so a wrong key grew the queue to its cap
    /// with nothing ever telling the integrator. It is now dropped and reported
    /// (INT-7436); the listener is where the bad key surfaces.
    func testUnauthorizedIsDroppedAndReported() {
        seedEvents(db, count: 5)
        let flush = makeFlush(fallback: .status(401))

        XCTAssertEqual(flushSync(flush), 0)
        XCTAssertEqual(session.requestCount, 1)
        XCTAssertEqual(db.count(.events), 0)
        XCTAssertEqual(recorded.failures.first?.status, 401)
    }

    /// The claim must be released on failure, or the rows are flagged forever
    /// and every later flush reads an empty un-flagged set.
    func testFailedBatchIsRetriedOnTheNextFlush() {
        seedEvents(db, count: 3)

        // Offline is the one failure that keeps a batch for the next flush.
        let flush = makeFlush(replies: [.offline(), .ok()])

        XCTAssertEqual(flushSync(flush), 0)
        XCTAssertEqual(db.count(.events), 3)

        XCTAssertEqual(flushSync(flush), 3, "the kept batch must be re-sent")
        XCTAssertEqual(db.count(.events), 0)
    }

    /// Partial drain: batch 1 succeeds, batch 2 never reaches the server.
    /// Exactly the first batch may be deleted. The old SDK's blanket delete
    /// destroyed both.
    func testPartialDrainDeletesOnlyTheAcknowledgedBatch() {
        seedEvents(db, count: 80)
        let flush = makeFlush(replies: [.ok(), .offline()])

        XCTAssertEqual(flushSync(flush, timeout: 10), 50)
        XCTAssertEqual(db.count(.events), 30, "only the acknowledged 50 may be deleted")

        // And the 30 survivors are the right ones.
        let flush2 = makeFlush()
        XCTAssertEqual(flushSync(flush2, timeout: 10), 30)
        XCTAssertEqual(trackedNames(in: session.bodies[0]).first, "e50")
    }

    // MARK: - Drain

    /// A failed batch must stop the drain rather than marching through every
    /// remaining batch against a server that is plainly down.
    func testDrainStopsAtTheFirstFailureInsteadOfHammering() {
        seedEvents(db, count: 500)
        let flush = makeFlush(fallback: .status(503))

        _ = flushSync(flush, timeout: 10)
        XCTAssertEqual(
            session.requestCount, 2, "the send and its one resend; one failed batch ends the drain")
        XCTAssertEqual(db.count(.events), 450, "only the failed batch is dropped")
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

    /// A withdrawal that never reached the server is kept for the next flush.
    func testAConsentThatNeverReachedTheServerIsKept() {
        db.insert(.consents, data: JSONHandler.encodeAPIData(["action": "reject"])!)
        let flush = makeFlush(fallback: .offline())
        _ = flushSync(flush)
        XCTAssertEqual(db.count(.consents), 1, "a withdrawal must never be lost to being offline")
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

// MARK: - Failure policy (INT-7436) and reporting (INT-7444)

/// Round-2 CONTRACT S1/S2: one resend for 503/429 only, every other answer
/// dropped, only a never-reached batch kept, and each final failure reported
/// once per batch.
extension FlushTests {

    func test503IsResentOnceAfterRetryAfterThenDelivered() {
        seedEvents(db, count: 3)
        let flush = makeFlush(replies: [.status(503, headers: ["Retry-After": "7"]), .ok()])

        XCTAssertEqual(flushSync(flush), 3)
        XCTAssertEqual(session.requestCount, 2)
        XCTAssertEqual(recorded.delays, [7], "the resend waits for the server's Retry-After")
        XCTAssertEqual(db.count(.events), 0)
        XCTAssertTrue(recorded.failures.isEmpty, "a batch delivered on its resend is not a failure")
    }

    /// The 503/429 resend waits up to 60 s holding the person's batch; an
    /// opt-out during that wait must stop it from leaving (security:F1).
    func testNoResendAfterOptOutDuringTheRetryAfterWait() {
        seedEvents(db, count: 2)
        var permitted = true
        session = MockSession(replies: [.status(503, headers: ["Retry-After": "5"]), .ok()])
        let flush = Flush(
            db: db,
            network: Network(session: session),
            credentials: try! IntemptCredentials(apiKey: "pfx.secret"),
            orgId: "acme", projectId: "web", sourceId: "42",
            resendScheduler: { _, work in
                permitted = false
                work()
            })
        flush.isPermitted = { permitted }

        XCTAssertEqual(flushSync(flush), 0)
        XCTAssertEqual(session.requestCount, 1, "the held batch is not resent after opt-out")
    }

    func test429IsResentOnceToo() {
        seedEvents(db, count: 1)
        let flush = makeFlush(replies: [.status(429), .ok()])

        XCTAssertEqual(flushSync(flush), 1)
        XCTAssertEqual(session.requestCount, 2)
        XCTAssertEqual(recorded.delays, [1], "no Retry-After waits the 1 s floor")
    }

    func testRetryAfterIsClampedToOneToSixtySeconds() {
        for (header, expected) in [("600", 60.0), ("0", 1.0), ("12", 12.0)] {
            seedEvents(db, count: 1)
            let before = recorded.delays.count
            let flush = makeFlush(replies: [.status(503, headers: ["Retry-After": header]), .ok()])
            _ = flushSync(flush)
            XCTAssertEqual(recorded.delays.dropFirst(before).first, expected, "Retry-After \(header)")
        }
    }

    /// The failure is reported once, on the final outcome: not for the first
    /// 503 and again for the resend.
    func testASecondRetryableAnswerDropsTheBatchAndReportsItOnce() {
        seedEvents(db, count: 3)
        let flush = makeFlush(fallback: .status(503, headers: ["Retry-After": "2"]))

        XCTAssertEqual(flushSync(flush), 0)
        XCTAssertEqual(session.requestCount, 2, "exactly one resend")
        XCTAssertEqual(db.count(.events), 0)
        XCTAssertEqual(
            recorded.failures,
            [
                DeliveryFailure(
                    kind: .terminal, status: 503, eventCount: 3,
                    eventIds: ["ev_e0", "ev_e1", "ev_e2"], retryAfter: 2)
            ])
        XCTAssertEqual(recorded.failures.first?.terminal, true)
    }

    func testEveryOtherAnsweredStatusIsDroppedOnTheFirstAnswer() {
        for status in [400, 401, 402, 403, 404, 408, 413, 422, 500, 502, 504] {
            seedEvents(db, count: 2)
            let failuresBefore = recorded.failures.count
            let flush = makeFlush(fallback: .status(status))

            XCTAssertEqual(flushSync(flush), 0)
            XCTAssertEqual(session.requestCount, 1, "\(status) is never resent")
            XCTAssertEqual(db.count(.events), 0, "\(status) drops the batch")
            let reported = recorded.failures.dropFirst(failuresBefore)
            XCTAssertEqual(reported.map(\.kind), [.terminal], "\(status) is reported once")
            XCTAssertEqual(reported.first?.status, status)
        }
        XCTAssertTrue(recorded.delays.isEmpty)
    }

    /// The server may already hold a batch whose answer timed out, so a resend
    /// risks a duplicate. It is dropped, not kept.
    func testATimeoutIsDroppedNotResentOrKept() {
        seedEvents(db, count: 2)
        let flush = makeFlush(fallback: .timedOut())

        XCTAssertEqual(flushSync(flush), 0)
        XCTAssertEqual(session.requestCount, 1)
        XCTAssertEqual(db.count(.events), 0)
        XCTAssertEqual(recorded.failures.map(\.kind), [.dropped])
        XCTAssertNil(recorded.failures.first?.status)
        XCTAssertEqual(recorded.failures.first?.terminal, true)
    }

    /// An offline device flushes every minute. The kept batch is reported once,
    /// not on every one of those flushes.
    func testANeverReachedBatchIsKeptAndReportedOnlyOnce() {
        seedEvents(db, count: 2)
        let flush = makeFlush(fallback: .offline())

        for _ in 0..<3 { _ = flushSync(flush) }

        XCTAssertEqual(session.requestCount, 3, "kept, and tried again on every flush")
        XCTAssertEqual(db.count(.events), 2)
        XCTAssertEqual(recorded.failures.map(\.kind), [.transport])
        XCTAssertEqual(recorded.failures.first?.terminal, false)
        XCTAssertEqual(recorded.failures.first?.eventCount, 2)
        XCTAssertTrue(recorded.delays.isEmpty, "never reached is not a resend")
    }

    func testTheTransportReportEntryIsReleasedOnceTheBatchIsDelivered() {
        seedEvents(db, count: 2)
        let flush = makeFlush(replies: [.offline(), .ok()])

        _ = flushSync(flush)
        XCTAssertEqual(flush.trackedTransportReportCount, 1)
        XCTAssertEqual(flushSync(flush), 2)
        XCTAssertEqual(flush.trackedTransportReportCount, 0)
    }

    /// Consents follow the same table as events. A rejected consent no longer
    /// blocks every consent behind it either: once dropped, the next one goes
    /// out on the next flush.
    func testARejectedConsentIsDroppedAndReported() {
        db.insert(.consents, data: JSONHandler.encodeAPIData(["action": "accept"])!)
        db.insert(.consents, data: JSONHandler.encodeAPIData(["action": "reject"])!)
        let flush = makeFlush(replies: [.serverError(400, "Field validUntil is out of range")])

        _ = flushSync(flush)
        XCTAssertEqual(db.count(.consents), 1, "the rejected record is dropped")
        XCTAssertEqual(
            recorded.failures,
            [DeliveryFailure(kind: .terminal, status: 400, eventCount: 1, eventIds: [], retryAfter: nil)])

        _ = flushSync(flush)
        XCTAssertEqual(db.count(.consents), 0, "the withdrawal behind it is then sent")
        XCTAssertEqual(session.bodies.last?["action"] as? String, "reject")
    }

    func testAConsentAnswered503TwiceIsDropped() {
        db.insert(.consents, data: JSONHandler.encodeAPIData(["action": "reject"])!)
        let flush = makeFlush(fallback: .status(503))

        _ = flushSync(flush)
        XCTAssertEqual(session.requestCount, 2, "one resend")
        XCTAssertEqual(db.count(.consents), 0)
        XCTAssertEqual(recorded.failures.map(\.kind), [.terminal])
    }

    /// R3 + R6: a consent is sent once like an event. A 500 is final for it even though the
    /// shared classifier calls a 500 retryable for push and feeds.
    func testAConsentAnsweredWithAServerErrorIsDroppedNotResent() {
        for status in [408, 500, 502, 504] {
            db.insert(.consents, data: JSONHandler.encodeAPIData(["action": "reject"])!)
            let failuresBefore = recorded.failures.count
            let flush = makeFlush(fallback: .status(status))

            _ = flushSync(flush)
            XCTAssertEqual(session.requestCount, 1, "\(status) is never resent")
            XCTAssertEqual(db.count(.consents), 0, "\(status) drops the consent")
            XCTAssertEqual(
                Array(recorded.failures.dropFirst(failuresBefore)),
                [DeliveryFailure(kind: .terminal, status: status, eventCount: 1, eventIds: [], retryAfter: nil)])
        }
        XCTAssertTrue(recorded.delays.isEmpty)
    }

    /// R2: a consent dropped without a request is still a failed consent, so the listener hears
    /// of it. Before, only a log line said so.
    func testAConsentDroppedUnsentIsReported() {
        seedConsent("accept", at: Date().addingTimeInterval(-QueueConstants.consentMaxAge - 1))
        db.insert(.consents, data: Data("not json".utf8))
        let flush = makeFlush(fallback: .ok())

        _ = flushSync(flush)
        XCTAssertEqual(session.requestCount, 0)
        XCTAssertEqual(db.count(.consents), 0)
        XCTAssertEqual(
            recorded.failures,
            Array(
                repeating: DeliveryFailure(kind: .dropped, status: nil, eventCount: 1, eventIds: [], retryAfter: nil),
                count: 2))
    }

    /// The instance surface forwards to the delivery path.
    func testTheInstanceListenerReceivesTheFailure() throws {
        let session = MockSession(replies: [], fallback: .status(400))
        let instance = try IntemptInstance.makeForTesting(
            store: defaults, databaseDirectory: tempDir, network: Network(session: session))
        let failures = Recorded()
        instance.onDeliveryFailure = { failures.append(failure: $0) }

        XCTAssertTrue(instance.track(eventTitle: "Checkout"), "track says only that it was queued")
        var sent: Int?
        instance.flush { sent = $0 }
        waitUntil("flush completes") { sent != nil }

        XCTAssertEqual(failures.failures.map(\.kind), [.terminal])
        XCTAssertEqual(failures.failures.first?.status, 400)
        XCTAssertEqual(failures.failures.first?.eventCount, 1)
    }

    // MARK: - Consent age (android CONSENT_MAX_AGE_DAYS)

    private func seedConsent(_ action: String, at time: Date = Date()) {
        db.insert(.consents, data: JSONHandler.encodeAPIData(["action": action])!, at: time)
    }

    private func consentRequests() -> [[String: Any]] {
        zip(session.requests, session.bodies)
            .filter { $0.0.url!.absoluteString.hasSuffix("/consents/data") }
            .map(\.1)
    }

    /// A consent kept while offline must not park the queue head forever:
    /// past the age limit it is dropped without being sent.
    func testAConsentOlderThanTheAgeLimitIsDroppedWithoutBeingSent() {
        let now = Date()
        seedConsent("accept", at: now.addingTimeInterval(-QueueConstants.consentMaxAge - 1))
        seedConsent("reject", at: now)
        let flush = makeFlush(fallback: .ok())

        _ = flushSync(flush)
        XCTAssertEqual(db.count(.consents), 0)
        XCTAssertEqual(
            consentRequests().map { $0["action"] as? String }, ["reject"],
            "the expired head is dropped and the one behind it is sent")
    }

    func testAConsentJustInsideTheAgeLimitIsStillSent() {
        seedConsent("accept", at: Date().addingTimeInterval(-QueueConstants.consentMaxAge + 60))
        let flush = makeFlush(fallback: .ok())

        _ = flushSync(flush)
        XCTAssertEqual(consentRequests().count, 1)
        XCTAssertEqual(db.count(.consents), 0)
    }

    func testTheConsentAgeLimitIsThirtyDays() {
        XCTAssertEqual(QueueConstants.consentMaxAge, 30 * 24 * 60 * 60)
    }
}

/// Written from the flush queue, read from the test thread.
final class Recorded {
    private let lock = NSLock()
    private var _delays: [TimeInterval] = []
    private var _failures: [DeliveryFailure] = []

    var delays: [TimeInterval] {
        lock.lock()
        defer { lock.unlock() }
        return _delays
    }

    var failures: [DeliveryFailure] {
        lock.lock()
        defer { lock.unlock() }
        return _failures
    }

    func append(delay: TimeInterval) {
        lock.lock()
        _delays.append(delay)
        lock.unlock()
    }

    func append(failure: DeliveryFailure) {
        lock.lock()
        _failures.append(failure)
        lock.unlock()
    }
}
