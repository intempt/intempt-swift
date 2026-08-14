import XCTest

@testable import Intempt

/// Pins every wire value that must match the JS SDK.
///
/// These are not style assertions. An event title is a wire value: an analyst
/// filtering a funnel on "Added to cart" stops seeing iOS carts the moment this
/// SDK sends "Product Add" instead. This suite exists because that had already
/// happened — the first implementation invented "Product View", "Product Add"
/// and "Product Ordered", none of which intemptjs sends.
///
/// Source of truth, read from the intemptjs repo:
///   IntemptEventName    src/intemptJs/types/constants.types.ts:1-11
///   DeviceTypeName      src/intemptJs/types/constants.types.ts:21-26
///   session event name  src/.../sessionTracker/sessionTracker.module.ts:11
final class JSParityTests: XCTestCase {

    // MARK: - Event titles

    func testCommerceEventTitlesMatchIntemptJS() {
        // intemptjs PRODUCT_VIEW / PRODUCT_ADD / PRODUCT_ORDER
        XCTAssertEqual(EventNames.productView, "Product viewed")
        XCTAssertEqual(EventNames.productAdd, "Added to cart")
        XCTAssertEqual(EventNames.productOrdered, "Product ordered")
    }

    func testInteractionEventTitlesMatchIntemptJS() {
        XCTAssertEqual(EventNames.viewPage, "View Page")
        XCTAssertEqual(EventNames.leavePage, "Leave Page")
        XCTAssertEqual(EventNames.clickOn, "Click On")
        XCTAssertEqual(EventNames.changeOn, "Change On")
        XCTAssertEqual(EventNames.submitOn, "Submit On")
    }

    /// intemptjs is internally inconsistent: its enum declares
    /// `SESSION_START = "Session Start"` but the session tracker hardcodes
    /// `'Session start'` and never reads the enum. The lowercase form is what
    /// reaches ingestion, so it is what we must send — matching the enum would
    /// look tidier and produce a name no existing report filters on.
    func testSessionEventTitleMatchesWhatIntemptJSActuallySends() {
        XCTAssertEqual(EventNames.sessionStart, "Session start")
        XCTAssertNotEqual(
            EventNames.sessionStart, "Session Start",
            "the enum value is not the value the JS SDK puts on the wire")
    }

    // MARK: - The titles that actually reach the wire

    /// Guards the call sites, not just the constants. A correct constant that
    /// nothing uses is the failure mode a constants-only test cannot see.
    func testProductCallsPutTheIntemptJSTitlesOnTheWire() throws {
        let store = UserDefaults(suiteName: "parity-\(UUID().uuidString)")!
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("parity-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: dir)
            IntemptInstance.removeAllInstances()
        }

        let instance = try IntemptInstance.makeForTesting(
            store: store, databaseDirectory: dir)

        XCTAssertTrue(instance.productView(productId: "sku_1"))
        XCTAssertTrue(instance.productAdd(productId: "sku_1", quantity: 2))
        XCTAssertTrue(instance.productOrdered(products: [(productId: "sku_1", quantity: 1)]))

        let names = instance.db.read(.events, limit: 10).compactMap {
            (JSONHandler.deserializeData($0.data) as? [String: Any])?["name"] as? String
        }
        XCTAssertEqual(names, ["Product viewed", "Added to cart", "Product ordered"])
    }

    // MARK: - Vocabulary

    func testDeviceTypeUsesTheIntemptJSVocabulary() {
        // DeviceTypeName: Desktop | Mobile | Tablet | Not Recognized.
        // TV and Watch are documented native additions — the web SDK cannot see
        // those platforms, and reporting an Apple Watch as "Not Recognized"
        // would discard real information for a false consistency.
        let allowed: Set<String> = [
            "Desktop", "Mobile", "Tablet", "Not Recognized", "TV", "Watch",
        ]
        XCTAssertTrue(
            allowed.contains(AutomaticProperties.deviceType),
            "\(AutomaticProperties.deviceType) is outside the agreed vocabulary")
    }

    /// intemptjs's `ios` formatter emits `iOS <major>.<minor>` and deliberately
    /// drops the patch component, so a segment written against web data matches
    /// iOS data. Sending "iOS 18.2.1" would not match "iOS 18.2".
    func testPlatformStringFormat() {
        let platform = AutomaticProperties.platform
        #if os(macOS)
            XCTAssertTrue(
                platform.hasPrefix("Mac OS X "), "got \(platform)")
        #elseif os(iOS) && !targetEnvironment(macCatalyst)
            XCTAssertTrue(platform.hasPrefix("iOS "), "got \(platform)")
            let version = platform.replacingOccurrences(of: "iOS ", with: "")
            XCTAssertEqual(
                version.split(separator: ".").count, 2,
                "intemptjs sends major.minor only, got \(version)")
        #endif
    }

    /// Attribute keys are camelCase in intemptjs. snake_case would create a
    /// second, parallel set of profile attributes that no web-built segment
    /// matches.
    func testUserAttributeKeysAreCamelCase() {
        AutomaticProperties.reset()
        for key in AutomaticProperties.userAttributes().keys {
            XCTAssertFalse(key.contains("_"), "\(key) must be camelCase, not snake_case")
            XCTAssertFalse(key.hasPrefix("$"), "\(key) uses Mixpanel's reserved convention")
        }
    }

    // MARK: - Session model shape

    /// intemptjs's `SessionEventModel` declares only `name` and `payload` — no
    /// `type`. Verified against production that a typeless entry is accepted.
    func testSessionEntryOmitsTheTypeField() {
        let model = SessionModel(
            sessionId: "se_1", profileId: "pr_1", name: EventNames.sessionStart,
            data: nil, userAttributes: ["platform": "iOS 18.2"])

        let entry = model.toEnvelopeEntry()
        XCTAssertNil(entry["type"], "SessionEventModel carries no type field")
        XCTAssertEqual(entry["name"] as? String, "Session start")
        XCTAssertNotNil(entry["payload"])
    }

    /// `toEnvelopeEntry()` is declared in the protocol, not only in its
    /// extension, so a conforming type's override survives dynamic dispatch.
    /// If it were extension-only, `SessionModel`'s version would be ignored
    /// everywhere the SDK holds models as `IntemptModel` — which is everywhere.
    func testTypeOmissionSurvivesTheExistential() {
        let model: IntemptModel = SessionModel(
            sessionId: "se_1", profileId: "pr_1", name: EventNames.sessionStart,
            data: nil, userAttributes: nil)

        XCTAssertNil(
            model.toEnvelopeEntry()["type"],
            "dispatched through IntemptModel, the type field must still be absent")
    }

    /// Not an `ev_` UUID: reusing the session id makes session start naturally
    /// idempotent, so a retry cannot create a second one.
    func testSessionEventIdIsTheSessionId() {
        let model = SessionModel(
            sessionId: "se_abc", profileId: "pr_1", name: EventNames.sessionStart,
            data: nil, userAttributes: nil)

        let payload = model.toPayload()
        XCTAssertEqual(payload["eventId"] as? String, "se_abc")
        XCTAssertEqual(payload["sessionId"] as? String, "se_abc")
        XCTAssertNil(payload["pageId"], "SessionEventModel carries no pageId")
    }

    /// Every other model keeps its `type`; only the session model omits it.
    func testEveryOtherModelStillCarriesItsType() {
        let envelope = EventEnvelope(
            eventId: "ev_1", profileId: "pr_1", sessionId: "se_1", pageId: "pa_1")

        let models: [(IntemptModel, String)] = [
            (TrackModel(envelope: envelope, name: "X", data: nil), "track"),
            (
                IdentifyModel(
                    envelope: envelope, name: "Identify", userId: "u",
                    userAttributes: nil, data: nil), "identify"
            ),
            (
                GroupModel(
                    envelope: envelope, name: "Identify", accountId: "a",
                    accountAttributes: nil), "group"
            ),
            (
                AliasModel(eventId: "ev_1", profileId: "pr_1", userId: "u", anotherUserId: "v"),
                "alias"
            ),
            (
                RecordModel(
                    envelope: envelope, name: "X", userId: "u", accountId: nil,
                    data: nil, userAttributes: nil, accountAttributes: nil), "record"
            ),
            (
                ProductModel(
                    envelope: envelope, name: EventNames.productView,
                    productId: "sku", quantity: nil), "product"
            ),
        ]

        for (model, expected) in models {
            XCTAssertEqual(
                model.toEnvelopeEntry()["type"] as? String, expected,
                "\(expected) must keep its type discriminator")
        }
    }
}
