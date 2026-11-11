import XCTest

@testable import Intempt

/// Round-2 CONTRACT S1 (INT-7436), decided without IO. `FlushTests` proves the
/// same table end to end.
final class RetryPolicyTests: XCTestCase {

    func testSuccessDeletesTheBatch() {
        XCTAssertEqual(RetryPolicy.disposition(for: .success(nil)), .deleteBatch)
        XCTAssertNil(RetryPolicy.resendDelay(after: .success(nil), isResend: false))
    }

    func testOnly503And429EarnAResend() {
        for status in [429, 503] {
            XCTAssertNotNil(
                RetryPolicy.resendDelay(after: .retryable(status: status, retryAfter: nil), isResend: false))
        }
        for outcome: HTTPOutcome in [
            .terminal(status: 500, body: nil), .terminal(status: 401, body: nil),
            .unanswered("timed out"), .transport("offline"),
        ] {
            XCTAssertNil(RetryPolicy.resendDelay(after: outcome, isResend: false), "\(outcome)")
        }
    }

    func testThereIsOnlyOneResend() {
        XCTAssertNil(
            RetryPolicy.resendDelay(after: .retryable(status: 503, retryAfter: 5), isResend: true))
        XCTAssertEqual(
            RetryPolicy.disposition(for: .retryable(status: 503, retryAfter: 5)), .drop(.terminal),
            "a 503 that reaches a verdict is the failed resend, and it drops the batch")
    }

    func testResendWaitIsRetryAfterClampedToOneToSixtySeconds() {
        XCTAssertEqual(RetryPolicy.clampedDelay(nil), 1, "absent Retry-After waits the floor")
        XCTAssertEqual(RetryPolicy.clampedDelay(0), 1)
        XCTAssertEqual(RetryPolicy.clampedDelay(30), 30)
        XCTAssertEqual(RetryPolicy.clampedDelay(600), 60)
    }

    func testEveryOtherAnswerIsDroppedAsTerminal() {
        for status in [400, 401, 402, 403, 404, 408, 413, 422, 500, 502, 504] {
            XCTAssertEqual(
                RetryPolicy.disposition(for: .terminal(status: status, body: nil)), .drop(.terminal),
                "\(status)")
        }
    }

    func testUnansweredIsDroppedNotKept() {
        XCTAssertEqual(RetryPolicy.disposition(for: .unanswered("timed out")), .drop(.dropped))
    }

    func testOnlyANeverReachedRequestIsKept() {
        XCTAssertEqual(RetryPolicy.disposition(for: .transport("offline")), .keepForNextFlush)
    }
}
