import XCTest

@testable import Intempt

final class IntemptTypeTests: XCTestCase {

    func testScalarsAreValid() {
        XCTAssertTrue("s".isValidNestedTypeAndValue())
        XCTAssertTrue(1.isValidNestedTypeAndValue())
        XCTAssertTrue(UInt(1).isValidNestedTypeAndValue())
        XCTAssertTrue(true.isValidNestedTypeAndValue())
        XCTAssertTrue(Date().isValidNestedTypeAndValue())
        XCTAssertTrue(URL(string: "https://intempt.com")!.isValidNestedTypeAndValue())
        XCTAssertTrue(NSNull().isValidNestedTypeAndValue())
        XCTAssertTrue(1.5.isValidNestedTypeAndValue())
    }

    func testNaNAndInfinityAreRejected() {
        XCTAssertFalse(Double.nan.isValidNestedTypeAndValue())
        XCTAssertFalse(Double.infinity.isValidNestedTypeAndValue())
        XCTAssertFalse((-Double.infinity).isValidNestedTypeAndValue())
        XCTAssertFalse(Float.nan.isValidNestedTypeAndValue())
        XCTAssertFalse(NSNumber(value: Double.nan).isValidNestedTypeAndValue())
    }

    /// The exact shape every model uses. If this file compiles at all, the
    /// conditional-conformance defect that broke the earlier draft is gone.
    func testDictionaryOfExistentialsCompilesAndValidates() {
        let good: [String: IntemptType] = ["name": "Sid", "count": 3, "ok": true]
        XCTAssertTrue(good.isValidNestedTypeAndValue())

        let bad: [String: IntemptType] = ["name": "Sid", "bad": Double.nan]
        XCTAssertFalse(bad.isValidNestedTypeAndValue())
    }

    func testArrayValidation() {
        XCTAssertTrue([1, 2, 3].isValidNestedTypeAndValue())
        XCTAssertFalse([1.0, Double.nan].isValidNestedTypeAndValue())
    }

    /// Improvement over upstream, which validates only one level deep: a NaN
    /// buried inside a nested dictionary must still poison the whole payload.
    func testDeeplyNestedInvalidValueIsCaught() {
        let nested: [String: IntemptType] = [
            "outer": ["middle": ["inner": Double.nan] as [String: IntemptType]]
                as [String: IntemptType]
        ]
        XCTAssertFalse(
            nested.isValidNestedTypeAndValue(),
            "a NaN nested two levels deep must be rejected")
    }

    func testNonStringKeysAreRejected() {
        let intKeyed: [Int: Int] = [1: 1]
        XCTAssertFalse(intKeyed.isValidNestedTypeAndValue())
    }

    func testUnsupportedValueTypeIsRejected() {
        struct Custom {}
        let dict: [String: Any] = ["x": Custom()]
        XCTAssertFalse(dict.isValidNestedTypeAndValue())
    }
}
