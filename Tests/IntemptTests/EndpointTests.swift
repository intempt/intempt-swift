import XCTest

@testable import Intempt

/// Every path asserted against the verified intemptjs call sites:
///   track     autoTracker.module.ts:163
///   consents  autoTracker.module.ts:377
///   feed      intemptJs.ts:299
final class EndpointTests: XCTestCase {

    func testTrackPath() {
        let e = Endpoint.track(org: "acme", project: "web", sourceId: "42", useIPForGeolocation: true)
        XCTAssertEqual(e.path, "/acme/projects/web/sources/42/track?ip=1")
        XCTAssertEqual(
            e.url()?.absoluteString,
            "https://api.intempt.com/v1/acme/projects/web/sources/42/track?ip=1")
    }

    /// The device never reads its own address. It states whether the platform may derive location
    /// from the address the request already arrives on, and that is the whole mechanism.
    func testTrackPathCarriesTheGeolocationFlag() {
        let off = Endpoint.track(org: "acme", project: "web", sourceId: "42", useIPForGeolocation: false)
        XCTAssertEqual(off.path, "/acme/projects/web/sources/42/track?ip=0")

        let on = Endpoint.track(org: "acme", project: "web", sourceId: "42", useIPForGeolocation: true)
        XCTAssertEqual(on.path, "/acme/projects/web/sources/42/track?ip=1")
        XCTAssertNotEqual(on.path, off.path, "the flag must actually change the request")
    }

    /// Exactly one `?ip=`. A second would be parsed as part of the first value.
    func testGeolocationFlagAppearsExactlyOnce() {
        let path = Endpoint.track(
            org: "acme", project: "web", sourceId: "42",
            useIPForGeolocation: true
        ).path
        XCTAssertEqual(path.components(separatedBy: "?ip=").count - 1, 1)
    }

    /// Consent and feed carry no geolocation flag; only /track does.
    func testOnlyTrackCarriesTheFlag() {
        XCTAssertFalse(Endpoint.consents(org: "acme", project: "web").path.contains("ip="))
        XCTAssertFalse(
            Endpoint.feed(org: "acme", project: "web", feedId: "1").path.contains("ip="))
    }

    func testConsentsPathIsSeparateFromTrack() {
        let e = Endpoint.consents(org: "acme", project: "web")
        XCTAssertEqual(e.path, "/acme/projects/web/consents/data")
        XCTAssertFalse(e.path.contains("/track"), "consent must not route through /track")
        XCTAssertFalse(e.path.contains("/sources/"), "consent is not source-scoped")
    }

    /// A native SDK uses choose-api. choose-web is intemptjs alone, where a change is applied
    /// against the DOM and the caller never branches; a native surface has no visual editor, so the
    /// value is authored as a payload and read like any server call.
    ///
    /// This test had an empty body between the 2026-08-15 removal of the endpoint and its return
    /// here. It passed the whole time, which is what an empty test does.
    func testChooseApiNotChooseWeb() {
        let e = Endpoint.chooseApi(org: "acme", project: "web")
        XCTAssertEqual(e.path, "/acme/projects/web/optimization/choose-api")
        XCTAssertFalse(e.path.contains("choose-web"), "a native SDK is an api-channel consumer")
        XCTAssertEqual(
            e.url()?.absoluteString,
            "https://api.intempt.com/v1/acme/projects/web/optimization/choose-api")
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
