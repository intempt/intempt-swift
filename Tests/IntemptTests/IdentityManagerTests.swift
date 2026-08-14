import XCTest

@testable import Intempt

final class IdentityManagerTests: XCTestCase {

    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        try super.setUpWithError()
        suiteName = "intempt-identity-tests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName)
        try super.tearDownWithError()
    }

    // MARK: profileId

    func testProfileIdPersistsAcrossInstances() {
        let a = IdentityManager(namespace: "ns", store: defaults)
        let first = a.profileId
        XCTAssertTrue(first.hasPrefix("pr_"))

        let b = IdentityManager(namespace: "ns", store: defaults)
        XCTAssertEqual(b.profileId, first, "anonymous identity must survive relaunch")
    }

    func testDifferentNamespacesGetDifferentProfiles() {
        let a = IdentityManager(namespace: "one", store: defaults)
        let b = IdentityManager(namespace: "two", store: defaults)
        XCTAssertNotEqual(a.profileId, b.profileId)
    }

    /// Android's logOut() restores the same profileId, so the next user on a
    /// shared device inherits the previous identity. Must not happen here.
    func testLogOutRotatesProfileIdAndPersistsTheNewOne() {
        let m = IdentityManager(namespace: "ns", store: defaults)
        let before = m.profileId
        m.logOut()
        let after = m.profileId

        XCTAssertNotEqual(before, after, "logOut must rotate the anonymous identity")

        let reopened = IdentityManager(namespace: "ns", store: defaults)
        XCTAssertEqual(reopened.profileId, after, "the rotated id must be the persisted one")
        XCTAssertNotEqual(reopened.profileId, before)
    }

    func testLogOutAlsoRotatesSessionAndPage() {
        let m = IdentityManager(namespace: "ns", store: defaults)
        let s = m.sessionId
        let p = m.pageId
        m.logOut()
        XCTAssertNotEqual(m.sessionId, s)
        XCTAssertNotEqual(m.pageId, p)
    }

    // MARK: sessionId

    /// F-53: the old SDK minted a fresh UUID on every getSessionId() call and
    /// never stored it, so no two reads agreed.
    func testSessionIdIsStableAcrossReads() {
        let m = IdentityManager(namespace: "ns", store: defaults)
        XCTAssertEqual(m.sessionId, m.sessionId)
        XCTAssertEqual(m.sessionId, m.sessionId)
    }

    func testSessionRollsOverAfterIdleTimeout() {
        var now = Date()
        let m = IdentityManager(namespace: "ns", store: defaults, clock: { now })
        let first = m.sessionId

        now = now.addingTimeInterval(IdentityManager.sessionTimeout + 1)
        let second = m.sessionId

        XCTAssertNotEqual(first, second, "session must roll after the idle window")
    }

    func testSessionDoesNotRollBeforeTimeout() {
        var now = Date()
        let m = IdentityManager(namespace: "ns", store: defaults, clock: { now })
        let first = m.sessionId

        now = now.addingTimeInterval(IdentityManager.sessionTimeout - 60)
        XCTAssertEqual(m.sessionId, first)
    }

    /// F-51: typing did not count as activity in the old SDK, so long-form
    /// text entry tripped a rollover mid-input.
    func testActivityKeepsSessionAliveIndefinitely() {
        var now = Date()
        let m = IdentityManager(namespace: "ns", store: defaults, clock: { now })
        let first = m.sessionId

        // Simulate 90 minutes of continuous typing, active every 5 minutes.
        for _ in 0..<18 {
            now = now.addingTimeInterval(300)
            m.recordActivity()
        }

        XCTAssertEqual(m.sessionId, first, "continuous activity must not roll the session")
    }

    // MARK: pageId

    func testNewPageChangesPageIdButNotSession() {
        let m = IdentityManager(namespace: "ns", store: defaults)
        let s = m.sessionId
        let p = m.pageId
        m.newPage()
        XCTAssertNotEqual(m.pageId, p)
        XCTAssertEqual(m.sessionId, s)
    }

    // MARK: envelopes

    func testEnvelopeCarriesCurrentIdentity() {
        let m = IdentityManager(namespace: "ns", store: defaults)
        let e = m.makeEnvelope()
        XCTAssertEqual(e.profileId, m.profileId)
        XCTAssertEqual(e.sessionId, m.sessionId)
        XCTAssertEqual(e.pageId, m.pageId)
        XCTAssertTrue(e.eventId.hasPrefix("ev_"))
    }

    func testEachEnvelopeGetsAFreshEventId() {
        let m = IdentityManager(namespace: "ns", store: defaults)
        XCTAssertNotEqual(m.makeEnvelope().eventId, m.makeEnvelope().eventId)
    }

    /// Every envelope satisfies ingestion's identity requirement.
    func testEnvelopeAlwaysSatisfiesIdentityRule() throws {
        let m = IdentityManager(namespace: "ns", store: defaults)
        let model = TrackModel(envelope: m.makeEnvelope(), name: "T", data: nil)
        XCTAssertNoThrow(try PayloadValidator.validate(model.toPayload()))
    }

    // MARK: concurrency

    func testConcurrentAccessIsStable() {
        let m = IdentityManager(namespace: "ns", store: defaults)
        let group = DispatchGroup()
        for _ in 0..<200 {
            group.enter()
            DispatchQueue.global().async {
                _ = m.makeEnvelope()
                m.recordActivity()
                group.leave()
            }
        }
        group.wait()
        XCTAssertTrue(m.profileId.hasPrefix("pr_"))
    }
}
