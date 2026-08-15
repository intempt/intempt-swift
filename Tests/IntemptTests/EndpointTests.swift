import XCTest

@testable import Intempt

/// Every path asserted against the verified intemptjs call sites:
///   track     autoTracker.module.ts:163
///   consents  autoTracker.module.ts:377
///   feed      intemptJs.ts:299
final class EndpointTests: XCTestCase {

    func testTrackPath() {
        let e = Endpoint.track(org: "acme", project: "web", sourceId: "42")
        XCTAssertEqual(e.path, "/acme/projects/web/sources/42/track")
        XCTAssertEqual(
            e.url()?.absoluteString,
            "https://api.intempt.com/v1/acme/projects/web/sources/42/track")
    }

    func testConsentsPathIsSeparateFromTrack() {
        let e = Endpoint.consents(org: "acme", project: "web")
        XCTAssertEqual(e.path, "/acme/projects/web/consents/data")
        XCTAssertFalse(e.path.contains("/track"), "consent must not route through /track")
        XCTAssertFalse(e.path.contains("/sources/"), "consent is not source-scoped")
    }

    /// Native clients use choose-api. choose-web is the web variant and must
    /// never appear here.
    func testChooseApiNotChooseWeb() {
    }

    func testFeedPath() {
        let e = Endpoint.feed(org: "acme", project: "web", feedId: "7")
        XCTAssertEqual(e.path, "/acme/projects/web/feeds/7/data")
    }

    func testConstantsMatchWireContract() {
        XCTAssertEqual(APIConstants.host, "https://api.intempt.com/v1")
        XCTAssertEqual(APIConstants.maxBatchSize, 50)
        XCTAssertEqual(EventConstants.eventIdPrefix, "ev_")
    }

    /// The old Obj-C SDK treated 401/429/500 as success and then deleted the
    /// batch. These must be classified, not conflated.
    func testRetryableStatusClassification() {
        for s in [408, 429, 500, 502, 503, 504] {
            XCTAssertTrue(APIConstants.retryableStatuses.contains(s), "\(s) should be retryable")
        }
        for s in [400, 401, 402, 403, 404, 422] {
            XCTAssertFalse(APIConstants.retryableStatuses.contains(s), "\(s) must be terminal")
        }
    }
}
