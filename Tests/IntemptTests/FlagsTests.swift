import XCTest

@testable import Intempt

/// The cross-SDK flag surface, per `docs/SDK-API-CONTRACT.md`.
///
/// The assertions that matter are the failure ones. A flag SDK is judged on what it returns when
/// the service is unreachable, not on the happy path.
final class FlagsTests: XCTestCase {

    // MARK: reason vocabulary — published to four package registries, so it cannot drift

    func testReasonWireValues() {
        XCTAssertEqual(FlagReason.targeted.rawValue, "targeted")
        XCTAssertEqual(FlagReason.holdout.rawValue, "holdout")
        XCTAssertEqual(FlagReason.off.rawValue, "off")
        // Snake case on the wire, camel case in Swift. The mapping is the point of the raw value.
        XCTAssertEqual(FlagReason.notTargeted.rawValue, "not_targeted")
    }

    func testOffIsDistinguishableFromNotTargeted() {
        // A stopped experience and a person outside the audience are different answers. Collapsing
        // them is the ambiguity this whole surface exists to remove.
        XCTAssertNotEqual(FlagReason.off, FlagReason.notTargeted)
    }

    func testAnUnknownReasonFallsBackRatherThanCrashing() {
        // A reason added server-side that this SDK version predates must not trap.
        XCTAssertNil(FlagReason(rawValue: "invented_later"))
    }

    // MARK: context

    func testContextCarriesTheIdentifierThatSurvivesSignIn() {
        // profileId is present before and after sign-in; userId only appears at it. Deriving on
        // userId re-buckets a visitor mid-session.
        let context = FlagContext(userId: "u-1", profileId: "p-1")
        XCTAssertEqual(context.profileId, "p-1")
        XCTAssertEqual(context.userId, "u-1")

        let anonymous = FlagContext(profileId: "p-1")
        XCTAssertNil(anonymous.userId)
        XCTAssertEqual(anonymous.profileId, "p-1")
    }

    // The two FlagDetail tests that were here are deleted rather than adapted. Each built a
    // FlagDetail and asserted it held what had just been put in it -- a memberwise initialiser
    // storing its arguments, which is a property of the language and cannot fail. Neither could
    // ever have gone red, and `variant` being wrong all along is what they failed to catch.
    //
    // FlagDetail is internal now anyway: it carries a reason the platform does not send, so
    // variationDetail is not exposed until the serving contract carries one.
}

// MARK: - Flags.detail, against a scripted transport
//
// The four tests above cover the FlagReason enum and FlagContext — types, not behaviour.
// Nothing exercised the evaluation path itself, so the failure modes every other SDK in
// this effort tests were untested here: an unreachable service, a non-2xx, a malformed
// body, an unknown key, a blank key. Each must yield nil, which is what tells the caller
// to use its defaultValue rather than throw into a render.
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

    private func flags(_ replies: [MockSession.Reply]) -> (Flags, MockSession) {
        let session = MockSession(replies: replies, fallback: .status(500))
        let network = Network(session: session, host: "example.invalid")
        let f = Flags(
            network: network,
            credentials: try! IntemptCredentials(apiKey: "examplePrefix123.exampleSecretValue"),
            orgId: "o", projectId: "p", sourceId: "s")
        return (f, session)
    }

    private func detail(_ f: Flags, _ key: String) -> FlagDetail? {
        let done = expectation(description: "detail")
        var out: FlagDetail?
        f.detail(key: key, context: FlagContext(userId: "u-1")) {
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

    func testAnUnknownKeyYieldsNil() {
        let (f, _) = flags([.json(200, #"{"choices":[]}"#)])
        XCTAssertNil(detail(f, "never_created"))
    }

    func testANon2xxYieldsNil() {
        let (f, _) = flags([.status(500)])
        XCTAssertNil(detail(f, "k"))
    }

    func testAnUnreachableServiceYieldsNil() {
        let (f, _) = flags([.offline()])
        XCTAssertNil(detail(f, "k"))
    }

    func testAMalformedBodyYieldsNil() {
        let (f, _) = flags([.json(200, "not json at all")])
        XCTAssertNil(detail(f, "k"))
    }

    func testTheRequestNamesTheKeyAndCarriesTheIdentifier() {
        let (f, session) = flags([.json(200, #"{"choices":[]}"#)])
        _ = detail(f, "checkout_v2")
        let body = session.bodies.first
        XCTAssertEqual(body?["names"] as? [String], ["checkout_v2"])
        XCTAssertEqual((body?["identification"] as? [String: Any])?["userId"] as? String, "u-1")
    }

    func testAllFlagsAsksForEveryKeyRatherThanNamingOne() {
        // `names` absent is what makes the serving query return everything; sending an empty
        // array instead would filter to nothing and look like "no flags exist".
        let (f, session) = flags([.json(200, #"{"choices":[]}"#)])
        let done = expectation(description: "all")
        f.all(context: FlagContext(userId: "u-1")) { _ in done.fulfill() }
        wait(for: [done], timeout: 2)
        XCTAssertNil(session.bodies.first?["names"])
    }
}
