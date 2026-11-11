import XCTest

@testable import Intempt

/// The cross-SDK flag surface, per `docs/SDK-API-CONTRACT.md`.
///
/// The assertions that matter are the failure ones. A flag SDK is judged on what it returns when
/// the service is unreachable, not on the happy path.
final class FlagsTests: XCTestCase {

    // MARK: reason vocabulary
    //
    // Public since INT-7454, but that is not why. It is asserted because these strings are the
    // WIRE vocabulary shared with
    // intempt-java (`TARGETED("targeted")`, `HOLDOUT("holdout")`, `NOT_TARGETED("not_targeted")`),
    // and a raw value edited to match the Swift case name would silently stop matching the server.

    func testReasonWireValues() {
        XCTAssertEqual(FlagReason.targeted.rawValue, "targeted")
        XCTAssertEqual(FlagReason.holdout.rawValue, "holdout")
        XCTAssertEqual(FlagReason.off.rawValue, "off")
        // Snake case on the wire, camel case in Swift. The mapping is the point of the raw value.
        XCTAssertEqual(FlagReason.notTargeted.rawValue, "not_targeted")
    }

    func testUnansweredIsNotOff() {
        // EXP-SERVE-001: a caller must be able to tell a deliberate off state from a request the
        // service did not answer. This SDK aliased `unanswered` onto `.off` until 2026-08-31,
        // which is the collapse the requirement forbids. Deleting `case unanswered` restores the
        // alias and this goes red.
        XCTAssertNotEqual(FlagReason.unanswered, FlagReason.off)
        XCTAssertNotEqual(FlagReason.unanswered, FlagReason.notTargeted)
    }

    // Three tests that used to sit here are gone, for the reason the deleted FlagDetail pair went:
    // each asserted something the language guarantees, so none had a failing state.
    //
    //   testOffIsDistinguishableFromNotTargeted   two distinct cases of a synthesized-Equatable
    //                                             enum; deleting a case would not compile
    //   testAnUnknownReasonFallsBackRatherThanCrashing
    //                                             Swift's synthesized init?(rawValue:)
    //   testContextCarriesTheIdentifierThatSurvivesSignIn
    //                                             a memberwise-init round trip
    //
    // What each was reaching for is asserted for real below, against the evaluation path:
    // `testAnUnknownReasonResolvesToUnanswered` and
    // `testTheDefaultContextDerivesOnProfileIdNotUserId`.

    func testErrorIsItsOwnReason() {
        // INT-7454: a failed request must not read as a deliberate off state either.
        XCTAssertEqual(FlagReason.error.rawValue, "error")
        XCTAssertNotEqual(FlagReason.error, FlagReason.off)
        XCTAssertEqual(FlagError.Kind.badRequest.rawValue, "bad_request")
    }

    // MARK: key charset
    //
    // The server validates `names` against ^[a-zA-Z0-9_-]*$ inside `requestToMono`, so a key it
    // refuses takes the whole request body with it and the caller reads a default that is
    // indistinguishable from "no flag configured". These assert the predicate directly rather
    // than through a transport, because it is pure and total.

    func testAKeyTheServerWouldRefuseIsRejectedBeforeTheRoundTrip() {
        XCTAssertFalse(Flags.isValidKey("checkout.new"), "a dot is outside ^[a-zA-Z0-9_-]*$")
        XCTAssertFalse(Flags.isValidKey("new checkout"), "a space is outside it")
        XCTAssertFalse(Flags.isValidKey("pricing:cta"), "a colon is outside it")
        XCTAssertFalse(Flags.isValidKey("flag/one"), "a slash is outside it")
        XCTAssertFalse(Flags.isValidKey("café"), "the pattern is ASCII; é is not in it")
        XCTAssertFalse(Flags.isValidKey(""), "stricter than the server on purpose — * admits empty")
    }

    func testTheKeysIntegratorsActuallyWriteAreAccepted() {
        // The guard must not be the reason a working key stops working: every shape the pattern
        // does allow has to pass, or this fix is a regression dressed as a hardening.
        XCTAssertTrue(Flags.isValidKey("new_checkout"))
        XCTAssertTrue(Flags.isValidKey("pricing-cta"))
        XCTAssertTrue(Flags.isValidKey("Flag2"))
        XCTAssertTrue(Flags.isValidKey("_leading"))
        XCTAssertTrue(Flags.isValidKey("-leading"))
        XCTAssertTrue(Flags.isValidKey("a"))
    }

}

// MARK: - Flags.detail, against a scripted transport
//
// The four tests above cover the FlagReason enum and FlagContext — types, not behaviour.
// Nothing exercised the evaluation path itself, so the failure modes every other SDK in
// this effort tests were untested here: an unreachable service, a non-2xx, a malformed
// body, an unknown key, a blank key. Each yields no value, which is what tells the caller
// to use its defaultValue rather than throw into a render, and since INT-7454 a reason
// that says which of them happened.
//
// These target `Flags.detail` rather than `IntemptInstance.variation` because
// IntemptInstance's init is private and cannot be built with a stubbed Network. That
// leaves ONE thing uncovered: the `?? defaultValue` substitution itself, which lives in
// IntemptInstance. Making that reachable means widening the init, which is a source
// change for testability and not one to make quietly inside a feature PR. Recorded here
// so the gap is visible rather than assumed away.
//
// MockSession and URLSessionProtocol already existed; only the Flags wiring was missing.

final class FlagsDetailTests: XCTestCase {

    private let hookCalls = HookCalls()

    private func flags(_ replies: [MockSession.Reply]) -> (Flags, MockSession) {
        let session = MockSession(replies: replies, fallback: .status(500))
        let network = Network(session: session, host: "example.invalid")
        let f = Flags(
            network: network,
            credentials: try! IntemptCredentials(apiKey: "examplePrefix123.exampleSecretValue"),
            orgId: "o", projectId: "p", sourceId: "s")
        let hookCalls = self.hookCalls
        f.onFlagError = { hookCalls.append($0) }
        return (f, session)
    }

    private func detail(
        _ f: Flags,
        _ key: String,
        context: FlagContext = FlagContext(userId: "u-1"),
        sessionId: String? = "s-1"
    ) -> FlagEvaluation? {
        let done = expectation(description: "detail")
        var out: FlagEvaluation?
        f.detail(key: key, context: context, sessionId: sessionId) {
            out = $0
            done.fulfill()
        }
        wait(for: [done], timeout: 2)
        return out
    }

    private func all(_ f: Flags) -> [String: JSONValue] {
        let done = expectation(description: "all")
        var out: [String: JSONValue] = [:]
        f.all(context: FlagContext(userId: "u-1"), sessionId: "s-1") {
            out = $0
            done.fulfill()
        }
        wait(for: [done], timeout: 2)
        return out
    }

    func testReturnsTheServedValue() {
        // The fixture supplies "group" and "reason" and the serving response carries NEITHER
        // today — which is why variationDetail is not public and why asserting on them here
        // would prove nothing about the platform.
        let (f, _) = flags([
            .json(
                200,
                #"{"choices":[{"name":"checkout_v2","group":"B","body":true,"reason":"targeted"}]}"#
            )
        ])
        XCTAssertEqual(detail(f, "checkout_v2")?.value, .bool(true))
    }

    func testAServedNullBodyYieldsNoValueSoTheCallerSubstitutes() {
        // NOT the holdout case, which cannot be asserted: a held-back person's experience is
        // absent from the response entirely rather than present with a cause.
        let (f, _) = flags([.json(200, #"{"choices":[{"name":"k","body":null}]}"#)])
        XCTAssertNil(detail(f, "k")?.value)
    }

    /// The service answered and served nothing for the key: a real `off`, not an error
    /// (CONTRACT S3 keeps `off` here so INT-7457 stays honest).
    func testAnUnknownKeyYieldsNoValueAndOff() {
        let (f, _) = flags([.json(200, #"{"choices":[]}"#)])
        let result = detail(f, "never_created")
        XCTAssertNil(result?.value)
        XCTAssertEqual(result?.reason, .off)
        XCTAssertNil(result?.error)
        XCTAssertTrue(hookCalls.errors.isEmpty, "an answered request is not a failure")
    }

    func testANon2xxYieldsNoValueAndAServerError() {
        let (f, _) = flags([.status(500)])
        let result = detail(f, "k")
        XCTAssertNil(result?.value)
        XCTAssertEqual(result?.reason, .error)
        XCTAssertEqual(result?.error, FlagError(key: "k", kind: .server, status: 500))
        XCTAssertEqual(hookCalls.errors, [FlagError(key: "k", kind: .server, status: 500)])
    }

    func testAnUnreachableServiceYieldsANetworkError() {
        let (f, _) = flags([.offline()])
        let result = detail(f, "k")
        XCTAssertNil(result?.value)
        XCTAssertEqual(result?.error, FlagError(key: "k", kind: .network, status: nil))
    }

    func testAMalformedBodyYieldsAParseError() {
        let (f, _) = flags([.json(200, "not json at all")])
        let result = detail(f, "k")
        XCTAssertNil(result?.value)
        XCTAssertEqual(result?.error, FlagError(key: "k", kind: .parse, status: nil))
    }

    /// INT-7454: a wrong key used to read exactly like "flag not configured", with no log. The
    /// hook fires on every failure, and the error-level log names the key prefix, once.
    func testARejectedKeyFiresTheHookEveryTimeAndLogsAnErrorOnce() {
        let sink = CollectingLogger()
        IntemptLogger.shared.addLogging(sink)
        IntemptLogger.shared.enable(.error)
        defer {
            IntemptLogger.shared.removeAllLogging()
            IntemptLogger.shared.disableAllLevels()
        }
        let (f, _) = flags([.status(401), .status(403)])

        XCTAssertEqual(detail(f, "k")?.error, FlagError(key: "k", kind: .auth, status: 401))
        XCTAssertEqual(detail(f, "k")?.error, FlagError(key: "k", kind: .auth, status: 403))

        XCTAssertEqual(hookCalls.errors.map(\.kind), [.auth, .auth])
        let errorLines = sink.messages.filter { $0.contains("examplePrefix123") }
        XCTAssertEqual(errorLines.count, 1, "error level once per instance, debug after: \(sink.messages)")
        XCTAssertFalse(errorLines.joined().contains("exampleSecretValue"), "never the secret")
    }

    func testStatusesMapToTheirKinds() {
        let cases: [(MockSession.Reply, FlagError.Kind, Int?)] = [
            (.status(400), .badRequest, 400), (.status(404), .badRequest, 404),
            (.status(408), .timeout, 408), (.status(429), .badRequest, 429),
            (.status(502), .server, 502), (.status(503), .server, 503),
            (.timedOut(), .timeout, nil),
        ]
        for (reply, kind, status) in cases {
            let (f, _) = flags([reply])
            XCTAssertEqual(detail(f, "k")?.error, FlagError(key: "k", kind: kind, status: status), "\(reply)")
        }
    }

    /// Skipped the round trip, as before, but no longer silently.
    func testAKeyTheServiceWouldRejectIsReportedWithoutARequest() {
        let (f, session) = flags([])
        let result = detail(f, "checkout.new")
        XCTAssertEqual(result?.reason, .error)
        XCTAssertEqual(result?.error, FlagError(key: "checkout.new", kind: .badRequest, status: nil))
        XCTAssertEqual(session.requestCount, 0)
    }

    func testAllFlagsReportsAFailureWithNoKey() {
        let (f, _) = flags([.status(500)])
        XCTAssertTrue(all(f).isEmpty)
        XCTAssertEqual(hookCalls.errors, [FlagError(key: nil, kind: .server, status: 500)])
    }

    func testAnUnknownReasonResolvesToUnanswered() {
        // A reason this SDK version predates must not trap AND must not read as a deliberate
        // off state. Both halves matter: `off` here is a wrong answer, not a missing one.
        let (f, _) = flags([
            .json(200, #"{"choices":[{"name":"k","body":true,"reason":"invented_later"}]}"#)
        ])
        XCTAssertEqual(detail(f, "k")?.reason, .unanswered)
    }

    func testTheDefaultContextDerivesOnProfileIdNotUserId() {
        // EXP-ASSIGN-005: the value must not change when someone signs in. profileId is present
        // on both sides of that transition; userId appears at it. A context carrying only
        // profileId must not smuggle a userId onto the wire, because the server segments on
        // EntityType.USER when userId is present and EntityType.PROFILE otherwise — two
        // different entities, so the person re-buckets.
        let (f, session) = flags([.json(200, #"{"choices":[]}"#)])
        _ = detail(f, "k", context: FlagContext(profileId: "p-1"))
        let identification = session.bodies.first?["identification"] as? [String: Any]
        XCTAssertEqual(identification?["profileId"] as? String, "p-1")
        XCTAssertNil(identification?["userId"])
    }

    func testTheRequestNamesTheKeyAndCarriesTheIdentifier() {
        let (f, session) = flags([.json(200, #"{"choices":[]}"#)])
        _ = detail(f, "checkout_v2")
        let body = session.bodies.first
        XCTAssertEqual(body?["names"] as? [String], ["checkout_v2"])
        XCTAssertEqual((body?["identification"] as? [String: Any])?["userId"] as? String, "u-1")
        // `device` must stay inside ExperienceDevice (all/desktop/mobile). Anything else fails to
        // bind server-side and the entire request is rejected, silently.
        let device = body?["device"] as? String
        XCTAssertNotNil(device)
        XCTAssertTrue(
            Personalization.allowedDeviceClasses.contains(device ?? ""),
            "device \(device ?? "nil") is outside ExperienceDevice")
        // Without sessionId, ChooserHelper stores "default" and ONCE_PER_VISIT degrades to
        // once-ever-per-profile.
        XCTAssertEqual(body?["sessionId"] as? String, "s-1")
    }

    func testABlankSessionIdIsOmittedRatherThanSentEmpty() {
        let (f, session) = flags([.json(200, #"{"choices":[]}"#)])
        _ = detail(f, "k", sessionId: "")
        XCTAssertNil(session.bodies.first?["sessionId"])
    }

    func testAllFlagsAsksForEveryKeyRatherThanNamingOne() {
        // `names` absent is what makes the serving query return everything; sending an empty
        // array instead would filter to nothing and look like "no flags exist".
        let (f, session) = flags([.json(200, #"{"choices":[]}"#)])
        _ = all(f)
        XCTAssertNil(session.bodies.first?["names"])
    }

    func testAllFlagsOmitsANullBodyRatherThanReportingItAsAValue() {
        // detail() flattens a JSON null to absent; all() returned `.null` for the same key, so
        // the two public methods disagreed about one flag. A caller enumerating allFlags() saw a
        // key it could not use, while variation(key:) for that key gave it the default.
        let (f, _) = flags([
            .json(200, #"{"choices":[{"name":"served","body":true},{"name":"empty","body":null}]}"#)
        ])
        let values = all(f)
        XCTAssertEqual(values["served"], .bool(true))
        XCTAssertNil(values["empty"])
        XCTAssertEqual(values.count, 1)
    }
}

/// The public surface: `variationDetail` substitutes the default and keeps the reason, and the
/// instance hook reaches `Flags` (INT-7454).
final class VariationDetailTests: IntemptTestCase {

    private func instance(_ replies: [MockSession.Reply]) throws -> IntemptInstance {
        try IntemptInstance.makeForTesting(
            store: defaults, databaseDirectory: tempDir,
            network: Network(session: MockSession(replies: replies, fallback: .status(500))))
    }

    private func detail(_ sdk: IntemptInstance, _ key: String = "k") -> FlagDetail? {
        let done = expectation(description: "variationDetail")
        var out: FlagDetail?
        sdk.variationDetail(key: key, defaultValue: .string("fallback")) {
            out = $0
            done.fulfill()
        }
        wait(for: [done], timeout: 2)
        return out
    }

    func testAFailureReturnsTheDefaultWithTheError() throws {
        let sdk = try instance([.status(401)])
        let calls = HookCalls()
        sdk.onFlagError = { calls.append($0) }

        let result = detail(sdk)
        XCTAssertEqual(result?.value, .string("fallback"))
        XCTAssertEqual(result?.reason, .error)
        XCTAssertEqual(result?.error, FlagError(key: "k", kind: .auth, status: 401))
        XCTAssertEqual(calls.errors, [FlagError(key: "k", kind: .auth, status: 401)])
    }

    func testAnAnsweredMissReturnsTheDefaultAndOff() throws {
        let result = detail(try instance([.json(200, #"{"choices":[]}"#)]))
        XCTAssertEqual(result?.value, .string("fallback"))
        XCTAssertEqual(result?.reason, .off)
        XCTAssertNil(result?.error)
    }

    func testAServedValueIsReturnedWithoutAGuessedReason() throws {
        let result = detail(try instance([.json(200, #"{"choices":[{"name":"k","body":"B"}]}"#)]))
        XCTAssertEqual(result?.value, .string("B"))
        XCTAssertEqual(result?.reason, .unanswered, "the serving response sends no reason")
    }

    func testVariationStillReturnsTheDefaultOnFailure() throws {
        let sdk = try instance([.status(500)])
        let done = expectation(description: "variation")
        sdk.variation(key: "k", defaultValue: .bool(false)) {
            XCTAssertEqual($0, .bool(false))
            done.fulfill()
        }
        wait(for: [done], timeout: 2)
    }
}

/// Written from the network callback's thread, read from the test thread.
final class HookCalls {
    private let lock = NSLock()
    private var _errors: [FlagError] = []

    var errors: [FlagError] {
        lock.lock()
        defer { lock.unlock() }
        return _errors
    }

    func append(_ error: FlagError) {
        lock.lock()
        _errors.append(error)
        lock.unlock()
    }
}
