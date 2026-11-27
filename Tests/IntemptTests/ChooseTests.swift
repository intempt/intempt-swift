import XCTest

@testable import Intempt

/// `choose()` over choose-api (D13), ported from intempt-node tests/choose.test.ts in spirit.
final class ChooseTests: XCTestCase {

    private var bodies: [[String: Any]] = []
    private var reply: FlagReply = .answered(Data(#"{"choices":[]}"#.utf8))

    private func makeChoose(sourceId: String = "s") -> Choose {
        Choose(
            deps: Choose.Deps(
                sourceId: sourceId, device: "mobile",
                post: { [unowned self] body, done in
                    self.bodies.append(body)
                    done(self.reply)
                }))
    }

    private func choose(
        _ chooser: Choose? = nil,
        context: FlagContext = FlagContext(userId: "u-1", profileId: "p-1"),
        names: [String]? = ["hero"],
        groups: [String]? = nil,
        disableExposure: Bool = false
    ) -> [Choice]? {
        var out: [Choice]?
        (chooser ?? makeChoose()).choose(
            context: context, sessionId: "se-1", names: names, groups: groups,
            disableExposure: disableExposure
        ) { out = $0 }
        return out
    }

    func testTheRequestCarriesIdentityNamesGroupsDeviceAndSession() {
        _ = choose(names: ["hero"], groups: ["home"])
        let body = bodies.first
        XCTAssertEqual(body?["names"] as? [String], ["hero"])
        XCTAssertEqual(body?["groups"] as? [String], ["home"])
        XCTAssertEqual(body?["device"] as? String, "mobile")
        XCTAssertEqual(body?["sessionId"] as? String, "se-1")
        let identification = body?["identification"] as? [String: Any]
        XCTAssertEqual(identification?["userId"] as? String, "u-1")
        XCTAssertEqual(identification?["profileId"] as? String, "p-1")
        XCTAssertEqual(identification?["sourceId"] as? String, "s")
        XCTAssertNil(body?["exposure"], "absent is the service's record default")
    }

    func testOmittedNamesAndGroupsAreNotSentAsEmptyLists() {
        _ = choose(names: nil, groups: nil)
        XCTAssertNil(bodies.first?["names"])
        XCTAssertNil(bodies.first?["groups"])
    }

    func testDisableExposureSendsExposureFalse() {
        _ = choose(disableExposure: true)
        XCTAssertEqual(bodies.first?["exposure"] as? Bool, false)
    }

    func testRowsAreReadWithTheirOptionalFields() {
        reply = .answered(
            Data(
                #"{"choices":[{"name":"hero","group":"home","body":{"title":"Hi"},"experienceId":7,"variantId":9,"reason":"targeted"},{"name":"bare"},{"group":"no-name"},{"name":"odd","group":3,"experienceId":"7"}]}"#
                    .utf8))
        XCTAssertEqual(
            choose(),
            [
                Choice(
                    name: "hero", group: "home", body: .object(["title": .string("Hi")]),
                    experienceId: 7, variantId: 9, reason: "targeted"),
                Choice(name: "bare", body: .null),
                Choice(name: "odd", body: .null),
            ])
    }

    func testAFailedRequestIsNoChoices() {
        for failure: FlagReply in [
            .failed(.server, status: 500), .failed(.auth, status: 401), .failed(.network, status: nil),
            .answered(Data("nope".utf8)), .answered(Data(#"{"flags":[]}"#.utf8)), .answered(nil),
        ] {
            reply = failure
            XCTAssertEqual(choose(), [], "\(failure)")
        }
    }

    func testAMalformedCallIsNoChoicesWithoutARequest() {
        XCTAssertEqual(choose(names: ["bad name"]), [])
        XCTAssertEqual(choose(names: [""]), [])
        XCTAssertEqual(choose(groups: ["a.b"]), [])
        XCTAssertEqual(choose(context: FlagContext()), [])
        XCTAssertEqual(choose(makeChoose(sourceId: ""), context: FlagContext(profileId: "p-1")), [])
        XCTAssertTrue(bodies.isEmpty)
    }

    func testAUserIdAloneIsEnoughIdentity() {
        _ = choose(makeChoose(sourceId: ""), context: FlagContext(userId: "u-1"))
        XCTAssertEqual(bodies.count, 1)
    }
}
