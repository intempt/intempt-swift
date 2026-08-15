import XCTest

@testable import Intempt

/// One test per public method, plus the gating invariants.
final class IntemptInstanceTests: XCTestCase {

    private var tmp: URL!
    private var suite: String!
    private var defaults: UserDefaults!
    private var sdk: IntemptInstance!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("inst-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        suite = "intempt-inst-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
        sdk = try IntemptInstance.makeForTesting(store: defaults, databaseDirectory: tmp)
    }

    override func tearDownWithError() throws {
        sdk = nil
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: tmp)
        IntemptInstance.removeAllInstances()
        try super.tearDownWithError()
    }

    // MARK: - initialize

    func testInitializeRejectsMalformedAPIKey() {
        XCTAssertThrowsError(
            try IntemptInstance.initialize(
                apiKey: "nodots", orgId: "a", projectId: "b", sourceId: "c",
                instanceName: "bad-key")
        ) { XCTAssertEqual($0 as? IntemptError, .malformedAPIKey(length: 6)) }
    }

    /// F-04: the old SDK logged an error and carried on, because NSAssert
    /// compiles out in Release. It then POSTed to ".../(null)/projects/(null)".
    func testInitializeThrowsOnBlankIdentifiers() {
        for (org, project, source, field) in [
            ("", "p", "s", "orgId"), ("o", "", "s", "projectId"), ("o", "p", "", "sourceId"),
            ("  ", "p", "s", "orgId"),
        ] {
            XCTAssertThrowsError(
                try IntemptInstance.initialize(
                    apiKey: "pfx.secret", orgId: org, projectId: project, sourceId: source,
                    instanceName: "blank-\(field)-\(UUID().uuidString)")
            ) { XCTAssertEqual($0 as? IntemptError, .missingConfiguration(field: field)) }
        }
    }

    func testInitializeIsIdempotentPerName() throws {
        let a = try IntemptInstance.initialize(
            apiKey: "pfx.secret", orgId: "o", projectId: "p", sourceId: "s",
            instanceName: "same")
        let b = try IntemptInstance.initialize(
            apiKey: "pfx.secret", orgId: "o", projectId: "p", sourceId: "s",
            instanceName: "same")
        XCTAssertTrue(a === b)
    }

    /// Regression for the old SDK's five unsafe check-then-create singletons.
    func testConcurrentInitializeReturnsOneInstance() {
        let name = "race-\(UUID().uuidString)"
        var ids = Set<ObjectIdentifier>()
        let lock = NSLock()
        let group = DispatchGroup()
        for _ in 0..<100 {
            group.enter()
            DispatchQueue.global().async {
                if let i = try? IntemptInstance.initialize(
                    apiKey: "pfx.secret", orgId: "o", projectId: "p", sourceId: "s",
                    instanceName: name)
                {
                    lock.lock()
                    ids.insert(ObjectIdentifier(i))
                    lock.unlock()
                }
                group.leave()
            }
        }
        group.wait()
        XCTAssertEqual(ids.count, 1, "concurrent initialize must yield exactly one instance")
    }

    func testMainInstanceAndNamedLookup() throws {
        _ = try IntemptInstance.initialize(
            apiKey: "pfx.secret", orgId: "o", projectId: "p", sourceId: "s")
        XCTAssertNotNil(IntemptInstance.mainInstance())
        XCTAssertNotNil(IntemptInstance.instance(named: "default"))
        XCTAssertNil(IntemptInstance.instance(named: "nope"))
    }

    // MARK: - Tracking entry points (one test each)

    func testTrack() {
        XCTAssertTrue(sdk.track(eventTitle: "Checkout", data: ["v": 1]))
        XCTAssertEqual(sdk.queuedEventCount(), 1)
    }

    func testIdentify() {
        XCTAssertTrue(sdk.identify(userId: "u1", userAttributes: ["plan": "pro"]))
        XCTAssertEqual(sdk.queuedEventCount(), 1)
    }

    func testGroup() {
        XCTAssertTrue(sdk.group(accountId: "acc1", accountAttributes: ["seats": 10]))
        XCTAssertEqual(sdk.queuedEventCount(), 1)
    }

    func testAlias() {
        XCTAssertTrue(sdk.alias(userId: "u1", anotherUserId: "u2"))
        XCTAssertEqual(sdk.queuedEventCount(), 1)
    }

    func testRecord() {
        XCTAssertTrue(
            sdk.record(
                eventTitle: "Signup", userId: "u1", accountId: "acc1",
                userAttributes: ["role": "admin"], accountAttributes: ["seats": 5]))
        XCTAssertEqual(sdk.queuedEventCount(), 1)
    }

    func testProductAdd() {
        XCTAssertTrue(sdk.productAdd(productId: "sku1", quantity: 2))
        XCTAssertEqual(sdk.queuedEventCount(), 1)
    }

    func testProductView() {
        XCTAssertTrue(sdk.productView(productId: "sku1"))
        XCTAssertEqual(sdk.queuedEventCount(), 1)
    }

    func testProductOrderedEnqueuesOnePerProduct() {
        XCTAssertTrue(
            sdk.productOrdered(products: [("sku1", 1), ("sku2", 3), ("sku3", 2)]))
        XCTAssertEqual(sdk.queuedEventCount(), 3)
    }

    // MARK: - Identity accessors

    func testProfileIdAndSessionIdAreStable() {
        XCTAssertTrue(sdk.getProfileId().hasPrefix("pr_"))
        XCTAssertEqual(sdk.getProfileId(), sdk.getProfileId())
        XCTAssertEqual(sdk.getSessionId(), sdk.getSessionId())
        XCTAssertFalse(sdk.sdkVersion.isEmpty)
    }

    // MARK: - Opt out / in

    func testOptOutStopsCollection() {
        sdk.optOut()
        XCTAssertTrue(sdk.hasOptedOut())
        XCTAssertFalse(sdk.isOptedIn())
        XCTAssertFalse(sdk.track(eventTitle: "blocked"))
        XCTAssertEqual(sdk.queuedEventCount(), 0)
    }

    /// intemptjs only sets a flag, leaving queued events to upload after the
    /// user has objected. A purge is required.
    func testOptOutPurgesAlreadyQueuedEvents() {
        sdk.track(eventTitle: "a")
        sdk.track(eventTitle: "b")
        sdk.identify(userId: "u1")
        XCTAssertEqual(sdk.queuedEventCount(), 3)

        sdk.optOut()

        XCTAssertEqual(sdk.queuedEventCount(), 0, "opt-out must discard collected data")
    }

    func testOptOutRotatesIdentity() {
        let before = sdk.getProfileId()
        sdk.optOut()
        XCTAssertNotEqual(sdk.getProfileId(), before)
    }

    func testOptInResumesCollection() {
        sdk.optOut()
        sdk.optIn()
        XCTAssertTrue(sdk.isOptedIn())
        XCTAssertTrue(sdk.track(eventTitle: "allowed"))
        XCTAssertEqual(sdk.queuedEventCount(), 1)
    }

    /// Every mutating entry point must respect the gate, not just track().
    func testOptOutGatesEverySurface() {
        sdk.optOut()
        XCTAssertFalse(sdk.track(eventTitle: "x"))
        XCTAssertFalse(sdk.identify(userId: "u"))
        XCTAssertFalse(sdk.group(accountId: "a"))
        XCTAssertFalse(sdk.alias(userId: "u", anotherUserId: "v"))
        XCTAssertFalse(sdk.record(eventTitle: "r", userId: "u"))
        XCTAssertFalse(sdk.productAdd(productId: "s", quantity: 1))
        XCTAssertFalse(sdk.productView(productId: "s"))
        XCTAssertFalse(sdk.productOrdered(products: [("s", 1)]))
        XCTAssertEqual(sdk.queuedEventCount(), 0)
    }

    // MARK: - Consent (F-42)

    /// The old SDK recorded the answer and gated nothing.
    func testConsentRejectGatesAndPurges() {
        sdk.track(eventTitle: "before")
        sdk.track(eventTitle: "also-before")
        XCTAssertEqual(sdk.queuedEventCount(), 2)

        XCTAssertTrue(sdk.consent(action: .reject, validUntil: 0))

        XCTAssertTrue(sdk.hasOptedOut(), "reject must gate collection")
        XCTAssertEqual(sdk.queuedEventCount(), 0, "reject must purge queued events")
        XCTAssertFalse(sdk.track(eventTitle: "after"), "further capture must be refused")
        XCTAssertEqual(sdk.queuedEventCount(), 0)
    }

    func testConsentAcceptOptsIn() {
        sdk.optOut()
        XCTAssertTrue(sdk.consent(action: .accept, validUntil: 0))
        XCTAssertTrue(sdk.isOptedIn())
        XCTAssertTrue(sdk.track(eventTitle: "allowed"))
    }

    /// A withdrawal must reach the server even though collection has stopped,
    /// and it goes to its own store, not the /track queue.
    func testConsentIsStoredSeparatelyAndSurvivesOptOut() {
        XCTAssertTrue(sdk.consent(action: .reject, validUntil: 0))
        XCTAssertEqual(sdk.queuedConsentCount(), 1, "the consent record itself must persist")
        XCTAssertEqual(sdk.queuedEventCount(), 0)
    }

    func testConsentCarriesPlatformSource() throws {
        sdk.consent(action: .accept, validUntil: 123, email: "a@b.com", category: "marketing")
        let rows = sdk.db.read(.consents, limit: 1)
        let payload = try XCTUnwrap(
            JSONHandler.deserializeData(rows[0].data) as? [String: Any])
        XCTAssertEqual(payload["source"] as? String, IntemptInstance.platformName)
        XCTAssertNotEqual(payload["source"] as? String, "web")
        XCTAssertEqual(payload["email"] as? String, "a@b.com")
        XCTAssertEqual(payload["category"] as? String, "marketing")
    }

    // MARK: - logOut / reset

    func testLogOutRotatesProfileButKeepsQueue() {
        sdk.track(eventTitle: "a")
        let before = sdk.getProfileId()
        sdk.logOut()
        XCTAssertNotEqual(sdk.getProfileId(), before)
        XCTAssertEqual(sdk.queuedEventCount(), 1, "logOut is not a purge")
    }

    func testResetRotatesProfileAndClearsQueue() {
        sdk.track(eventTitle: "a")
        let before = sdk.getProfileId()
        sdk.reset()
        XCTAssertNotEqual(sdk.getProfileId(), before)
        XCTAssertEqual(sdk.queuedEventCount(), 0)
    }

    // MARK: - Validation at the boundary

    func testInvalidPropertyValueIsRejected() {
        XCTAssertFalse(
            sdk.track(eventTitle: "bad", data: ["v": Double.nan]),
            "NaN must be refused at the entry point")
        XCTAssertEqual(sdk.queuedEventCount(), 0)
    }

    func testNestedInvalidPropertyValueIsRejected() {
        let nested: [String: IntemptType] = ["outer": ["inner": Double.nan] as [String: IntemptType]]
        XCTAssertFalse(sdk.track(eventTitle: "bad", data: nested))
        XCTAssertEqual(sdk.queuedEventCount(), 0)
    }

    func testValidDateAndURLAreAccepted() {
        XCTAssertTrue(
            sdk.track(eventTitle: "ok", data: ["at": Date(), "url": URL(string: "https://x.com")!]))
        XCTAssertEqual(sdk.queuedEventCount(), 1)
    }

    // MARK: - Queue ceiling

    func testQueueIsTrimmedToCeiling() {
        // Cheaper than 5000 real events: insert directly, then trim via a track.
        for i in 0..<(QueueConstants.maxQueueSize + 10) {
            sdk.db.insert(.events, data: Data("row-\(i)".utf8))
        }
        sdk.track(eventTitle: "triggers-trim")
        XCTAssertLessThanOrEqual(
            sdk.queuedEventCount(), QueueConstants.maxQueueSize,
            "queue must not grow past the ceiling")
    }

    // MARK: - Persistence

    func testQueuedEventsSurviveInstanceRecreation() throws {
        sdk.track(eventTitle: "persisted")
        let name = sdk.instanceName
        sdk = nil

        let reopened = try IntemptInstance.makeForTesting(
            instanceName: name, store: defaults, databaseDirectory: tmp)
        XCTAssertEqual(reopened.queuedEventCount(), 1)
    }

    // MARK: - Concurrency

    func testConcurrentTrackingLosesNothing() {
        let group = DispatchGroup()
        for i in 0..<300 {
            group.enter()
            DispatchQueue.global().async {
                self.sdk.track(eventTitle: "e-\(i)")
                group.leave()
            }
        }
        group.wait()
        XCTAssertEqual(sdk.queuedEventCount(), 300)
    }

    func testConcurrentTrackAndOptOutDoesNotCrash() {
        let group = DispatchGroup()
        for i in 0..<200 {
            group.enter()
            DispatchQueue.global().async {
                if i % 20 == 0 { self.sdk.optOut() } else { self.sdk.track(eventTitle: "e") }
                group.leave()
            }
        }
        group.wait()
        XCTAssertTrue(sdk.hasOptedOut())
    }
}
