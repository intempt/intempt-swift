import XCTest

@testable import Intempt

/// Field sets asserted exactly — no more, no less — against the verified
/// intemptjs payload types. A model gaining or losing a field breaks these.
final class ModelsTests: XCTestCase {

    private let env = EventEnvelope(
        eventId: "ev_1", profileId: "p1", sessionId: "s1", pageId: "pg1")

    private func keys(_ payload: [String: Any]) -> Set<String> { Set(payload.keys) }

    // MARK: Envelope

    func testGeneratedEventIdIsPrefixedAndUnique() {
        let a = EventEnvelope.generate(profileId: "p", sessionId: "s", pageId: "pg")
        let b = EventEnvelope.generate(profileId: "p", sessionId: "s", pageId: "pg")
        XCTAssertTrue(a.eventId.hasPrefix("ev_"))
        XCTAssertNotEqual(a.eventId, b.eventId)
    }

    // MARK: Track

    func testTrackFieldSet() {
        let m = TrackModel(envelope: env, name: "Checkout", data: ["button": "pay"])
        XCTAssertEqual(keys(m.toPayload()), ["eventId", "profileId", "sessionId", "pageId", "data"])
        XCTAssertEqual(m.type, "track")
    }

    func testTrackOmitsDataWhenNil() {
        let m = TrackModel(envelope: env, name: "Ping", data: nil)
        XCTAssertFalse(m.toPayload().keys.contains("data"))
    }

    // MARK: Identify

    func testIdentifyFieldSet() {
        let m = IdentifyModel(
            envelope: env, name: "Identify", userId: "u1",
            userAttributes: ["plan": "pro"], data: nil)
        XCTAssertEqual(
            keys(m.toPayload()),
            ["eventId", "profileId", "sessionId", "pageId", "userId", "userAttributes"])
        XCTAssertEqual(m.type, "identify")
    }

    // MARK: Group / Account

    func testGroupCarriesAccountAttributesNotUserAttributes() {
        let m = GroupModel(
            envelope: env, name: "Identify", accountId: "acc1",
            accountAttributes: ["seats": 10])
        let p = m.toPayload()
        XCTAssertEqual(
            keys(p), ["eventId", "profileId", "sessionId", "pageId", "accountId", "accountAttributes"])
        // The old Obj-C SDK named this parameter userAttributes while sending
        // an account concept.
        XCTAssertNil(p["userAttributes"], "group must not carry userAttributes")
        XCTAssertNil(p["userId"], "group is the account concept, not the user concept")
    }

    // MARK: Alias

    /// Regression guard: alias must NOT gain sessionId/pageId the way every
    /// other model has them.
    func testAliasIsDeliberatelyThinner() {
        let m = AliasModel(
            eventId: "ev_1", profileId: "p1", userId: "u1", anotherUserId: "u2")
        XCTAssertEqual(keys(m.toPayload()), ["eventId", "profileId", "userId", "anotherUserId"])
        XCTAssertEqual(m.name, "Identify")
    }

    // MARK: Record

    func testRecordUserOnlyOmitsAccountFields() {
        let m = RecordModel(
            envelope: env, name: "Signup", userId: "u1", accountId: nil,
            data: nil, userAttributes: ["role": "admin"], accountAttributes: nil)
        let p = m.toPayload()
        XCTAssertNotNil(p["userId"])
        XCTAssertNil(p["accountId"])
        XCTAssertNil(p["accountAttributes"])
    }

    func testRecordCarriesUserAndAccountTogether() {
        let m = RecordModel(
            envelope: env, name: "Signup", userId: "u1", accountId: "acc1",
            data: ["src": "web"], userAttributes: ["role": "admin"],
            accountAttributes: ["seats": 10])
        XCTAssertEqual(
            keys(m.toPayload()),
            [
                "eventId", "profileId", "sessionId", "pageId",
                "userId", "accountId", "data", "userAttributes", "accountAttributes",
            ])
    }

    // MARK: Product

    func testProductDataIsFixedShape() {
        let m = ProductModel(envelope: env, name: "Product View", productId: "sku1", quantity: 2)
        let data = m.toPayload()["data"] as! [String: Any]
        XCTAssertEqual(Set(data.keys), ["productId", "quantity"])
    }

    func testProductOmitsQuantityWhenNil() {
        let m = ProductModel(envelope: env, name: "Product View", productId: "sku1", quantity: nil)
        let data = m.toPayload()["data"] as! [String: Any]
        XCTAssertEqual(Set(data.keys), ["productId"])
    }

    // MARK: Consent

    func testConsentFieldSetAndPlatformSource() {
        let m = ConsentModel(
            action: .reject, profileId: "p1", sourceId: "src1", source: "ios",
            validUntil: 123, email: nil, message: nil, category: nil)
        let p = m.toPayload()
        XCTAssertEqual(keys(p), ["action", "profileId", "sourceId", "source", "validUntil"])
        XCTAssertEqual(p["action"] as? String, "reject")
        XCTAssertEqual(p["source"] as? String, "ios", "native must not report intemptjs's \"web\"")
    }

    /// Tripwire: adding taxonomy cases must be a conscious change, not drift.
    func testConsentIsBinaryOnly() {
        XCTAssertEqual(ConsentAction.allCases.count, 2)
    }

    // MARK: Envelope wrapping

    func testEnvelopeEntryShape() {
        let m = TrackModel(envelope: env, name: "Checkout", data: nil)
        let entry = m.toEnvelopeEntry()
        XCTAssertEqual(Set(entry.keys), ["name", "type", "payload"])
        XCTAssertEqual(entry["name"] as? String, "Checkout")
        XCTAssertEqual((entry["payload"] as? [[String: Any]])?.count, 1)
    }

    /// One request carries a mixed batch — every type except consent.
    func testMixedTypeBatchInOneEnvelope() {
        let models: [IntemptModel] = [
            TrackModel(envelope: env, name: "T", data: nil),
            IdentifyModel(envelope: env, name: "I", userId: "u", userAttributes: nil, data: nil),
            GroupModel(envelope: env, name: "G", accountId: "a", accountAttributes: nil),
        ]
        let wrapped = TrackEnvelope.wrap(models: models)
        let entries = wrapped["track"] as! [[String: Any]]
        XCTAssertEqual(entries.count, 3)
        XCTAssertEqual(entries.compactMap { $0["type"] as? String }, ["track", "identify", "group"])
    }

    // MARK: Identity validation

    /// Ingestion rejects any item without one of these four.
    func testPayloadValidatorRequiresIdentity() {
        XCTAssertThrowsError(try PayloadValidator.validate(["eventId": "ev_1"])) { e in
            XCTAssertEqual(e as? IntemptError, .missingIdentity)
        }
        XCTAssertNoThrow(try PayloadValidator.validate(["profileId": "p1"]))
        XCTAssertNoThrow(try PayloadValidator.validate(["userId": "u1"]))
        XCTAssertNoThrow(try PayloadValidator.validate(["accountId": "a1"]))
        XCTAssertNoThrow(try PayloadValidator.validate(["productId": "sku"]))
    }

    func testEmptyIdentityStringIsRejected() {
        XCTAssertThrowsError(try PayloadValidator.validate(["profileId": ""]))
    }

    /// Every model must satisfy the ingestion identity rule as constructed.
    func testAllModelsCarryIdentity() throws {
        let models: [IntemptModel] = [
            TrackModel(envelope: env, name: "T", data: nil),
            IdentifyModel(envelope: env, name: "I", userId: "u", userAttributes: nil, data: nil),
            GroupModel(envelope: env, name: "G", accountId: "a", accountAttributes: nil),
            AliasModel(eventId: "ev_1", profileId: "p1", userId: "u", anotherUserId: "u2"),
            RecordModel(
                envelope: env, name: "R", userId: "u", accountId: nil, data: nil,
                userAttributes: nil, accountAttributes: nil),
            ProductModel(envelope: env, name: "P", productId: "sku", quantity: nil),
        ]
        for m in models {
            XCTAssertNoThrow(
                try PayloadValidator.validate(m.toPayload()),
                "\(m.type) must satisfy the ingestion identity rule")
        }
    }

    /// Every model must survive JSON encoding — a Date or NaN slipping in
    /// would silently drop the whole event.
    func testAllModelsEncodeToJSON() {
        let models: [IntemptModel] = [
            TrackModel(envelope: env, name: "T", data: ["at": Date(), "n": 1.5]),
            IdentifyModel(
                envelope: env, name: "I", userId: "u",
                userAttributes: ["joined": Date()], data: nil),
            ProductModel(envelope: env, name: "P", productId: "sku", quantity: 3),
        ]
        for m in models {
            XCTAssertNotNil(
                JSONHandler.encodeAPIData(TrackEnvelope.wrap(models: [m])),
                "\(m.type) failed to encode")
        }
    }
}
