import XCTest

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

    /// A failed report is logged and dropped, never retried and never thrown.
    func testAServerErrorIsSwallowed() {
        let session = MockSession(replies: [.status(500)])
        let done = expectation(description: "reported")
        sender(session).report(.delivered, userInfo: apnsPayload()) { outcome in
            XCTAssertFalse(outcome.isSuccess)
            done.fulfill()
        }
        wait(for: [done], timeout: 2)
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
        XCTAssertEqual(session.bodies[0]["status"] as? String, "opened")
        XCTAssertEqual(
            session.requests[0].url?.path, "/webhooks/events/push-notification",
            "the analytics flush uses a different path; this must be the webhook")
    }

    func testTrackPushReceivedReportsDeliveredWhenNotificationsAreAllowed() throws {
        PushAuthorization.probe = { $0(true) }
        let session = MockSession(replies: [.ok()])
        XCTAssertTrue(try instance(session).trackPushReceived(apnsPayload()))

        waitUntil("webhook posted") { session.requestCount == 1 }
        XCTAssertEqual(session.bodies[0]["status"] as? String, "delivered")
    }

    /// The iOS half of `FirebaseService.notifySafely`: authorization denied means
    /// the system will not show it, which is a bounce, not a delivery.
    func testTrackPushReceivedReportsBouncedWhenNotificationsAreDenied() throws {
        PushAuthorization.probe = { $0(false) }
        let session = MockSession(replies: [.ok()])
        XCTAssertTrue(try instance(session).trackPushReceived(apnsPayload()))

        waitUntil("webhook posted") { session.requestCount == 1 }
        XCTAssertEqual(session.bodies[0]["status"] as? String, "bounced")
        XCTAssertNotEqual(
            session.bodies[0]["status"] as? String, "delivered",
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
}
