import XCTest

@testable import Intempt

/// Every fixture body in this file was captured from a live production response
/// (docs/CONTRACT.md), not invented. A parser tested only against a body the
/// same author imagined proves nothing about the wire.
final class PersonalizationTests: IntemptTestCase {

    private var session: MockSession!

    private func makeClient(
        replies: [MockSession.Reply] = [],
        fallback: MockSession.Reply = .json(200, "{}")
    ) -> Personalization {
        session = MockSession(replies: replies, fallback: fallback)
        return Personalization(
            network: Network(session: session),
            credentials: try! IntemptCredentials(apiKey: "pfx.secret"),
            orgId: "acme", projectId: "web", sourceId: "42")
    }

    // Captured verbatim from POST /optimization/choose-web on the linea project.
    private static let liveChoices = """
        {"choices":[
          {"target":"https://shoplinea.intempt.com/","changes":[],"variant":"8458","updatedAt":1780479018724,"experience":"8038"},
          {"target":"https://shoplinea.intempt.com/","changes":[],"variant":"8461","updatedAt":1780480473903,"experience":"8039"}
        ]}
        """

    // Captured verbatim from POST /feeds/5258/data with fields=[title,price,imageUrl,productId].
    private static let liveProducts = """
        {"products":[
          {"title":"Acanthus","price":0.0,"imageUrl":null,"productId":null},
          {"title":"Anthemion","price":0.0,"imageUrl":null,"productId":null},
          {"title":"Palmette","price":0.0,"imageUrl":null,"productId":null}
        ]}
        """

    // MARK: - Experiments: request shape

    // MARK: - Experiments: response parsing

    // MARK: - Products: the 443x defect

    /// Verified live: the same 10 products are 503 bytes with `fields` and
    /// 222,919 bytes without, because the unfielded response includes raw ML
    /// embedding vectors. An unfielded request must never leave the device.
    func testProductsAlwaysSendsFields() {
        let client = makeClient()
        let done = expectation(description: "products")
        client.products(
            feedId: "5258", profileId: "pr_1", count: 5, fields: []
        ) { _ in done.fulfill() }
        wait(for: [done], timeout: 2)

        let fields = session.bodies[0]["fields"] as? [String]
        XCTAssertNotNil(fields, "fields must always be present")
        XCTAssertFalse(fields!.isEmpty, "an empty list reads as absent to the server")
        XCTAssertEqual(fields, Personalization.defaultFields)
    }

    func testExplicitFieldsAreHonoured() {
        let client = makeClient()
        let done = expectation(description: "products")
        client.products(
            feedId: "5258", profileId: "pr_1", count: 5, fields: ["title", "sku"]
        ) { _ in done.fulfill() }
        wait(for: [done], timeout: 2)
        XCTAssertEqual(session.bodies[0]["fields"] as? [String], ["title", "sku"])
    }

    // MARK: - Products: request shape

    /// feeds/{id}/data takes a FLAT body. choose-api nests under
    /// `identification`. The two endpoints really do differ, and sending one
    /// shape to the other's endpoint fails.
    func testProductsBodyIsFlatNotIdentificationWrapped() {
        let client = makeClient()
        let done = expectation(description: "products")
        client.products(
            feedId: "5258", profileId: "pr_1", count: 3, fields: ["title"]
        ) { _ in done.fulfill() }
        wait(for: [done], timeout: 2)

        let body = session.bodies[0]
        XCTAssertNil(body["identification"], "feeds does NOT use the identification wrapper")
        XCTAssertEqual(body["profileId"] as? String, "pr_1")
        XCTAssertEqual(body["sourceId"] as? String, "42")
        XCTAssertEqual(body["limit"] as? Int, 3)
    }

    func testProductsURLCarriesTheFeedId() {
        let client = makeClient()
        let done = expectation(description: "products")
        client.products(feedId: "5258", profileId: "pr_1", count: 1, fields: ["title"]) { _ in
            done.fulfill()
        }
        wait(for: [done], timeout: 2)
        XCTAssertEqual(
            session.requests[0].url?.absoluteString,
            "https://api.intempt.com/v1/acme/projects/web/feeds/5258/data")
    }

    /// `limit: 0` returns nothing, so a caller that forgets to set a count gets
    /// silence rather than a diagnosable error.
    func testCountIsClampedToAtLeastOne() {
        let client = makeClient()
        let done = expectation(description: "products")
        client.products(feedId: "5258", profileId: "pr_1", count: 0, fields: ["title"]) { _ in
            done.fulfill()
        }
        wait(for: [done], timeout: 2)
        XCTAssertEqual(session.bodies[0]["limit"] as? Int, 1)
    }

    // MARK: - Products: response parsing

    func testParsesLiveProductsResponse() {
        let json = JSONHandler.deserializeData(Data(Self.liveProducts.utf8)) as! [String: Any]
        let products = Personalization.parseProducts(json)

        XCTAssertEqual(products.count, 3)
        XCTAssertEqual(products.map(\.title), ["Acanthus", "Anthemion", "Palmette"])
    }

    /// The live feed returns `"imageUrl":null` and `"productId":null`. Rendering
    /// those via String(describing:) produces the literal "<null>" in a label.
    func testNullAttributesAreOmittedNotStringified() {
        let json = JSONHandler.deserializeData(Data(Self.liveProducts.utf8)) as! [String: Any]
        let product = Personalization.parseProducts(json)[0]

        XCTAssertNil(product.imageURL)
        XCTAssertNil(product.productId)
        XCTAssertNil(product["imageUrl"])
        XCTAssertFalse(
            product.attributes.values.contains { $0.contains("null") },
            "a null must never reach a UI as the text \"<null>\"")
    }

    /// The live feed sends `"price":0.0`. "0.0" in a price label is wrong.
    ///
    /// This guards `NSNumber.stringValue` specifically. Interpolating the
    /// double instead — `"\(n.doubleValue)"`, the obvious-looking shortcut —
    /// yields "0.0" and fails here.
    func testWholeNumbersRenderWithoutADecimalTail() {
        let json = JSONHandler.deserializeData(Data(Self.liveProducts.utf8)) as! [String: Any]
        let product = Personalization.parseProducts(json)[0]

        XCTAssertEqual(product["price"], "0", "0.0 must render as 0, not \"0.0\"")
        XCTAssertEqual(product.price, 0)
    }

    func testFractionalPricesKeepTheirPrecision() {
        let body = #"{"products":[{"title":"X","price":129.99}]}"#
        let json = JSONHandler.deserializeData(Data(body.utf8)) as! [String: Any]
        let product = Personalization.parseProducts(json)[0]
        XCTAssertEqual(product["price"], "129.99")
        XCTAssertEqual(product.price ?? 0, 129.99, accuracy: 0.001)
    }

    /// A widened `fields` can pull in `intempt_image_vector` — hundreds of
    /// floats per product. Flattening it into a label string is useless and
    /// enormous, so vector columns are skipped.
    func testVectorColumnsAreSkipped() {
        let body = """
            {"products":[{"title":"X","intempt_image_vector":[0.0015,-0.0037,0.0091]}]}
            """
        let json = JSONHandler.deserializeData(Data(body.utf8)) as! [String: Any]
        let product = Personalization.parseProducts(json)[0]

        XCTAssertEqual(product.title, "X")
        XCTAssertNil(product["intempt_image_vector"], "array columns must not be stringified")
        XCTAssertEqual(product.attributes.count, 1)
    }

    /// Verified live: a PRODUCT-input feed called without `productId` returns
    /// 200 with an empty array — indistinguishable from "no recommendations".
    func testEmptyProductsIsSuccessNotFailure() {
        let client = makeClient(replies: [.json(200, #"{"products":[]}"#)])
        var result: Result<[ProductRecommendation], IntemptError>?
        let done = expectation(description: "products")
        client.products(feedId: "4874", profileId: "pr_1", count: 2, fields: ["title"]) {
            result = $0
            done.fulfill()
        }
        wait(for: [done], timeout: 2)

        guard case .success(let products) = result else { return XCTFail("expected success") }
        XCTAssertTrue(products.isEmpty)
    }

    // MARK: - Error surfacing

    /// "Invalid feed id: nonexistent" is actionable. "400" is not.
    func testServerMessageIsSurfaced() {
        let client = makeClient(
            replies: [.serverError(400, "Invalid feed id: nonexistent")])
        var result: Result<[ProductRecommendation], IntemptError>?
        let done = expectation(description: "products")
        client.products(feedId: "nope", profileId: "pr_1", count: 1, fields: ["title"]) {
            result = $0
            done.fulfill()
        }
        wait(for: [done], timeout: 2)

        guard case .failure(let error) = result else { return XCTFail("expected failure") }
        XCTAssertEqual(error, .server(status: 400, messages: ["Invalid feed id: nonexistent"]))
        XCTAssertTrue(error.description.contains("Invalid feed id"))
    }

    func testIdentificationRequiredMessageIsSurfaced() {
        let client = makeClient(replies: [.serverError(400, "Identification is required")])
        var result: Result<[ProductRecommendation], IntemptError>?
        let done = expectation(description: "products")
        client.products(feedId: "9", profileId: "", count: 5, fields: ["id"]) {
            result = $0
            done.fulfill()
        }
        wait(for: [done], timeout: 2)

        guard case .failure(let error) = result else { return XCTFail("expected failure") }
        XCTAssertEqual(error, .server(status: 400, messages: ["Identification is required"]))
    }

    /// A 401 with no body must still be reported, not swallowed into an empty
    /// success — the caller needs to know personalization is misconfigured.
    func testTerminalWithoutBodyFallsBackToStatus() {
        let client = makeClient(replies: [.status(401)])
        var result: Result<[ProductRecommendation], IntemptError>?
        let done = expectation(description: "products")
        client.products(feedId: "9", profileId: "pr_1", count: 5, fields: ["id"]) {
            result = $0
            done.fulfill()
        }
        wait(for: [done], timeout: 2)

        guard case .failure(let error) = result else { return XCTFail("expected failure") }
        XCTAssertEqual(error, .terminal(status: 401))
    }

    func testRetryableIsReportedAsRetryable() {
        let client = makeClient(replies: [.status(503, headers: ["Retry-After": "12"])])
        var result: Result<[ProductRecommendation], IntemptError>?
        let done = expectation(description: "products")
        client.products(feedId: "9", profileId: "pr_1", count: 5, fields: ["id"]) {
            result = $0
            done.fulfill()
        }
        wait(for: [done], timeout: 2)

        guard case .failure(let error) = result else { return XCTFail("expected failure") }
        XCTAssertEqual(error, .retryable(status: 503, retryAfter: 12))
    }

    func testTransportFailureIsReported() {
        let client = makeClient(replies: [.offline()])
        var result: Result<[ProductRecommendation], IntemptError>?
        let done = expectation(description: "products")
        client.products(feedId: "9", profileId: "pr_1", count: 5, fields: ["id"]) {
            result = $0
            done.fulfill()
        }
        wait(for: [done], timeout: 2)

        guard case .failure(let error) = result else { return XCTFail("expected failure") }
        if case .transport = error {} else { XCTFail("expected transport, got \(error)") }
    }

    /// 2xx with an unreadable body: there is nothing to serve, but nothing the
    /// caller can act on either. Empty success, not a fabricated error.
    func testSuccessWithUnparseableBodyYieldsEmpty() {
        let client = makeClient(replies: [.json(200, "not json at all")])
        var result: Result<[ProductRecommendation], IntemptError>?
        let done = expectation(description: "products")
        client.products(feedId: "9", profileId: "pr_1", count: 5, fields: ["id"]) {
            result = $0
            done.fulfill()
        }
        wait(for: [done], timeout: 2)

        guard case .success(let choices) = result else { return XCTFail("expected success") }
        XCTAssertTrue(choices.isEmpty)
    }

    // MARK: - Device class

    func testDeviceClassIsPlatformAppropriate() {
        #if os(macOS)
            XCTAssertEqual(Personalization.deviceClass, "desktop")
        #elseif os(tvOS)
            XCTAssertEqual(Personalization.deviceClass, "tv")
        #else
            XCTAssertEqual(Personalization.deviceClass, "mobile")
        #endif
    }

    // MARK: - Number rendering

    func testPlainNumberRendering() {
        XCTAssertEqual(Personalization.plain(NSNumber(value: 0.0)), "0")
        XCTAssertEqual(Personalization.plain(NSNumber(value: 8458)), "8458")
        XCTAssertEqual(Personalization.plain(NSNumber(value: 8458.0)), "8458")
        XCTAssertEqual(Personalization.plain(NSNumber(value: 129.99)), "129.99")
        XCTAssertEqual(Personalization.plain(NSNumber(value: true)), "true")
        XCTAssertEqual(Personalization.plain(NSNumber(value: -3.0)), "-3")
    }
}

// MARK: - Untyped bridge for migrating off the Objective-C SDK

extension PersonalizationTests {

    /// `JSONValue` is how an untyped server value crosses into Swift, and
    /// consumers convert it straight back to `[String: Any]`. Nested values and
    /// booleans are the two that break: a bool arriving as 1 changes a branch.
    ///
    /// Previously exercised through the experiment-choice parser; that parser is
    /// gone, so this goes at `JSONValue` directly rather than losing the case.
    func testBodyConvertsToAnUntypedDictionary() {
        let response = """
            {"type":"number","count":3,"live":true,"nested":{"a":1},"tags":["x","y"]}
            """
        let json = JSONHandler.deserializeData(Data(response.utf8)) as! [String: Any]
        let dict = JSONValue.from(json).dictionaryValue

        XCTAssertNotNil(dict)
        XCTAssertEqual(dict?["type"] as? String, "number")
        XCTAssertEqual(dict?["count"] as? Double, 3)
        // A bool must survive as a bool, not as 1 — consumers branch on it.
        XCTAssertEqual(dict?["live"] as? Bool, true)
        XCTAssertEqual((dict?["nested"] as? [String: Any])?["a"] as? Double, 1)
        XCTAssertEqual(dict?["tags"] as? [String], ["x", "y"])
    }

    func testDictionaryValueIsNilForNonObjects() {
        XCTAssertNil(JSONValue.string("x").dictionaryValue)
        XCTAssertNil(JSONValue.array([.number(1)]).dictionaryValue)
        XCTAssertNil(JSONValue.null.dictionaryValue)
    }
}
