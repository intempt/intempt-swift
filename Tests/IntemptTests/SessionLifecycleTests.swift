import XCTest

@testable import Intempt

/// Session rollover and "Session start". The SDK sends no "Session end": the server writes
/// session_end itself (INT-5603).
final class SessionLifecycleTests: IntemptTestCase {

    private var now = Date(timeIntervalSince1970: 1_700_000_000)

    private func makeIdentity() -> IdentityManager {
        IdentityManager(namespace: "session", store: defaults, clock: { self.now })
    }

    func testIdleRolloverStartsAFreshSession() {
        let identity = makeIdentity()
        let original = identity.sessionId

        now = now.addingTimeInterval(IdentityManager.sessionTimeout + 1)
        XCTAssertNotEqual(identity.sessionId, original)
    }

    func testClosingDeliberatelyStartsAFreshSession() {
        let identity = makeIdentity()
        let original = identity.sessionId

        identity.closeCurrentSession()
        XCTAssertNotEqual(identity.sessionId, original)
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
    func testReturningToTheForegroundStartsTheNextSession() throws {
        let instance = try makeLifecycleInstance()

        try post(.foreground)
        try post(.background)
        try post(.foreground)
        waitUntil("a start for the reopened session") {
            self.names(self.queuedEvents(instance)).filter { $0 == "Session start" }.count == 2
        }

        let events = queuedEvents(instance)
        XCTAssertEqual(names(events), ["Session start", "Session start"])
        guard events.count == 2 else { return }
        let first = sessionId(of: events[0])
        XCTAssertNotNil(first)
        XCTAssertNotEqual(sessionId(of: events[1]), first)
        XCTAssertEqual(sessionId(of: events[1]), instance.getSessionId())
    }

    /// A terminate can follow a background with no foreground between them; the reopen still
    /// starts exactly one session.
    func testBackgroundThenTerminateStartsOneNextSession() throws {
        let instance = try makeLifecycleInstance()

        try post(.foreground)
        try post(.background)
        try post(.terminate)
        try post(.foreground)
        waitUntil("a start for the reopened session") {
            self.names(self.queuedEvents(instance)).filter { $0 == "Session start" }.count == 2
        }

        XCTAssertEqual(
            names(queuedEvents(instance)), ["Session start", "Session start"])
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
