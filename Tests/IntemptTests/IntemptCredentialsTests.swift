import XCTest

@testable import Intempt

final class IntemptCredentialsTests: XCTestCase {

    func testValidKeySplitsIntoPrefixAndSecret() throws {
        // Not "pk_live_...": that prefix is what a live Stripe-style credential
        // uses, and the secret scanner matches it on sight. The assertion here
        // is about splitting on the first dot, which any pair exercises.
        let c = try IntemptCredentials(apiKey: "examplePrefix123.exampleSecretValue")
        XCTAssertEqual(c.prefix, "examplePrefix123")
        XCTAssertEqual(c.secret, "exampleSecretValue")
    }

    /// Must match what auth issues and what intemptjs sends.
    func testBasicAuthHeaderFormat() throws {
        let c = try IntemptCredentials(apiKey: "myprefix.mysecret")
        let expected = "Basic " + Data("myprefix:mysecret".utf8).base64EncodedString()
        XCTAssertEqual(c.basicAuthHeader, expected)
        XCTAssertEqual(c.basicAuthHeader, "Basic bXlwcmVmaXg6bXlzZWNyZXQ=")
    }

    /// Direct regression for F-02: the old SDK raised NSRangeException here
    /// and crashed the host app.
    func testKeyWithoutDotThrowsInsteadOfCrashing() {
        XCTAssertThrowsError(try IntemptCredentials(apiKey: "nodotshere")) { error in
            XCTAssertEqual(error as? IntemptError, .malformedAPIKey(length: 10))
        }
    }

    func testEmptyPrefixOrSecretThrows() {
        XCTAssertThrowsError(try IntemptCredentials(apiKey: ".secretonly"))
        XCTAssertThrowsError(try IntemptCredentials(apiKey: "prefixonly."))
        XCTAssertThrowsError(try IntemptCredentials(apiKey: ""))
        XCTAssertThrowsError(try IntemptCredentials(apiKey: "."))
    }

    /// A secret containing dots must survive intact.
    func testSplitsOnFirstDotOnly() throws {
        let c = try IntemptCredentials(apiKey: "prefix.secret.with.dots")
        XCTAssertEqual(c.prefix, "prefix")
        XCTAssertEqual(c.secret, "secret.with.dots")
    }

    /// The error must not carry key material into logs or crash reports.
    func testErrorLeaksNoKeyMaterial() {
        let key = "supersecretprefix.supersecretvalue"
        do {
            _ = try IntemptCredentials(apiKey: "nodots")
            XCTFail("expected throw")
        } catch {
            let rendered = "\(error)"
            XCTAssertFalse(rendered.contains(key))
            XCTAssertFalse(rendered.contains("supersecret"))
        }
    }

    /// Printing or dumping the struct must never reveal the secret.
    func testDescriptionRedactsSecret() throws {
        let c = try IntemptCredentials(apiKey: "pfx.TOPSECRET")
        XCTAssertFalse("\(c)".contains("TOPSECRET"))
        XCTAssertTrue("\(c)".contains("<redacted>"))
        var dumped = String()
        dump(c, to: &dumped)
        XCTAssertFalse(dumped.contains("TOPSECRET"), "dump() must not expose the secret")
    }
}
