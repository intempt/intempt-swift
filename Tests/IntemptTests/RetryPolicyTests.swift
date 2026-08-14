import XCTest

@testable import Intempt

final class RetryPolicyTests: XCTestCase {

    private var now = Date(timeIntervalSince1970: 1_700_000_000)
    private func policy(jitter: TimeInterval = 0) -> RetryPolicy {
        RetryPolicy(now: { self.now }, jitter: { jitter })
    }

    // MARK: Gate

    func testRequestsAllowedInitially() {
        XCTAssertFalse(policy().requestNotAllowed)
    }

    /// The old Obj-C SDK had no gate: it retried every timer tick forever,
    /// with no backoff, for the entire duration of an outage.
    func testSecondFailureOpensABackoffWindow() {
        var p = policy()
        p.recordFailure()
        XCTAssertFalse(p.requestNotAllowed, "one failure must not gate")

        p.recordFailure()
        XCTAssertTrue(p.requestNotAllowed, "backoff engages at the second failure")
    }

    func testWindowClosesWhenTimePasses() {
        var p = policy()
        p.recordFailure()
        p.recordFailure()
        XCTAssertTrue(p.requestNotAllowed)

        now = now.addingTimeInterval(APIConstants.maxRetryBackoff + 1)
        XCTAssertFalse(p.requestNotAllowed)
    }

    func testSuccessClearsTheWindowAndTheCounter() {
        var p = policy()
        p.recordFailure()
        p.recordFailure()
        XCTAssertTrue(p.requestNotAllowed)

        p.recordSuccess()
        XCTAssertFalse(p.requestNotAllowed)
        XCTAssertEqual(p.consecutiveFailures, 0)
    }

    // MARK: Backoff curve

    func testExponentialCurveIsClamped() {
        let p = policy(jitter: 0)
        XCTAssertEqual(p.backoff(for: 1), 60)   // 2^0 * 60
        XCTAssertEqual(p.backoff(for: 2), 120)  // 2^1 * 60
        XCTAssertEqual(p.backoff(for: 3), 240)
        XCTAssertEqual(p.backoff(for: 4), 480)
        XCTAssertEqual(p.backoff(for: 5), 600, "clamped at the ceiling")
        XCTAssertEqual(p.backoff(for: 20), 600, "stays clamped")
    }

    func testJitterIsAdded() {
        let p = policy(jitter: 17)
        XCTAssertEqual(p.backoff(for: 1), 77)
    }

    func testBackoffNeverBelowFloor() {
        let p = policy(jitter: 0)
        XCTAssertGreaterThanOrEqual(p.backoff(for: 1), APIConstants.minRetryBackoff)
    }

    // MARK: Retry-After

    /// Honoured even on the FIRST failure, before backoff engages — a 429
    /// with Retry-After must be respected immediately.
    func testRetryAfterRespectedOnFirstFailure() {
        var p = policy()
        p.recordFailure(retryAfter: 45)
        XCTAssertTrue(p.requestNotAllowed)

        now = now.addingTimeInterval(44)
        XCTAssertTrue(p.requestNotAllowed, "still inside the server's window")

        now = now.addingTimeInterval(2)
        XCTAssertFalse(p.requestNotAllowed)
    }

    /// When the server asks for longer than our curve, the server wins.
    func testRetryAfterIsAFloorNotACeiling() {
        var p = policy(jitter: 0)
        p.recordFailure()
        p.recordFailure(retryAfter: 500)  // curve would be 120
        now = now.addingTimeInterval(121)
        XCTAssertTrue(p.requestNotAllowed, "server's 500s must win over our 120s")

        now = now.addingTimeInterval(400)
        XCTAssertFalse(p.requestNotAllowed)
    }

    func testCurveWinsWhenLongerThanRetryAfter() {
        var p = policy(jitter: 0)
        p.recordFailure()
        p.recordFailure(retryAfter: 5)  // curve is 120
        now = now.addingTimeInterval(6)
        XCTAssertTrue(p.requestNotAllowed, "our 120s must win over the server's 5s")
    }

    // MARK: Disposition — the delivery-path invariant

    /// The batch may be deleted ONLY on success. This is the single most
    /// important rule in the SDK: the old Obj-C SDK marked rows sent before
    /// the POST and blanket-deleted on any success, destroying other batches.
    func testDeleteOnlyOnSuccess() {
        var p = policy()
        XCTAssertEqual(p.apply(.success(nil)), .deleteBatch)
    }

    func testRetryableKeepsTheBatch() {
        var p = policy()
        XCTAssertEqual(
            p.apply(.retryable(status: 503, retryAfter: nil)), .keepAndRetry)
        XCTAssertEqual(p.consecutiveFailures, 1)
    }

    /// A 401 means bad credentials, not bad data — the events are still valid
    /// and must survive until the integration is fixed.
    func testTerminalKeepsTheBatchAndStops() {
        var p = policy()
        XCTAssertEqual(p.apply(.terminal(status: 401, body: nil)), .keepAndStop)
    }

    func testTransportFailureKeepsAndRetries() {
        var p = policy()
        XCTAssertEqual(p.apply(.transport("offline")), .keepAndRetry)
    }

    func testRetryableCarriesRetryAfterIntoTheWindow() {
        var p = policy()
        _ = p.apply(.retryable(status: 429, retryAfter: 90))
        now = now.addingTimeInterval(89)
        XCTAssertTrue(p.requestNotAllowed)
        now = now.addingTimeInterval(2)
        XCTAssertFalse(p.requestNotAllowed)
    }

    /// A sustained outage escalates rather than hammering. Each wait is
    /// measured from the frozen clock, not from the previous window.
    func testSustainedOutageEscalatesThenClamps() {
        var p = policy(jitter: 0)
        var waits: [TimeInterval] = []
        for _ in 0..<6 {
            p.recordFailure()
            waits.append(p.allowedAfter.timeIntervalSince(now))
        }
        XCTAssertEqual(waits[0], 0, "first failure does not back off")
        XCTAssertEqual(waits[1], 120, "2^1 * 60")
        XCTAssertEqual(waits[2], 240, "2^2 * 60")
        XCTAssertEqual(waits[3], 480, "2^3 * 60")
        XCTAssertEqual(waits[4], 600, "clamped at the ceiling")
        XCTAssertEqual(waits[5], 600, "stays clamped")
    }
}
