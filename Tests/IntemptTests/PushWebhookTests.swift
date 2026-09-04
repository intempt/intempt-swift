import XCTest

#if canImport(UserNotifications)
    import UserNotifications
#endif

@testable import Intempt

/// The push webhook is the ONLY path that moves a send's own delivered/bounced/
/// opened numbers. Analytics events do not: `IosSourceInitialization` provisions
/// no push collection, so a "Push Opened" event has no column to land in.
final class PushWebhookTests: IntemptTestCase {

    override func tearDown() {
        PushAuthorization.reset()
        super.tearDown()
    }

    // MARK: - Fixtures

    /// The APNs shape `PushNotificationHandler.createApnsPayload` produces:
    /// metadata is a nested OBJECT whose ids are JSON numbers.
    private func apnsPayload(
        metadata: [String: Any]? = nil,
        title: String = "Sale"
    ) -> [AnyHashable: Any] {
        var root: [AnyHashable: Any] = [
            "aps": ["alert": ["title": title, "body": "20% off"]]
        ]
        root["metadata"] =
            metadata
            ?? [
                "orgId": 1, "projectId": 2, "destinationId": 3, "masterId": 4,
                "accountId": 5, "pipelineId": 6, "transformerId": 7, "templateId": 8,
            ]
        return root
    }

    /// The Firebase shape: metadata is a JSON STRING of the same object.
    private func fcmShapedPayload() -> [AnyHashable: Any] {
        [
            "metadata": """
            {"orgId":"1","projectId":"2","destinationId":"3","masterId":"4",\
            "accountId":"5","pipelineId":"6","transformerId":"7","templateId":"8"}
            """
        ]
    }

    private func sender(_ session: MockSession) -> PushWebhookSender {
        PushWebhookSender(
            network: Network(session: session),
            credentials: try! IntemptCredentials(apiKey: "pfx.secret"))
    }

    // MARK: - Endpoint

    /// The webhook is NOT under /v1. `PushSourceDataRoutes.java` registers it at
    /// the gateway root alongside the versioned routes, and Android posts to
    /// `${API_URL}/webhooks/events/push-notification` with `API_URL` set to the
    /// bare host. A /v1 here is a 404 the SDK cannot see, because the send is
    /// fire-and-forget.
    func testWebhookURLHasNoVersionSegment() {
        let url = Endpoint.pushNotificationWebhook.url()?.absoluteString
        XCTAssertEqual(url, "https://api.intempt.com/webhooks/events/push-notification")
        XCTAssertFalse(url!.contains("/v1"), "the webhook routes are unversioned")
    }

    /// The versioned routes must not have moved while the webhook was added.
    func testIngestionRoutesKeepTheirVersionSegment() {
        XCTAssertEqual(
            Endpoint.consents(org: "acme", project: "web").url()?.absoluteString,
            "https://api.intempt.com/v1/acme/projects/web/consents/data")
        XCTAssertEqual(Endpoint.pushNotificationWebhook.versionPrefix, "")
        XCTAssertEqual(Endpoint.consents(org: "a", project: "b").versionPrefix, "/v1")
    }

    // MARK: - Metadata parsing

    func testParsesTheApnsObjectShapeWithNumericIds() throws {
        let metadata = try XCTUnwrap(PushMetadata(userInfo: apnsPayload()))

        XCTAssertEqual(metadata.orgId, "1")
        XCTAssertEqual(metadata.projectId, "2")
        XCTAssertEqual(metadata.destinationId, "3")
        XCTAssertEqual(metadata.masterId, "4")
        XCTAssertEqual(metadata.accountId, "5")
        XCTAssertEqual(metadata.pipelineId, "6")
        XCTAssertEqual(metadata.transformerId, "7")
        XCTAssertEqual(metadata.templateId, "8")
    }

    /// A service extension can be handed the Firebase string form.
    func testParsesTheStringifiedShape() throws {
        let metadata = try XCTUnwrap(PushMetadata(userInfo: fcmShapedPayload()))
        XCTAssertEqual(metadata.orgId, "1")
        XCTAssertEqual(metadata.templateId, "8")
    }

    /// Both shapes must yield the SAME value, or a send reports differently
    /// depending on which process observed it.
    func testTheTwoShapesAgree() {
        XCTAssertEqual(PushMetadata(userInfo: apnsPayload()), PushMetadata(userInfo: fcmShapedPayload()))
    }

    func testANotificationWithNoMetadataIsNotOurs() {
        XCTAssertNil(PushMetadata(userInfo: ["aps": ["alert": "hello"]]))
        XCTAssertNil(PushMetadata(userInfo: [:]))
    }

    /// Every one of the eight is `@NotNull` server-side. A report missing one is
    /// rejected AFTER the request, so it must not be built at all.
    func testEveryRequiredIdIsRequired() {
        for missing in PushMetadata.requiredKeys {
            var fields: [String: Any] = [
                "orgId": 1, "projectId": 2, "destinationId": 3, "masterId": 4,
                "accountId": 5, "pipelineId": 6, "transformerId": 7, "templateId": 8,
            ]
            fields.removeValue(forKey: missing)
            XCTAssertNil(
                PushMetadata(userInfo: apnsPayload(metadata: fields)),
                "dropping \(missing) must abandon the report")
        }
    }

    func testEmptyIdsAreRejected() {
        var fields: [String: Any] = [
            "orgId": "", "projectId": 2, "destinationId": 3, "masterId": 4,
            "accountId": 5, "pipelineId": 6, "transformerId": 7, "templateId": 8,
        ]
        XCTAssertNil(PushMetadata(userInfo: apnsPayload(metadata: fields)))
        fields["orgId"] = 1
        XCTAssertNotNil(PushMetadata(userInfo: apnsPayload(metadata: fields)))
    }

    /// CFBoolean bridges to NSNumber, so an unguarded numeric branch renders
    /// `true` as the id "1" and reports against org 1.
    func testABooleanIsNotAnId() {
        let fields: [String: Any] = [
            "orgId": true, "projectId": 2, "destinationId": 3, "masterId": 4,
            "accountId": 5, "pipelineId": 6, "transformerId": 7, "templateId": 8,
        ]
        XCTAssertNil(PushMetadata(userInfo: apnsPayload(metadata: fields)))
    }

    func testMalformedStringMetadataIsRejectedRatherThanCrashing() {
        XCTAssertNil(PushMetadata(userInfo: ["metadata": "{not json"]))
        XCTAssertNil(PushMetadata(userInfo: ["metadata": 42]))
    }

    // MARK: - Body

    /// The eleven fields `PushNotificationEvent` binds.
    func testBodyCarriesEveryFieldTheServerBinds() throws {
        let metadata = try XCTUnwrap(PushMetadata(userInfo: apnsPayload()))
        let body = PushWebhookBody.make(metadata: metadata, status: .opened)

        for key in PushMetadata.requiredKeys {
            XCTAssertNotNil(body[key], "\(key) is @NotNull on PushNotificationEvent")
        }
        XCTAssertEqual(body["status"] as? String, "opened")
        XCTAssertEqual(body["destinationType"] as? String, "apns")
        XCTAssertEqual(body["subject"] as? String, "apns")
        XCTAssertEqual(body.count, 11)
    }

    /// `PushNotificationEventService` matches `status` against
    /// `Type.receivedType` and records NOTHING when nothing matches — a 200 with
    /// no row written. These three strings are the whole contract.
    func testStatusStringsMatchTheServersEnum() {
        XCTAssertEqual(
            Set(PushWebhookStatus.allCases.map(\.rawValue)),
            ["delivered", "bounced", "opened"])
    }

    /// `type` is @JsonIgnore server-side and derived from `status`. Sending it
    /// invites a payload whose two fields disagree.
    func testBodyDoesNotSendTheDerivedType() throws {
        let metadata = try XCTUnwrap(PushMetadata(userInfo: apnsPayload()))
        XCTAssertNil(PushWebhookBody.make(metadata: metadata, status: .delivered)["type"])
    }

    // MARK: - Transport

    func testReportPostsToTheWebhookWithBasicAuth() throws {
        let session = MockSession(replies: [.ok()])
        XCTAssertTrue(sender(session).report(.opened, userInfo: apnsPayload()))

        XCTAssertEqual(session.requestCount, 1)
        let request = session.requests[0]
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(
            request.url?.absoluteString,
            "https://api.intempt.com/webhooks/events/push-notification")
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "Authorization"),
            "Basic " + Data("pfx:secret".utf8).base64EncodedString())
        XCTAssertEqual(session.bodies[0]["status"] as? String, "opened")
        XCTAssertEqual(session.bodies[0]["orgId"] as? String, "1")
    }

    /// A push from another vendor must cost nothing at all.
    func testAForeignNotificationSendsNoRequest() {
        let session = MockSession(replies: [.ok()])
        XCTAssertFalse(
            sender(session).report(.opened, userInfo: ["aps": ["alert": "from someone else"]]))
        XCTAssertEqual(session.requestCount, 0)
    }

    /// A report that fails every attempt is logged and dropped. It never throws
    /// and never reaches the caller as an error — a push interaction must not be
    /// able to take the host app down.
    func testAPersistentServerErrorIsSwallowed() {
        let session = MockSession(replies: [], fallback: .status(500))
        let done = expectation(description: "reported")
        retryingSender(session, delays: { _ in }).report(.delivered, userInfo: apnsPayload()) {
            outcome in
            XCTAssertFalse(outcome.isSuccess)
            done.fulfill()
        }
        wait(for: [done], timeout: 2)
        XCTAssertEqual(session.requestCount, PushWebhookSender.maxAttempts)
    }

    // MARK: - Instance wiring

    private func instance(_ session: MockSession) throws -> IntemptInstance {
        try IntemptInstance.makeForTesting(
            store: defaults, databaseDirectory: tempDir, network: Network(session: session))
    }

    func testTrackPushOpenAlsoReportsOpenedToTheWebhook() throws {
        let session = MockSession(replies: [.ok()])
        XCTAssertTrue(try instance(session).trackPushOpen(apnsPayload()))

        waitUntil("webhook posted") { session.requestCount == 1 }
        XCTAssertEqual(session.bodies.first?["status"] as? String, "opened")
        XCTAssertEqual(
            session.requests.first?.url?.path, "/webhooks/events/push-notification",
            "the analytics flush uses a different path; this must be the webhook")
    }

    func testTrackPushReceivedReportsDeliveredWhenNotificationsAreAllowed() throws {
        PushAuthorization.probe = { $0(true) }
        let session = MockSession(replies: [.ok()])
        XCTAssertTrue(try instance(session).trackPushReceived(apnsPayload()))

        waitUntil("webhook posted") { session.requestCount == 1 }
        XCTAssertEqual(session.bodies.first?["status"] as? String, "delivered")
    }

    /// The iOS half of `FirebaseService.notifySafely`: authorization denied means
    /// the system will not show it, which is a bounce, not a delivery.
    func testTrackPushReceivedReportsBouncedWhenNotificationsAreDenied() throws {
        PushAuthorization.probe = { $0(false) }
        let session = MockSession(replies: [.ok()])
        XCTAssertTrue(try instance(session).trackPushReceived(apnsPayload()))

        waitUntil("webhook posted") { session.requestCount == 1 }
        XCTAssertEqual(session.bodies.first?["status"] as? String, "bounced")
        XCTAssertNotEqual(
            session.bodies.first?["status"] as? String, "delivered",
            "a push the system suppressed was not delivered")
    }

    /// The probe must not be consulted for a notification that is not ours, and
    /// no request may be made for one.
    func testAForeignNotificationReachesNeitherTheProbeNorTheNetwork() throws {
        var probed = false
        PushAuthorization.probe = {
            probed = true
            $0(true)
        }
        let session = MockSession(replies: [.ok()])
        _ = try instance(session).trackPushReceived(["aps": ["alert": "hello"]])

        XCTAssertFalse(probed)
        XCTAssertEqual(session.requestCount, 0)
    }

    // MARK: - Opt-out

    /// The webhook body carries `masterId` and `accountId`, which identify a
    /// person. `optOut` promises to stop collection, and the webhook is not
    /// routed through `track` — so it needs its own gate or it becomes the one
    /// piece of person-linked traffic the opt-out does not reach.
    func testAnOptedOutUserReportsNoOpen() throws {
        let session = MockSession(replies: [.ok()])
        let instance = try instance(session)
        instance.optOut()

        _ = instance.trackPushOpen(apnsPayload())

        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        XCTAssertEqual(session.requestCount, 0, "opt-out must reach the webhook too")
    }

    func testAnOptedOutUserReportsNoDelivery() throws {
        PushAuthorization.probe = { $0(true) }
        let session = MockSession(replies: [.ok()])
        let instance = try instance(session)
        instance.optOut()

        _ = instance.trackPushReceived(apnsPayload())

        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        XCTAssertEqual(session.requestCount, 0)
    }

    /// The gate before the probe has its own effect, and without this the inner
    /// gate covers for it: an opted-out user must not have their notification
    /// authorization read at all. Asking is a system call about a person who has
    /// said stop.
    func testAnOptedOutUserIsNotEvenAskedAboutAuthorization() throws {
        var probed = false
        PushAuthorization.probe = {
            probed = true
            $0(true)
        }
        let session = MockSession(replies: [.ok()])
        let instance = try instance(session)
        instance.optOut()

        _ = instance.trackPushReceived(apnsPayload())

        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        XCTAssertFalse(probed, "opt-out must short-circuit before the probe")
        XCTAssertEqual(session.requestCount, 0)
    }

    /// Opting back in restores reporting, so the gate is a gate and not an
    /// accidental permanent disable.
    func testOptingBackInResumesReporting() throws {
        let session = MockSession(replies: [.ok()])
        let instance = try instance(session)
        instance.optOut()
        instance.optIn()

        _ = instance.trackPushOpen(apnsPayload())

        waitUntil("webhook posted") { session.requestCount == 1 }
        XCTAssertEqual(session.bodies.first?["status"] as? String, "opened")
    }

    /// Opting out DURING the authorization probe must still stop the report.
    /// The probe is async, so the decision to send outlives the check that
    /// permitted it.
    func testOptingOutWhileTheAuthorizationProbeIsInFlightStopsTheReport() throws {
        let session = MockSession(replies: [.ok()])
        let instance = try instance(session)

        var release: ((Bool) -> Void)?
        PushAuthorization.probe = { release = $0 }

        _ = instance.trackPushReceived(apnsPayload())
        XCTAssertEqual(session.requestCount, 0, "probe has not answered yet")

        instance.optOut()
        release?(true)

        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        XCTAssertEqual(session.requestCount, 0)
    }

    // MARK: - Retry

    private func retryingSender(
        _ session: MockSession, delays: @escaping (TimeInterval) -> Void
    ) -> PushWebhookSender {
        PushWebhookSender(
            network: Network(session: session),
            credentials: try! IntemptCredentials(apiKey: "pfx.secret"),
            scheduler: { delay, work in
                delays(delay)
                work()
            })
    }

    /// Android retries this webhook four times with a doubling delay, and says
    /// why: a dropped DELIVERED makes a journey believe the push never arrived
    /// and send the wrong follow-up to a real person.
    func testATransientFailureIsRetriedUpToFourAttempts() {
        let session = MockSession(replies: [], fallback: .status(503))
        var delays: [TimeInterval] = []
        let done = expectation(description: "gave up")

        retryingSender(session, delays: { delays.append($0) })
            .report(.delivered, userInfo: apnsPayload()) { _ in done.fulfill() }

        wait(for: [done], timeout: 2)
        XCTAssertEqual(session.requestCount, 4)
        XCTAssertEqual(delays, [1, 2, 4], "the delay must double, not repeat")
    }

    func testRetryingStopsAsSoonAsOneAttemptSucceeds() {
        let session = MockSession(replies: [.status(503), .ok()], fallback: .status(503))
        let done = expectation(description: "sent")

        retryingSender(session, delays: { _ in })
            .report(.opened, userInfo: apnsPayload()) { outcome in
                XCTAssertTrue(outcome.isSuccess)
                done.fulfill()
            }

        wait(for: [done], timeout: 2)
        XCTAssertEqual(session.requestCount, 2, "a success must not be followed by more attempts")
    }

    /// A 400 means the body is wrong and will be wrong again. Repeating it
    /// spends the little wall-clock a suspending process has on a certainty.
    func testARejectionIsNotRetried() {
        let session = MockSession(replies: [], fallback: .status(400))
        let done = expectation(description: "gave up")

        retryingSender(session, delays: { _ in })
            .report(.opened, userInfo: apnsPayload()) { _ in done.fulfill() }

        wait(for: [done], timeout: 2)
        XCTAssertEqual(session.requestCount, 1)
    }

    func testOfflineIsRetried() {
        let session = MockSession(replies: [], fallback: .offline())
        let done = expectation(description: "gave up")

        retryingSender(session, delays: { _ in })
            .report(.bounced, userInfo: apnsPayload()) { _ in done.fulfill() }

        wait(for: [done], timeout: 2)
        XCTAssertEqual(session.requestCount, PushWebhookSender.maxAttempts)
    }

    /// A retry is a NEW request, and the backoff spans seven seconds. Without a
    /// gate inside the loop, opting out during it still let three more
    /// person-linked POSTs leave — `masterId` and `accountId` each time.
    func testOptingOutMidBackoffAbandonsTheRemainingRetries() throws {
        let session = MockSession(replies: [], fallback: .status(503))
        let instance = try instance(session)

        var resume: (() -> Void)?
        let sender = PushWebhookSender(
            network: Network(session: session),
            credentials: try IntemptCredentials(apiKey: "pfx.secret"),
            scheduler: { _, work in resume = work })
        sender.isPermitted = { [weak instance] in instance?.hasOptedOut() == false }

        sender.report(.delivered, userInfo: apnsPayload())
        XCTAssertEqual(session.requestCount, 1, "first attempt has been made")

        instance.optOut()
        resume?()

        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        XCTAssertEqual(
            session.requestCount, 1,
            "no further attempt may start once collection has stopped")
    }

    /// Drives the instance's OWN sender, not a locally built one, so the
    /// `isPermitted` wiring in `IntemptInstance.init` is what is under test.
    /// A mutation deleting that line survived every other test here.
    func testTheInstanceWiresItsOwnSenderToOptOut() throws {
        PushAuthorization.probe = { $0(true) }
        let session = MockSession(replies: [], fallback: .status(503))
        let instance = try instance(session)

        var resume: (() -> Void)?
        instance.pushWebhook.scheduler = { _, work in resume = work }

        _ = instance.trackPushReceived(apnsPayload())
        waitUntil("first attempt made") { session.requestCount == 1 }

        instance.optOut()
        resume?()

        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        XCTAssertEqual(
            session.requestCount, 1,
            "the instance must gate its own sender's retries on opt-out")
    }

    /// The same path with no opt-out, so the test above is proving the gate
    /// rather than proving the scheduler was simply never resumed.
    func testTheInstanceSenderKeepsRetryingWhenStillCollecting() throws {
        PushAuthorization.probe = { $0(true) }
        let session = MockSession(replies: [], fallback: .status(503))
        let instance = try instance(session)

        var resume: (() -> Void)?
        instance.pushWebhook.scheduler = { _, work in resume = work }

        _ = instance.trackPushReceived(apnsPayload())
        waitUntil("first attempt made") { session.requestCount == 1 }

        resume?()
        waitUntil("second attempt made") { session.requestCount == 2 }
    }

    /// The gate must not be a permanent stop for a user who never opted out.
    func testRetriesContinueWhileCollectionIsPermitted() {
        let session = MockSession(replies: [], fallback: .status(503))
        var delays: [TimeInterval] = []
        let done = expectation(description: "gave up")

        let sender = retryingSender(session, delays: { delays.append($0) })
        sender.isPermitted = { true }
        sender.report(.delivered, userInfo: apnsPayload()) { _ in done.fulfill() }

        wait(for: [done], timeout: 2)
        XCTAssertEqual(session.requestCount, PushWebhookSender.maxAttempts)
    }

    // MARK: - Authorization mapping

    /// The only real logic in `PushAuthorization`, and until this existed it was
    /// executed by no test at all: every other test replaces `probe` wholesale,
    /// and `UNUserNotificationCenter.current()` raises without a bundle id so the
    /// probe itself cannot run here. A review inverted this comparison and the
    /// full 366-test suite stayed green.
    #if canImport(UserNotifications)
        /// Never asked is not granted. iOS displays nothing, so it is a bounce.
        /// A bare `!= .denied` reported it as `delivered` — the defect this pins.
        func testNotDeterminedIsNotADelivery() {
            XCTAssertFalse(PushAuthorization.isDisplayable(.notDetermined))
        }

        func testDeniedIsNotADelivery() {
            XCTAssertFalse(PushAuthorization.isDisplayable(.denied))
        }

        /// Provisional delivers quietly to the notification centre and ephemeral
        /// is an App Clip's grant. In both the notification arrives.
        func testEveryGrantedFormIsADelivery() {
            XCTAssertTrue(PushAuthorization.isDisplayable(.authorized))
            XCTAssertTrue(PushAuthorization.isDisplayable(.provisional))
            #if !os(macOS)
                // App Clip grant. The case does not exist on macOS, which is why
                // isDisplayable enumerates the withholding statuses instead of
                // the granting ones.
                XCTAssertTrue(PushAuthorization.isDisplayable(.ephemeral))
            #endif
        }

        /// Android reports BOUNCED for anything that is not
        /// `PERMISSION_GRANTED`, and "never asked" is not granted. Both docs
        /// claim this SDK matches that check, so the claim is asserted here
        /// rather than left in prose.
        func testTheTwoUngrantedStatusesAgreeWithEachOther() {
            XCTAssertEqual(
                PushAuthorization.isDisplayable(.notDetermined),
                PushAuthorization.isDisplayable(.denied),
                "Android bounces both; neither is PERMISSION_GRANTED")
        }
    #endif

    #if canImport(UserNotifications)
        /// Covers the WIRING, not the mapping. `isDisplayable` was tested while
        /// the line that calls it was not, and reverting that line to the old
        /// `!= .denied` survived the whole suite.
        func testTheProbeRunsEveryStatusThroughTheMapping() {
            for (status, expected) in [
                (UNAuthorizationStatus.notDetermined, false),
                (.denied, false),
                (.authorized, true),
                (.provisional, true),
            ] {
                PushAuthorization.statusSource = { $0(status) }
                var answer: Bool?
                PushAuthorization.defaultProbe { answer = $0 }
                XCTAssertEqual(answer, expected, "status \(status.rawValue)")
            }
        }

        /// An unbundled process cannot ask, and must not invent a bounce.
        func testAnUnaskableProcessAssumesDelivered() {
            PushAuthorization.statusSource = { $0(nil) }
            var answer: Bool?
            PushAuthorization.defaultProbe { answer = $0 }
            XCTAssertEqual(answer, true)
        }
    #endif

    /// The gate covers the first attempt, not only the retries.
    func testNothingIsSentAtAllWhenPermissionIsWithdrawn() {
        let session = MockSession(replies: [.ok()])
        let sender = sender(session)
        sender.isPermitted = { false }

        XCTAssertTrue(
            sender.report(.opened, userInfo: apnsPayload()),
            "the return value reports whether the payload was ours, not whether it was sent")
        XCTAssertEqual(session.requestCount, 0, "not even the first attempt may go out")
    }

    /// Pins the documented split between the return value and the completion.
    /// The return value says "this was an Intempt push"; the completion says "a
    /// request reached the network". A gated report is true and silent.
    func testAGatedReportNeverCallsItsCompletion() {
        let session = MockSession(replies: [.ok()])
        let sender = sender(session)
        sender.isPermitted = { false }

        var completed = false
        sender.report(.opened, userInfo: apnsPayload()) { _ in completed = true }

        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        XCTAssertFalse(completed, "nothing reached the network, so there is no outcome to report")
        XCTAssertEqual(session.requestCount, 0)
    }

    /// The same call, ungated, must reach the completion — otherwise the test
    /// above passes for the wrong reason.
    func testAPermittedReportDoesCallItsCompletion() {
        let session = MockSession(replies: [.ok()])
        let done = expectation(description: "completed")
        sender(session).report(.opened, userInfo: apnsPayload()) { _ in done.fulfill() }
        wait(for: [done], timeout: 2)
    }

    func testRetryClassification() {
        XCTAssertTrue(PushWebhookSender.isWorthRetrying(.retryable(status: 503, retryAfter: nil)))
        XCTAssertTrue(PushWebhookSender.isWorthRetrying(.transport("offline")))
        XCTAssertFalse(PushWebhookSender.isWorthRetrying(.terminal(status: 400, body: nil)))
        XCTAssertFalse(PushWebhookSender.isWorthRetrying(.success(nil)))
    }
}
