import XCTest

@testable import Intempt

// MARK: - Control interaction naming

/// These two names are the whole distinction between "someone pressed a button"
/// and "someone changed a value", and they are consumed by the iOS source
/// schema, by the docs, and by the cross-SDK contract's one-interaction-one-event
/// rule.
///
/// The decision used to live inside `#if canImport(UIKit)`, which `swift test`
/// on macOS excludes entirely — so swapping the two names passed every test.
/// Mutation testing found it; this is the test that kills it.
final class ControlInteractionNamingTests: XCTestCase {

    func testValueChangeIsEditField() {
        XCTAssertEqual(EventNames.controlInteraction(isValueChange: true), "Edit Field")
    }

    func testNonValueChangeIsAction() {
        XCTAssertEqual(EventNames.controlInteraction(isValueChange: false), "Action")
    }

    /// Guards the swap directly: whatever the names are, they must not be equal,
    /// and each must match the constant the schema provisions.
    func testTheTwoNamesAreNotInterchangeable() {
        let change = EventNames.controlInteraction(isValueChange: true)
        let press = EventNames.controlInteraction(isValueChange: false)

        XCTAssertNotEqual(change, press)
        XCTAssertEqual(change, EventNames.editField)
        XCTAssertEqual(press, EventNames.action)
    }
}
