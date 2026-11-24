import XCTest

@testable import Intempt

/// "Session end" and the session figures it carries.
///
/// The iOS source provisions a SessionEnd collection whose schema requires
/// `sessionDuration` and `sessionEventCount`. Neither can be reconstructed after
/// the session id has rolled, so both have to be tracked while the session runs
/// — which is the whole reason this state exists.
final class SessionLifecycleTests: IntemptTestCase {

    private var now = Date(timeIntervalSince1970: 1_700_000_000)

    private func makeIdentity() -> IdentityManager {
        IdentityManager(namespace: "session", store: defaults, clock: { self.now })
    }

    // MARK: - Duration and count

    func testEventsAreCountedAgainstTheSession() {
        let identity = makeIdentity()
        XCTAssertEqual(identity.sessionEventCount, 0)

        identity.countEvent()
        identity.countEvent()
        XCTAssertEqual(identity.sessionEventCount, 2)
    }

    /// An idle rollover must hand back the OUTGOING session, not the new one.
    /// Stamping the end event with the new id attributes the duration to a
    /// session that just started.
    func testIdleRolloverCapturesTheOutgoingSession() {
        let identity = makeIdentity()
        let original = identity.sessionId

        identity.countEvent()
        identity.countEvent()
        identity.countEvent()

        now = now.addingTimeInterval(60)
        identity.recordActivity()

        // Past the idle window.
        now = now.addingTimeInterval(IdentityManager.sessionTimeout + 1)
        let rolled = identity.sessionId
        XCTAssertNotEqual(rolled, original, "the session must have rolled")

        let ended = identity.takeEndedSession()
        XCTAssertNotNil(ended)
        XCTAssertEqual(ended?.sessionId, original, "the ENDED session, not the new one")
        XCTAssertEqual(ended?.eventCount, 3)
        XCTAssertEqual(ended?.duration ?? 0, 60, accuracy: 0.5, "measured to last activity")
    }

    /// Handed over exactly once, so a session end is not emitted repeatedly.
    func testEndedSessionIsHandedOverOnlyOnce() {
        let identity = makeIdentity()
        now = now.addingTimeInterval(IdentityManager.sessionTimeout + 1)
        _ = identity.sessionId

        XCTAssertNotNil(identity.takeEndedSession())
        XCTAssertNil(identity.takeEndedSession(), "a second read must be empty")
    }

    func testCountResetsForTheNewSession() {
        let identity = makeIdentity()
        identity.countEvent()
        identity.countEvent()

        now = now.addingTimeInterval(IdentityManager.sessionTimeout + 1)
        _ = identity.sessionId

        XCTAssertEqual(identity.sessionEventCount, 0, "the new session starts at zero")
    }

    /// Leaving the app IS the end of the session. Waiting for the idle timeout
    /// would report a duration that kept counting while the app was closed.
    func testClosingDeliberatelyEndsTheSessionImmediately() {
        let identity = makeIdentity()
        let original = identity.sessionId
        identity.countEvent()

        now = now.addingTimeInterval(120)
        let ended = identity.closeCurrentSession()

        XCTAssertEqual(ended.sessionId, original)
        XCTAssertEqual(ended.eventCount, 1)
        XCTAssertEqual(ended.duration, 120, accuracy: 0.5)
        XCTAssertNotEqual(identity.sessionId, original, "a fresh session follows")
        XCTAssertEqual(identity.sessionEventCount, 0)
    }

    func testLogOutClearsSessionState() {
        let identity = makeIdentity()
        identity.countEvent()
        now = now.addingTimeInterval(IdentityManager.sessionTimeout + 1)
        _ = identity.sessionId

        identity.logOut()

        XCTAssertEqual(identity.sessionEventCount, 0)
        XCTAssertNil(
            identity.takeEndedSession(),
            "a rolled session must not survive a logout and be attributed to the next user")
    }

    // MARK: - The emitted event

    func testSessionEndIsEnqueuedWithDurationAndCount() throws {
        let instance = try IntemptInstance.makeForTesting(
            store: defaults, databaseDirectory: tempDir,
            automaticEvents: AutomaticEventOptions(sessions: true))

        XCTAssertTrue(instance.track(eventTitle: "First"))
        instance.automatic.endSession(
            IdentityManager.EndedSession(
                sessionId: "se_original", duration: 95.5, eventCount: 7))

        let names = instance.db.read(.events, limit: 10).compactMap {
            (JSONHandler.deserializeData($0.data) as? [String: Any])?["name"] as? String
        }
        XCTAssertTrue(names.contains("Session end"), "got \(names)")

        let entry = instance.db.read(.events, limit: 10)
            .compactMap { JSONHandler.deserializeData($0.data) as? [String: Any] }
            .first { $0["name"] as? String == "Session end" }!
        let payload = (entry["payload"] as! [[String: Any]])[0]

        // The ENDED session's id, not the current one.
        XCTAssertEqual(payload["sessionId"] as? String, "se_original")
        XCTAssertEqual(payload["eventId"] as? String, "se_original")

        // SessionEnd.json puts these under `data`, unlike SessionStart which
        // uses `sessionAttributes`.
        let data = payload["data"] as! [String: Any]
        XCTAssertEqual(data["sessionDuration"] as? Double, 95.5)
        XCTAssertEqual(data["sessionEventCount"] as? Double, 7, "schema types the count as double")
        XCTAssertEqual(data["sessionEndEventName"] as? String, "Session end")
        XCTAssertNil(payload["sessionAttributes"], "that is SessionStart's shape, not this one")

        // userAttributes stays the two-name set the schema allows.
        XCTAssertEqual((payload["userAttributes"] as? [String: Any])?.count, 2)
    }

    /// Typeless, like session start — see SessionModel.
    func testSessionEndEntryOmitsTheTypeField() {
        let model = SessionEndModel(
            sessionId: "se_1", profileId: "pr_1", name: EventNames.sessionEnd,
            data: ["sessionDuration": 1.0], userAttributes: nil)

        let entry: [String: Any] = (model as IntemptModel).toEnvelopeEntry()
        XCTAssertNil(entry["type"])
        XCTAssertEqual(entry["name"] as? String, "Session end")
    }

    func testSessionEndRespectsOptOut() throws {
        let instance = try IntemptInstance.makeForTesting(
            store: defaults, databaseDirectory: tempDir,
            automaticEvents: AutomaticEventOptions(sessions: true))
        instance.optOut()

        instance.automatic.endSession(
            IdentityManager.EndedSession(sessionId: "se_x", duration: 1, eventCount: 1))
        XCTAssertEqual(instance.queuedEventCount(), 0)
    }

    /// An idle rollover mid-use must produce end-then-start, in that order.
    func testRolloverEmitsEndBeforeTheNextStart() throws {
        let instance = try IntemptInstance.makeForTesting(
            store: defaults, databaseDirectory: tempDir,
            automaticEvents: AutomaticEventOptions(sessions: true))

        XCTAssertTrue(instance.track(eventTitle: "Before"))
        let firstSession = instance.getSessionId()

        // Force a rollover through the real identity manager.
        instance.identity.forceRollForTesting()
        XCTAssertTrue(instance.track(eventTitle: "After"))
        XCTAssertNotEqual(instance.getSessionId(), firstSession)

        let names = instance.db.read(.events, limit: 20).compactMap {
            (JSONHandler.deserializeData($0.data) as? [String: Any])?["name"] as? String
        }
        let endIndex = names.firstIndex(of: "Session end")
        let startIndices = names.indices.filter { names[$0] == "Session start" }

        XCTAssertNotNil(endIndex, "got \(names)")
        XCTAssertEqual(startIndices.count, 2, "one start per session: \(names)")
        XCTAssertLessThan(
            endIndex!, startIndices[1],
            "the end of session 1 must precede the start of session 2: \(names)")
    }

    /// INT-5603: the server writes session_end itself, with the source stamped. The copy this SDK
    /// sent carried no sourceId, so it showed as source -1 and keyed a phantom profile per session.
    func testIdleRolloverSendsNoSessionEnd() throws {
        let instance = try IntemptInstance.makeForTesting(
            store: defaults, databaseDirectory: tempDir,
            automaticEvents: AutomaticEventOptions(sessions: true))

        XCTAssertTrue(instance.track(eventTitle: "Before"))
        instance.identity.forceRollForTesting()
        XCTAssertTrue(instance.track(eventTitle: "After"))

        let names = instance.db.read(.events, limit: 20).compactMap {
            (JSONHandler.deserializeData($0.data) as? [String: Any])?["name"] as? String
        }
        XCTAssertEqual(names, ["Session start", "Before", "Session start", "After"])
    }

    // MARK: - Sessions an app never tracks into (INT-5604)

    private func post(_ transition: AppTransition) throws {
        guard let name = AppLifecycle.notificationMap.first(where: { $0.1 == transition })?.0 else {
            throw XCTSkip("this platform reports no app transitions")
        }
        NotificationCenter.default.post(name: name, object: nil)
    }

    /// Claimed rows included: the background handler starts a flush, and a flush claims what it reads.
    private func queuedEvents(_ instance: IntemptInstance) -> [[String: Any]] {
        let rows = instance.db.read(.events, limit: 100) + instance.db.read(.events, limit: 100, flag: true)
        // A flush can claim a row between the two reads, so the same row may come back twice.
        var seen = Set<Int32>()
        return rows.filter { seen.insert($0.id).inserted }.sorted { $0.id < $1.id }.compactMap {
            JSONHandler.deserializeData($0.data) as? [String: Any]
        }
    }

    private func names(_ events: [[String: Any]]) -> [String] {
        events.compactMap { $0["name"] as? String }
    }

    private func sessionId(of entry: [String: Any]) -> String? {
        (entry["payload"] as? [[String: Any]])?.first?["sessionId"] as? String
    }

    /// Deliveries are held, so the flush a background starts cannot delete the rows under the assertions.
    private func makeLifecycleInstance() throws -> IntemptInstance {
        let session = MockSession()
        session.deferCompletions = true
        return try IntemptInstance.makeForTesting(
            store: defaults, databaseDirectory: tempDir, network: Network(session: session),
            automaticEvents: AutomaticEventOptions(sessions: true))
    }

    /// An app that only calls `initialize` still has a session. The launch's own foreground
    /// transition and the first tracked event belong to that session and must not start another.
    func testInitializeStartsASessionWithoutATrackedEvent() throws {
        let instance = try IntemptInstance.initialize(
            apiKey: "pfx.secret", orgId: "o", projectId: "p", sourceId: "s",
            instanceName: "int5604-\(UUID().uuidString)")
        defer { instance.db.deleteAll(.events) }

        let atLaunch = queuedEvents(instance)
        XCTAssertEqual(names(atLaunch), ["Session start"])
        XCTAssertEqual(atLaunch.first.flatMap(sessionId(of:)), instance.getSessionId())

        try post(.foreground)
        XCTAssertTrue(instance.track(eventTitle: "First"))
        XCTAssertEqual(
            names(queuedEvents(instance)), ["Session start", "First"],
            "one start per session, not one per foreground or per event")
    }

    /// The issue's repro: opened, backgrounded, reopened, nothing tracked.
    func testReturningToTheForegroundStartsTheNextSessionAfterTheEnd() throws {
        let instance = try makeLifecycleInstance()

        try post(.foreground)
        try post(.background)
        try post(.foreground)
        waitUntil("a start for the reopened session") {
            self.names(self.queuedEvents(instance)).filter { $0 == "Session start" }.count == 2
        }

        let events = queuedEvents(instance)
        XCTAssertEqual(names(events), ["Session start", "Session end", "Session start"])
        guard events.count == 3 else { return }
        let first = sessionId(of: events[0])
        XCTAssertNotNil(first)
        XCTAssertEqual(sessionId(of: events[1]), first, "the end closes the session that started")
        XCTAssertNotEqual(sessionId(of: events[2]), first)
        XCTAssertEqual(sessionId(of: events[2]), instance.getSessionId())
    }

    /// A terminate can follow a background with no foreground between them. The background
    /// already closed the session; the one it opened never started, so it gets no end.
    func testASessionThatNeverStartedSendsNoEnd() throws {
        let instance = try makeLifecycleInstance()

        try post(.foreground)
        try post(.background)
        try post(.terminate)
        try post(.foreground)
        waitUntil("a start for the reopened session") {
            self.names(self.queuedEvents(instance)).filter { $0 == "Session start" }.count == 2
        }

        XCTAssertEqual(
            names(queuedEvents(instance)), ["Session start", "Session end", "Session start"],
            "exactly one end, for the one session that started")
    }

    func testForegroundSessionStartRespectsOptOut() throws {
        let instance = try makeLifecycleInstance()
        instance.optOut()

        try post(.foreground)
        try post(.background)
        try post(.foreground)
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))

        XCTAssertEqual(queuedEvents(instance).count, 0)
    }
}
