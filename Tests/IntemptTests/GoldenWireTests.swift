import XCTest

@testable import Intempt

/// The keystone test.
///
/// Everything else asserts a component in isolation. This asserts the ONE
/// thing that matters commercially: that an event built by this SDK is
/// byte-correct on the wire — full URL, headers, and body shape — against a
/// fixture derived from the verified intemptjs contract.
///
/// A green suite that emits something ingestion rejects is worse than no
/// suite. This is what stops that.
final class GoldenWireTests: XCTestCase {

    // Shaped like a key and deliberately not shaped like a real one. The
    // previous fixture began "pk_live_", which is the prefix a live Stripe-style
    // credential uses, so the secret scanner matched it as generic-api-key —
    // correctly, on its face. A fixture only has to satisfy prefix.secret.
    private let creds = try! IntemptCredentials(apiKey: "examplePrefix.exampleSecret")

    /// Deterministic identity so the fixture is stable.
    private let env = EventEnvelope(
        eventId: "ev_FIXED-EVENT-ID",
        profileId: "pr_FIXED-PROFILE",
        sessionId: "se_FIXED-SESSION",
        pageId: "pg_FIXED-PAGE")

    // MARK: - The golden request

    func testTrackRequestIsByteCorrectOnTheWire() throws {
        let model = TrackModel(
            envelope: env,
            name: "Checkout Started",
            data: ["cart_value": 99, "currency": "USD"])

        let body = TrackEnvelope.wrap(models: [model])
        let request = try Network().makeRequest(
            endpoint: .track(org: "acme", project: "ecommerce", sourceId: "77", useIPForGeolocation: true),
            credentials: creds,
            body: body)

        // --- URL ---------------------------------------------------------
        XCTAssertEqual(
            request.url?.absoluteString,
            "https://api.intempt.com/v1/acme/projects/ecommerce/sources/77/track?ip=1",
            "URL must match intemptjs autoTracker.transport.ts — both SDKs now carry ?ip=, "
                + "which states whether the platform may derive location from the request address")

        // --- Method + headers -------------------------------------------
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "Authorization"),
            // base64("examplePrefix:exampleSecret"). Computed independently of
            // the code under test, so it still checks the encoding rather than
            // agreeing with whatever the SDK produced.
            "Basic ZXhhbXBsZVByZWZpeDpleGFtcGxlU2VjcmV0",
            "Basic base64(prefix:secret), matching intemptjs")

        // --- Body --------------------------------------------------------
        let decoded =
            try XCTUnwrap(
                JSONHandler.deserializeData(try XCTUnwrap(request.httpBody)) as? [String: Any])

        // Top level is exactly {"track": [...]}
        XCTAssertEqual(Set(decoded.keys), ["track"])

        let entries = try XCTUnwrap(decoded["track"] as? [[String: Any]])
        XCTAssertEqual(entries.count, 1)

        // Each entry is exactly {name, type, payload}
        let entry = entries[0]
        XCTAssertEqual(Set(entry.keys), ["name", "type", "payload"])
        XCTAssertEqual(entry["name"] as? String, "Checkout Started")
        XCTAssertEqual(entry["type"] as? String, "track")

        // payload is an ARRAY of dictionaries — DataRequest.java iterates it
        let payloads = try XCTUnwrap(entry["payload"] as? [[String: Any]])
        XCTAssertEqual(payloads.count, 1)

        let payload = payloads[0]
        XCTAssertEqual(
            Set(payload.keys),
            ["eventId", "profileId", "sessionId", "pageId", "data"])
        XCTAssertEqual(payload["eventId"] as? String, "ev_FIXED-EVENT-ID")
        XCTAssertEqual(payload["profileId"] as? String, "pr_FIXED-PROFILE")
        XCTAssertEqual(payload["sessionId"] as? String, "se_FIXED-SESSION")
        XCTAssertEqual(payload["pageId"] as? String, "pg_FIXED-PAGE")

        let data = try XCTUnwrap(payload["data"] as? [String: Any])
        XCTAssertEqual(data["cart_value"] as? Int, 99)
        XCTAssertEqual(data["currency"] as? String, "USD")

        // Ingestion's identity rule
        XCTAssertNoThrow(try PayloadValidator.validate(payload))
    }

    /// Consent takes a different endpoint and is NOT wrapped in the envelope.
    func testConsentRequestIsSeparateAndUnbatched() throws {
        let model = ConsentModel(
            action: .reject, profileId: "pr_FIXED-PROFILE", sourceId: "77",
            source: "ios", validUntil: 1_800_000_000,
            email: "a@b.com", message: nil, category: "marketing")

        let request = try Network().makeRequest(
            endpoint: .consents(org: "acme", project: "ecommerce"),
            credentials: creds,
            body: model.toPayload())

        XCTAssertEqual(
            request.url?.absoluteString,
            "https://api.intempt.com/v1/acme/projects/ecommerce/consents/data")

        let decoded =
            try XCTUnwrap(
                JSONHandler.deserializeData(try XCTUnwrap(request.httpBody)) as? [String: Any])

        XCTAssertNil(decoded["track"], "consent must NOT be wrapped in the track envelope")
        XCTAssertEqual(
            Set(decoded.keys),
            ["action", "profileId", "sourceId", "source", "validUntil", "email", "category"])
        XCTAssertEqual(decoded["action"] as? String, "reject")
        XCTAssertEqual(decoded["source"] as? String, "ios")
    }

    /// One request carries a mixed batch — the shape intemptjs actually sends.
    func testMixedBatchWireShape() throws {
        let models: [IntemptModel] = [
            IdentifyModel(
                envelope: env, name: "Identify", userId: "u_1",
                userAttributes: ["plan": "pro"], data: nil),
            GroupModel(
                envelope: env, name: "Identify", accountId: "acc_1",
                accountAttributes: ["seats": 25]),
            TrackModel(envelope: env, name: "Page View", data: nil),
            ProductModel(envelope: env, name: "Product View", productId: "sku_9", quantity: 2),
        ]

        let request = try Network().makeRequest(
            endpoint: .track(org: "acme", project: "ecommerce", sourceId: "77", useIPForGeolocation: true),
            credentials: creds,
            body: TrackEnvelope.wrap(models: models))

        let decoded =
            try XCTUnwrap(
                JSONHandler.deserializeData(try XCTUnwrap(request.httpBody)) as? [String: Any])
        let entries = try XCTUnwrap(decoded["track"] as? [[String: Any]])

        XCTAssertEqual(entries.count, 4)
        XCTAssertEqual(
            entries.compactMap { $0["type"] as? String },
            ["identify", "group", "track", "product"],
            "all four types travel in ONE request")

        // Every payload satisfies ingestion's identity rule
        for entry in entries {
            let payloads = try XCTUnwrap(entry["payload"] as? [[String: Any]])
            for p in payloads {
                XCTAssertNoThrow(
                    try PayloadValidator.validate(p),
                    "\(entry["type"] ?? "?") payload failed the identity rule")
            }
        }
    }

    /// A Date or NaN reaching the encoder must not silently drop the event.
    func testAwkwardValuesStillProduceAValidBody() throws {
        let model = TrackModel(
            envelope: env,
            name: "Edge",
            data: [
                "when": Date(timeIntervalSince1970: 1_700_000_000),
                "where": URL(string: "https://intempt.com/x")!,
                "bad": Double.nan,
                "flag": true,
            ])

        let request = try Network().makeRequest(
            endpoint: .track(org: "acme", project: "ecommerce", sourceId: "77", useIPForGeolocation: true),
            credentials: creds,
            body: TrackEnvelope.wrap(models: [model]))

        let decoded =
            try XCTUnwrap(
                JSONHandler.deserializeData(try XCTUnwrap(request.httpBody)) as? [String: Any])
        let payload = try XCTUnwrap(
            ((decoded["track"] as? [[String: Any]])?.first?["payload"] as? [[String: Any]])?.first)
        let data = try XCTUnwrap(payload["data"] as? [String: Any])

        XCTAssertEqual(data["when"] as? String, "2023-11-14T22:13:20.000Z")
        XCTAssertEqual(data["where"] as? String, "https://intempt.com/x")
        XCTAssertTrue(data["bad"] is NSNull, "NaN must become null, never the string \"nan\"")
        XCTAssertEqual(data["flag"] as? Bool, true)
    }

    /// End to end: identity -> model -> envelope -> store -> read back ->
    /// request. Proves what is persisted is what gets sent.
    func testPersistedEventReproducesTheSameWireBody() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("golden-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let db = IntemptDB(namespace: "golden", directoryOverride: tmp)
        let model = TrackModel(envelope: env, name: "Checkout Started", data: ["v": 1])

        // Persist the entry exactly as the flush path will
        let entryData = try XCTUnwrap(JSONHandler.encodeAPIData(model.toEnvelopeEntry()))
        XCTAssertTrue(db.insert(.events, data: entryData))

        // Read back and rebuild the request
        let rows = db.read(.events, limit: 10)
        XCTAssertEqual(rows.count, 1)
        let entry = try XCTUnwrap(JSONHandler.deserializeData(rows[0].data) as? [String: Any])

        let request = try Network().makeRequest(
            endpoint: .track(org: "acme", project: "ecommerce", sourceId: "77", useIPForGeolocation: true),
            credentials: creds,
            body: TrackEnvelope.wrap([entry]))

        let decoded =
            try XCTUnwrap(
                JSONHandler.deserializeData(try XCTUnwrap(request.httpBody)) as? [String: Any])
        let entries = try XCTUnwrap(decoded["track"] as? [[String: Any]])
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0]["type"] as? String, "track")
        XCTAssertEqual(entries[0]["name"] as? String, "Checkout Started")

        let payload = try XCTUnwrap((entries[0]["payload"] as? [[String: Any]])?.first)
        XCTAssertEqual(payload["eventId"] as? String, "ev_FIXED-EVENT-ID")
        XCTAssertNoThrow(try PayloadValidator.validate(payload))
    }
}
