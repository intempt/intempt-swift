import XCTest

@testable import Intempt

final class AutomaticEventsTests: IntemptTestCase {

    private struct Emission {
        let name: String
        let data: [String: IntemptType]?
        let userAttributes: [String: IntemptType]?
    }

    private var emissions: [Emission] = []

    private func makeTracker(
        options: AutomaticEvents.Options,
        namespace: String = "auto"
    ) -> AutomaticEvents {
        AutomaticEvents(namespace: namespace, store: defaults, options: options) {
            [self] name, data, userAttributes in
            emissions.append(Emission(name: name, data: data, userAttributes: userAttributes))
        }
    }

    override func setUp() {
        super.setUp()
        emissions = []
        AutomaticProperties.reset()
    }

    // MARK: - Sessions

    func testSessionStartEmittedOncePerSession() {
        let tracker = makeTracker(options: .init(sessions: true))

        tracker.noteActivity(sessionId: "se_1")
        tracker.noteActivity(sessionId: "se_1")
        tracker.noteActivity(sessionId: "se_1")
        XCTAssertEqual(emissions.count, 1, "one session start, not one per event")

        tracker.noteActivity(sessionId: "se_2")
        XCTAssertEqual(emissions.count, 2, "a new session id starts a new session")
    }

    func testSessionStartUsesTheIntemptJSName() {
        let tracker = makeTracker(options: .init(sessions: true))
        tracker.noteActivity(sessionId: "se_1")
        XCTAssertEqual(emissions[0].name, "Session start")
    }

    /// Device facts belong on the profile, not stamped onto every event the way
    /// Mixpanel does. intemptjs puts them in `userAttributes`.
    func testDeviceFactsTravelAsUserAttributesNotEventData() {
        let tracker = makeTracker(options: .init(sessions: true))
        tracker.noteActivity(sessionId: "se_1")

        let attributes = emissions[0].userAttributes
        XCTAssertNotNil(attributes)
        XCTAssertNotNil(attributes?["platform"])
        XCTAssertNotNil(attributes?["deviceType"])
        XCTAssertNotNil(attributes?["deviceModel"])
        XCTAssertEqual(attributes?["sdkName"] as? String, "intempt-swift")

        XCTAssertNil(emissions[0].data?["platform"], "device facts must not be event data")
        XCTAssertNil(emissions[0].data?["deviceModel"])
    }

    func testSessionsCanBeDisabled() {
        let tracker = makeTracker(options: .init(sessions: false))
        tracker.noteActivity(sessionId: "se_1")
        XCTAssertTrue(emissions.isEmpty)
    }

    // MARK: - Version changes

    func testFirstLaunchEmitsInstalledNotUpdated() {
        let tracker = makeTracker(options: .init(sessions: false, versionChanges: true))
        tracker.checkVersion()

        XCTAssertEqual(emissions.count, 1)
        XCTAssertEqual(emissions[0].name, "Application Installed")
        XCTAssertNil(emissions[0].data?["previousVersion"])
    }

    func testSameVersionOnSecondLaunchEmitsNothing() {
        makeTracker(options: .init(sessions: false, versionChanges: true)).checkVersion()
        emissions = []

        // A second tracker over the same store models a relaunch.
        makeTracker(options: .init(sessions: false, versionChanges: true)).checkVersion()
        XCTAssertTrue(emissions.isEmpty, "installed must not repeat on every launch")
    }

    func testVersionChangeEmitsUpdatedWithBothVersions() {
        let key = "com.intempt.lastSeenVersion.auto"
        defaults.set("0.9.0", forKey: key)

        let tracker = makeTracker(options: .init(sessions: false, versionChanges: true))
        tracker.checkVersion()

        XCTAssertEqual(emissions.count, 1)
        XCTAssertEqual(emissions[0].name, "Application Updated")
        XCTAssertEqual(emissions[0].data?["previousVersion"] as? String, "0.9.0")
        XCTAssertNotNil(emissions[0].data?["currentVersion"])
    }

    /// Two instances in one app must not each claim to have seen the install.
    /// Upstream keys this globally.
    func testVersionStateIsNamespacedPerInstance() {
        makeTracker(options: .init(sessions: false, versionChanges: true), namespace: "a")
            .checkVersion()
        XCTAssertEqual(emissions.count, 1)

        makeTracker(options: .init(sessions: false, versionChanges: true), namespace: "b")
            .checkVersion()
        XCTAssertEqual(emissions.count, 2, "a second namespace has its own first launch")

        emissions = []
        makeTracker(options: .init(sessions: false, versionChanges: true), namespace: "a")
            .checkVersion()
        XCTAssertTrue(emissions.isEmpty, "namespace 'a' already recorded its version")
    }

    func testVersionChangesDisabledByDefault() {
        let tracker = makeTracker(options: .default)
        tracker.checkVersion()
        XCTAssertTrue(emissions.isEmpty, "an SDK must not emit events nobody asked for")
    }

    // MARK: - App state

    func testAppStateTransitions() {
        let tracker = makeTracker(options: .init(sessions: false, appStateChanges: true))
        tracker.note(.foreground)
        tracker.note(.background)
        XCTAssertEqual(emissions.map(\.name), ["Application Opened", "Application Backgrounded"])
    }

    /// The process is going away; an event enqueued here would not flush.
    func testTerminateEmitsNothing() {
        let tracker = makeTracker(options: .init(sessions: false, appStateChanges: true))
        tracker.note(.terminate)
        XCTAssertTrue(emissions.isEmpty)
    }

    func testAppStateDisabledByDefault() {
        let tracker = makeTracker(options: .default)
        tracker.note(.foreground)
        XCTAssertTrue(emissions.isEmpty)
    }

    // MARK: - Integration through IntemptInstance

    func testTrackingEmitsSessionStartAheadOfTheEvent() throws {
        let instance = try IntemptInstance.makeForTesting(
            store: defaults, databaseDirectory: tempDir,
            automaticEvents: AutomaticEventOptions(sessions: true))

        XCTAssertTrue(instance.track(eventTitle: "Checkout"))
        XCTAssertEqual(instance.queuedEventCount(), 2, "session start + the event")

        let rows = instance.db.read(.events, limit: 10)
        let names = rows.compactMap {
            (JSONHandler.deserializeData($0.data) as? [String: Any])?["name"] as? String
        }
        XCTAssertEqual(names, ["Session start", "Checkout"], "session start comes first")
    }

    /// The session-start emission re-enters the instance's enqueue path. Doing
    /// that inside the serial state queue deadlocks on the first event of every
    /// session — this test is the regression guard.
    func testFirstEventOfASessionDoesNotDeadlock() throws {
        let instance = try IntemptInstance.makeForTesting(
            store: defaults, databaseDirectory: tempDir,
            automaticEvents: AutomaticEventOptions(sessions: true))

        let done = expectation(description: "track returns")
        DispatchQueue.global().async {
            _ = instance.track(eventTitle: "First")
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
    }

    func testSessionStartIsNotEmittedWhenOptedOut() throws {
        let instance = try IntemptInstance.makeForTesting(
            store: defaults, databaseDirectory: tempDir,
            automaticEvents: AutomaticEventOptions(sessions: true))
        instance.optOut()

        XCTAssertFalse(instance.track(eventTitle: "Checkout"))
        XCTAssertEqual(instance.queuedEventCount(), 0, "opt-out gates automatic events too")
    }
}
