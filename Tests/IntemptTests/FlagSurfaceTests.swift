import XCTest

@testable import Intempt

/// The public flag and choose surface on a real `IntemptInstance`, over `MockSession`: which route
/// each call reaches, the default substitution and the transport settings. The evaluator's own
/// rules are in FlagsTests.swift, against closures.
final class FlagSurfaceTests: IntemptTestCase {

    private func instance(
        _ replies: [MockSession.Reply], fallback: MockSession.Reply = .status(500)
    ) throws -> (IntemptInstance, MockSession) {
        let session = MockSession(replies: replies, fallback: fallback)
        let sdk = try IntemptInstance.makeForTesting(
            store: defaults, databaseDirectory: tempDir,
            network: Network(session: session))
        return (sdk, session)
    }

    private func paths(_ session: MockSession) -> [String] {
        session.requests.compactMap { $0.url?.path }
    }

    private func detail(
        _ sdk: IntemptInstance, _ key: String = "k", default defaultValue: JSONValue = .string("fallback"),
        disableExposure: Bool = false
    ) -> FlagDetail? {
        let done = expectation(description: "variationDetail")
        var out: FlagDetail?
        sdk.variationDetail(key: key, defaultValue: defaultValue, disableExposure: disableExposure) {
            out = $0
            done.fulfill()
        }
        wait(for: [done], timeout: 2)
        return out
    }

    func testAFlagReadGoesToEvaluateNeverChooseApi() throws {
        let (sdk, session) = try instance([
            .json(200, #"{"key":"k","value":"B","variationId":4,"reason":"targeted"}"#)
        ])
        let result = detail(sdk)
        XCTAssertEqual(paths(session), ["/v1/acme/projects/web/flags/evaluate"])
        XCTAssertEqual(result?.value, .string("B"))
        XCTAssertEqual(result?.reason, .targeted)
        XCTAssertEqual(result?.variationId, 4)
        XCTAssertEqual(session.bodies.first?["sessionId"] as? String, sdk.getSessionId())
    }

    func testAFlagReadOpensTheStreamWithTheSameAuth() throws {
        let (sdk, session) = try instance([.json(200, #"{"key":"k","value":true}"#)])
        _ = detail(sdk, default: .bool(false))
        let stream = try XCTUnwrap(session.streamRequests.first)
        XCTAssertEqual(stream.url?.path, "/v1/acme/projects/web/flags/stream")
        XCTAssertEqual(stream.httpMethod, "GET")
        XCTAssertEqual(stream.value(forHTTPHeaderField: "Accept"), "text/event-stream")
        XCTAssertEqual(
            stream.value(forHTTPHeaderField: "Authorization"),
            session.requests.first?.value(forHTTPHeaderField: "Authorization"))
        XCTAssertEqual(stream.timeoutInterval, Network.streamIdleTimeout)
    }

    func testFlagAndChooseReadsTimeOutAfter2s() throws {
        let (sdk, session) = try instance([])
        _ = detail(sdk)
        let done = expectation(description: "choose")
        sdk.choose(names: ["hero"]) { _ in done.fulfill() }
        wait(for: [done], timeout: 2)
        XCTAssertEqual(session.requests.map(\.timeoutInterval), [2, 2])
    }

    func testAFailureReturnsTheDefaultWithTheErrorAndFiresTheHook() throws {
        let (sdk, _) = try instance([.status(401)])
        let calls = HookCalls()
        sdk.onFlagError = { calls.append($0) }
        let result = detail(sdk)
        XCTAssertEqual(result?.value, .string("fallback"))
        XCTAssertEqual(result?.reason, .error)
        XCTAssertEqual(result?.errorCode, .general)
        XCTAssertEqual(result?.error, FlagError(key: "k", kind: .auth, status: 401))
        XCTAssertEqual(calls.errors, [FlagError(key: "k", kind: .auth, status: 401)])
    }

    func testA404IsFlagNotFound() throws {
        let (sdk, _) = try instance([.status(404)])
        XCTAssertEqual(detail(sdk)?.errorCode, .flagNotFound)
    }

    func testDisableExposureReadsThroughAll() throws {
        let (sdk, session) = try instance([.json(200, #"{"flags":[{"key":"k","value":true}]}"#)])
        let done = expectation(description: "boolVariation")
        var value: Bool?
        sdk.boolVariation(key: "k", defaultValue: false, disableExposure: true) {
            value = $0
            done.fulfill()
        }
        wait(for: [done], timeout: 2)
        XCTAssertEqual(value, true)
        XCTAssertEqual(paths(session), ["/v1/acme/projects/web/flags/all"])
        XCTAssertEqual(session.bodies.first?["keys"] as? [String], ["k"])
    }

    func testTypedReadsNeverCoerce() throws {
        let (sdk, _) = try instance([.json(200, #"{"key":"k","value":"true"}"#)])
        let done = expectation(description: "boolVariation")
        sdk.boolVariation(key: "k", defaultValue: false) {
            XCTAssertFalse($0)
            done.fulfill()
        }
        wait(for: [done], timeout: 2)
    }

    func testJsonVariationAcceptsAnArray() throws {
        let (sdk, _) = try instance([.json(200, #"{"key":"k","value":[1],"valueType":"json"}"#)])
        let done = expectation(description: "jsonVariation")
        sdk.jsonVariation(key: "k", defaultValue: .object([:])) {
            XCTAssertEqual($0, .array([.number(1)]))
            done.fulfill()
        }
        wait(for: [done], timeout: 2)
    }

    func testAllFlagsReadsAllAndExposesOnFirstRead() throws {
        let (sdk, session) = try instance(
            [.json(200, #"{"flags":[{"key":"a","value":true,"variationId":5}]}"#)],
            fallback: .status(202))
        let done = expectation(description: "allFlags")
        var values: FlagValues?
        sdk.allFlags {
            values = $0
            done.fulfill()
        }
        wait(for: [done], timeout: 2)
        XCTAssertEqual(paths(session), ["/v1/acme/projects/web/flags/all"])
        XCTAssertEqual(values?["a"], .bool(true))
        _ = values?["a"]
        XCTAssertEqual(
            paths(session),
            ["/v1/acme/projects/web/flags/all", "/v1/acme/projects/web/flags/expose"])
        XCTAssertEqual(session.bodies.last?["variationId"] as? Int, 5)
    }

    func testChooseReadsChooseApiWithNames() throws {
        let (sdk, session) = try instance([
            .json(200, #"{"choices":[{"name":"hero","group":"home","body":{"t":1},"variantId":3}]}"#)
        ])
        let done = expectation(description: "choose")
        var choices: [Choice] = []
        sdk.choose(names: ["hero"]) {
            choices = $0
            done.fulfill()
        }
        wait(for: [done], timeout: 2)
        XCTAssertEqual(paths(session), ["/v1/acme/projects/web/optimization/choose-api"])
        XCTAssertEqual(session.bodies.first?["names"] as? [String], ["hero"])
        XCTAssertEqual(
            (session.bodies.first?["identification"] as? [String: Any])?["profileId"] as? String,
            sdk.getProfileId())
        XCTAssertEqual(
            choices, [Choice(name: "hero", group: "home", body: .object(["t": .number(1)]), variantId: 3)])
    }
}

/// The URLSession reply mapped onto the flag reply kinds: the same table as intempt-node.
final class FlagTransportTests: XCTestCase {

    func testStatusesMapToTheirKinds() {
        let cases: [(HTTPOutcome, FlagError.Kind, Int?)] = [
            (.terminal(status: 400, body: nil), .badRequest, 400),
            (.terminal(status: 404, body: nil), .badRequest, 404),
            (.terminal(status: 401, body: nil), .auth, 401),
            (.terminal(status: 403, body: nil), .auth, 403),
            (.retryable(status: 408, retryAfter: nil), .timeout, 408),
            (.retryable(status: 429, retryAfter: nil), .server, 429),
            (.terminal(status: 501, body: nil), .server, 501),
            (.retryable(status: 503, retryAfter: nil), .server, 503),
            (.unanswered("timed out"), .timeout, nil),
            (.transport("offline"), .network, nil),
        ]
        for (outcome, kind, status) in cases {
            XCTAssertEqual(FlagTransport.reply(for: outcome), .failed(kind, status: status), "\(outcome)")
        }
        XCTAssertEqual(FlagTransport.reply(for: .success(nil)), .answered(nil))
    }
}
