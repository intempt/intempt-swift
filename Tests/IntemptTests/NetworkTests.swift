import XCTest

@testable import Intempt

final class NetworkTests: XCTestCase {

    private let creds = try! IntemptCredentials(apiKey: "pfx.secret")

    private func response(_ status: Int, headers: [String: String] = [:]) -> HTTPURLResponse {
        HTTPURLResponse(
            url: URL(string: "https://api.intempt.com/v1/x")!,
            statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
    }

    // MARK: Request construction

    func testTrackRequestShape() throws {
        let net = Network()
        let req = try net.makeRequest(
            endpoint: .track(org: "acme", project: "web", sourceId: "42", useIPForGeolocation: true),
            credentials: creds,
            body: ["track": []])

        XCTAssertEqual(
            req.url?.absoluteString,
            "https://api.intempt.com/v1/acme/projects/web/sources/42/track?ip=1")
        XCTAssertEqual(req.httpMethod, "POST")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(
            req.value(forHTTPHeaderField: "Authorization"),
            "Basic " + Data("pfx:secret".utf8).base64EncodedString())
        XCTAssertNotNil(req.httpBody)
    }

    /// URLSession owns Content-Length; setting it manually is unsupported and
    /// produced duplicate headers behind some proxies in the old SDK.
    func testContentLengthIsNotSetManually() throws {
        let req = try Network().makeRequest(
            endpoint: .track(org: "a", project: "b", sourceId: "1", useIPForGeolocation: true),
            credentials: creds, body: ["track": []])
        XCTAssertNil(req.value(forHTTPHeaderField: "Content-Length"))
    }

    func testConsentRequestGoesToItsOwnEndpoint() throws {
        let req = try Network().makeRequest(
            endpoint: .consents(org: "acme", project: "web"),
            credentials: creds, body: ["action": "reject"])
        let url = req.url!.absoluteString
        XCTAssertEqual(url, "https://api.intempt.com/v1/acme/projects/web/consents/data")
        XCTAssertFalse(url.contains("/track"), "consent must not route through /track")
    }

    // MARK: Status classification

    /// Direct regression for F-34: under URLSession an HTTP 500 arrives with
    /// error == nil. The old SDK read that as success and deleted the batch.
    func testServerErrorIsNotTreatedAsSuccess() {
        for status in [500, 502, 503, 504] {
            let outcome = Network.classify(data: nil, response: response(status), error: nil)
            XCTAssertFalse(outcome.isSuccess, "\(status) must never classify as success")
            XCTAssertEqual(outcome, .retryable(status: status, retryAfter: nil))
        }
    }

    func testSuccessRange() {
        for status in [200, 201, 202, 204] {
            XCTAssertTrue(
                Network.classify(data: Data(), response: response(status), error: nil).isSuccess)
        }
    }

    func testRetryableStatuses() {
        for status in [408, 429] {
            XCTAssertEqual(
                Network.classify(data: nil, response: response(status), error: nil),
                .retryable(status: status, retryAfter: nil))
        }
    }

    /// Retrying a bad credential or a capped account can never succeed.
    func testTerminalStatuses() {
        for status in [400, 401, 402, 403, 404, 422] {
            XCTAssertEqual(
                Network.classify(data: nil, response: response(status), error: nil),
                .terminal(status: status, body: nil),
                "\(status) must be terminal, not retried forever")
        }
    }

    func testTransportFailure() {
        let err = NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet)
        let outcome = Network.classify(data: nil, response: nil, error: err)
        if case .transport = outcome {} else { XCTFail("expected transport failure, got \(outcome)") }
    }

    func testMissingHTTPResponseIsTransportFailure() {
        let outcome = Network.classify(data: nil, response: URLResponse(), error: nil)
        if case .transport = outcome {} else { XCTFail("expected transport failure") }
    }

    // MARK: Retry-After

    func testRetryAfterSeconds() {
        let r = response(429, headers: ["Retry-After": "30"])
        XCTAssertEqual(Network.retryAfter(from: r), 30)
        XCTAssertEqual(
            Network.classify(data: nil, response: r, error: nil),
            .retryable(status: 429, retryAfter: 30))
    }

    func testRetryAfterHTTPDate() {
        let future = Date().addingTimeInterval(120)
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "GMT")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        let r = response(503, headers: ["Retry-After": f.string(from: future)])
        let seconds = Network.retryAfter(from: r)
        XCTAssertNotNil(seconds)
        XCTAssertEqual(seconds!, 120, accuracy: 5)
    }

    func testMalformedRetryAfterIsIgnoredNotFatal() {
        let r = response(429, headers: ["Retry-After": "not-a-date"])
        XCTAssertNil(Network.retryAfter(from: r))
    }
}
