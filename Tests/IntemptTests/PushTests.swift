import XCTest

@testable import Intempt

final class PushTests: IntemptTestCase {

    // MARK: - Token formatting

    /// The historically common implementation used `Data.description` and
    /// stripped angle brackets. That worked until iOS 13 changed the format
    /// from `<a1b2 c3d4>` to `32 bytes` — after which apps registered the
    /// literal string "32 bytes" as their token and every push stopped
    /// arriving, with nothing in any log to say so.
    func testTokenIsLowercaseHexNotDataDescription() {
        let token = Data([0xa1, 0xb2, 0xc3, 0xd4, 0x00, 0x0f])
        let hex = Push.hexString(from: token)

        XCTAssertEqual(hex, "a1b2c3d4000f")
        XCTAssertFalse(hex.contains("bytes"), "Data.description would produce '6 bytes'")
        XCTAssertFalse(hex.contains("<"))
        XCTAssertFalse(hex.contains(" "))
    }

    /// Leading zeroes must survive. `String(byte, radix: 16)` drops them and
    /// yields a short token that APNs silently rejects.
    func testLeadingZeroBytesArePadded() {
        XCTAssertEqual(Push.hexString(from: Data([0x00, 0x01, 0x0a])), "00010a")
        XCTAssertEqual(Push.hexString(from: Data([0x00])), "00")
    }

    func testFullLengthTokenIsSixtyFourCharacters() {
        let token = Data((0..<32).map { UInt8($0) })
        XCTAssertEqual(Push.hexString(from: token).count, 64)
    }

    func testEmptyTokenIsEmptyString() {
        XCTAssertEqual(Push.hexString(from: Data()), "")
    }

    // MARK: - Plausibility

    func testRealLengthTokensAreAccepted() {
        XCTAssertTrue(Push.isPlausible(Data(repeating: 0xab, count: 32)))
        XCTAssertTrue(Push.isPlausible(Data(repeating: 0xab, count: 100)))
    }

    /// The usual mistake is passing a stringified token re-encoded as UTF-8, or
    /// an empty Data from a failed registration.
    func testShortTokensAreRejected() {
        XCTAssertFalse(Push.isPlausible(Data()))
        XCTAssertFalse(Push.isPlausible(Data("32 bytes".utf8)))
        XCTAssertFalse(Push.isPlausible(Data(repeating: 0xab, count: 31)))
    }

    func testInstanceRejectsAnImplausibleToken() throws {
        let instance = try IntemptInstance.makeForTesting(
            store: defaults, databaseDirectory: tempDir)

        XCTAssertFalse(instance.setPushToken(Data("32 bytes".utf8)))
        XCTAssertEqual(instance.queuedEventCount(), 0, "a bad token must not be sent")
    }

    /// The attribute name must be `apns_token_<sourceId>`, mirroring the Android
    /// SDK's `"fcm_token_" + config.sourceId` (InstallOrUpgradeEvent.kt:45).
    ///
    /// `AndroidSourceInitialization` renames the schema's placeholder
    /// `device_token` field to `fcm_token_<sourceId>`, and the iOS source
    /// initialisation now does the same with `apns_token_<sourceId>`. The name
    /// therefore has to be built client-side — a flat `pushToken`, which an
    /// earlier version sent, matches no column and is dropped after a 201.
    func testTokenAttributeIsNamedPerSourceLikeAndroid() throws {
        let instance = try IntemptInstance.makeForTesting(
            sourceId: "1842928692221829120",
            store: defaults, databaseDirectory: tempDir)

        let token = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
        XCTAssertTrue(instance.setPushToken(token))

        let row = instance.db.read(.events, limit: 1)[0]
        let entry = JSONHandler.deserializeData(row.data) as! [String: Any]
        let payload = (entry["payload"] as! [[String: Any]])[0]
        let attributes = payload["userAttributes"] as! [String: Any]

        XCTAssertEqual(
            attributes["apns_token_1842928692221829120"] as? String,
            Push.hexString(from: token))
        XCTAssertNil(attributes["pushToken"], "a flat name matches no column")
        XCTAssertNil(attributes["device_token"], "that is the schema placeholder, not the wire name")
    }

    /// Same event title Android uses, so both platforms land in the collection
    /// their source provisions.
    func testTokenRidesTheInstallUpgradeEvent() throws {
        let instance = try IntemptInstance.makeForTesting(
            store: defaults, databaseDirectory: tempDir)
        XCTAssertTrue(instance.setPushToken(Data(repeating: 0xAB, count: 32)))

        let entry = JSONHandler.deserializeData(instance.db.read(.events, limit: 1)[0].data)
            as! [String: Any]
        XCTAssertEqual(entry["name"] as? String, "App Install/Upgrade")
    }

    func testKeyBuilderMatchesTheAndroidShape() {
        XCTAssertEqual(EventKeys.apnsToken(sourceId: "123"), "apns_token_123")
        // Android: "fcm_token_" + sourceId. Same construction, different prefix,
        // and destinations-processor selects on the prefix.
        XCTAssertTrue(EventKeys.apnsToken(sourceId: "123").hasPrefix("apns_token_"))
    }

    func testInstanceAcceptsARealToken() throws {
        let instance = try IntemptInstance.makeForTesting(
            store: defaults, databaseDirectory: tempDir)

        let token = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
        XCTAssertTrue(instance.setPushToken(token))
        XCTAssertEqual(instance.queuedEventCount(), 1)

        let row = instance.db.read(.events, limit: 1)[0]
        let entry = JSONHandler.deserializeData(row.data) as! [String: Any]
        XCTAssertEqual(entry["name"] as? String, "App Install/Upgrade")

        let payload = (entry["payload"] as! [[String: Any]])[0]
        let attributes = payload["userAttributes"] as? [String: Any]
        XCTAssertEqual(
            attributes?[EventKeys.apnsToken(sourceId: instance.sourceId)] as? String,
            Push.hexString(from: token))
    }

    // MARK: - Attribution

    /// The notification BODY is content written for one user and routinely
    /// contains their own data — a message preview, an order total, a medical
    /// result. It must never be copied into analytics.
    func testNotificationBodyIsNeverCaptured() {
        let userInfo: [AnyHashable: Any] = [
            "aps": [
                "alert": [
                    "title": "Order update",
                    "body": "Your prescription for Sertraline 50mg is ready",
                ]
            ],
            "intempt_campaign_id": "camp_42",
        ]

        let properties = Push.attribution(from: userInfo)
        let rendered = properties.values.map { String(describing: $0) }.joined(separator: " ")

        XCTAssertFalse(rendered.contains("Sertraline"), "the body must never be captured")
        XCTAssertFalse(rendered.contains("prescription"))
        XCTAssertEqual(properties["campaignId"] as? String, "camp_42")
        XCTAssertEqual(properties["notificationTitle"] as? String, "Order update")
    }

    func testCampaignIdAliasesAreAccepted() {
        for key in ["intempt_campaign_id", "campaignId", "campaign_id"] {
            let properties = Push.attribution(from: [key: "camp_1"])
            XCTAssertEqual(
                properties["campaignId"] as? String, "camp_1",
                "\(key) must be recognised")
        }
    }

    func testIntemptPrefixedKeyWinsWhenSeveralArePresent() {
        let properties = Push.attribution(from: [
            "campaign_id": "generic", "intempt_campaign_id": "intempt",
        ])
        XCTAssertEqual(properties["campaignId"] as? String, "intempt")
    }

    func testEmptyPayloadYieldsNoProperties() {
        XCTAssertTrue(Push.attribution(from: [:]).isEmpty)
    }

    func testEmptyCampaignIdIsIgnored() {
        XCTAssertNil(Push.attribution(from: ["campaignId": ""])["campaignId"])
    }

    /// A string-form alert (`"alert": "text"`) is the shorthand APNs allows.
    /// It carries no title, and the whole string is body content.
    func testStringAlertShorthandCapturesNothing() {
        let properties = Push.attribution(from: [
            "aps": ["alert": "Your prescription is ready"]
        ])
        XCTAssertNil(properties["notificationTitle"])
        XCTAssertTrue(properties.isEmpty)
    }

    func testMalformedPayloadDoesNotCrash() {
        XCTAssertTrue(Push.attribution(from: ["aps": "not a dictionary"]).isEmpty)
        XCTAssertTrue(Push.attribution(from: ["aps": ["alert": 42]]).isEmpty)
        XCTAssertTrue(Push.attribution(from: ["campaignId": 42]).isEmpty)
    }

    // MARK: - Events

    func testPushOpenAndReceiveUseDistinctTitles() throws {
        let instance = try IntemptInstance.makeForTesting(
            store: defaults, databaseDirectory: tempDir)

        XCTAssertTrue(instance.trackPushOpen(["campaignId": "c1"]))
        XCTAssertTrue(instance.trackPushReceived(["campaignId": "c1"]))

        let names = instance.db.read(.events, limit: 10).compactMap {
            (JSONHandler.deserializeData($0.data) as? [String: Any])?["name"] as? String
        }
        XCTAssertEqual(names, ["Push Opened", "Push Received"])
    }

    func testPushEventsRespectOptOut() throws {
        let instance = try IntemptInstance.makeForTesting(
            store: defaults, databaseDirectory: tempDir)
        instance.optOut()

        XCTAssertFalse(instance.trackPushOpen(["campaignId": "c1"]))
        XCTAssertFalse(instance.setPushToken(Data(repeating: 0xab, count: 32)))
        XCTAssertEqual(instance.queuedEventCount(), 0)
    }
}
