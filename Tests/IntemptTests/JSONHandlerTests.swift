import XCTest

@testable import Intempt

final class JSONHandlerTests: XCTestCase {

    private func encodeToString(_ obj: Any) -> String? {
        guard let d = JSONHandler.encodeAPIData(obj) else { return nil }
        return String(decoding: d, as: UTF8.self)
    }

    func testEncodesSimpleObject() {
        XCTAssertNotNil(JSONHandler.encodeAPIData(["key": "value", "num": 1]))
    }

    /// Regression: a Date in the payload previously returned nil, silently
    /// dropping the entire event.
    func testDateIsSerializedNotDropped() {
        let fixed = Date(timeIntervalSince1970: 1_700_000_000)
        let json = encodeToString(["at": fixed])
        XCTAssertNotNil(json)
        XCTAssertTrue(
            json!.contains("2023-11-14T22:13:20.000Z"),
            "expected the ingestion-compatible UTC format, got: \(json!)")
    }

    func testURLIsSerializedAsString() {
        let json = encodeToString(["link": URL(string: "https://intempt.com")!])
        XCTAssertEqual(json, "{\"link\":\"https:\\/\\/intempt.com\"}")
    }

    /// Objective-C bridges Bool to NSNumber; without the CFBoolean check this
    /// serialises as 1 and the backend sees a number where a boolean belongs.
    func testBridgedBoolStaysBoolean() {
        let json = encodeToString(["flag": NSNumber(value: true)])
        XCTAssertEqual(json, "{\"flag\":true}")
    }

    /// Better than upstream: a non-finite number becomes null rather than the
    /// string "nan", which would land a string in a numeric column.
    func testNonFiniteNumberBecomesNullNotString() {
        let json = encodeToString(["v": Double.nan])
        XCTAssertNotNil(json)
        XCTAssertEqual(json, "{\"v\":null}")
        XCTAssertFalse(json!.contains("nan"), "must not stringify NaN")
    }

    func testInfinityBecomesNull() {
        XCTAssertEqual(encodeToString(["v": Double.infinity]), "{\"v\":null}")
    }

    /// One malformed element must not kill an entire batch.
    func testTopLevelArrayDropsOnlyInvalidElements() {
        struct Unsupported {}
        let arr: [Any] = [["ok": 1], ["bad": Unsupported()]]
        let data = JSONHandler.encodeAPIData(arr)
        XCTAssertNotNil(data, "a single bad element must not fail the whole array")
    }

    func testNestedStructuresRoundTrip() {
        let obj: [String: Any] = [
            "a": 1,
            "b": ["c": "d"],
            "e": [1, 2, 3],
        ]
        let data = JSONHandler.encodeAPIData(obj)!
        let back = JSONHandler.deserializeData(data) as? [String: Any]
        XCTAssertEqual(back?["a"] as? Int, 1)
        XCTAssertEqual((back?["b"] as? [String: Any])?["c"] as? String, "d")
        XCTAssertEqual(back?["e"] as? [Int], [1, 2, 3])
    }

    func testNilInsideArrayIsDropped() {
        let arr: [Any?] = [1, nil, 3]
        let data = JSONHandler.encodeAPIData(["items": arr])
        XCTAssertNotNil(data)
        let back = JSONHandler.deserializeData(data!) as? [String: Any]
        XCTAssertEqual((back?["items"] as? [Int])?.count, 2)
    }

    func testDeserializeGarbageReturnsNil() {
        XCTAssertNil(JSONHandler.deserializeData(Data([0x00, 0x01, 0x02])))
    }
}
