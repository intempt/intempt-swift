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

    // MARK: detail

    func testDetailCarriesValueReasonAndVariant() {
        let detail = FlagDetail(value: .bool(true), reason: .targeted, variant: "B")
        XCTAssertEqual(detail.value, .bool(true))
        XCTAssertEqual(detail.reason, .targeted)
        XCTAssertEqual(detail.variant, "B")
    }

    func testAHoldoutIsAnAnsweredEvaluation() {
        // Before the reason existed, a held-back person and a failed request were both an absent
        // entry and a caller could not tell them apart.
        let detail = FlagDetail(value: nil, reason: .holdout)
        XCTAssertEqual(detail.reason, .holdout)
        XCTAssertNil(detail.variant)
    }
}
