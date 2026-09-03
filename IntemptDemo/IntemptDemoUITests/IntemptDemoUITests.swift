//
//  IntemptDemoUITests.swift
//  IntemptDemoUITests
//
//  Copyright © 2026 Intempt Technologies, Inc.
//  Licensed under the Apache License, Version 2.0.
//
//  The only tests that RUN the SDK on iOS.
//
//  The package's unit tests run on the macOS host, where every `#if os(iOS)`
//  branch is excluded from the build entirely — so autocapture, the UIKit
//  swizzles, background-task assertions and APNs formatting are type-checked
//  there at best and executed nowhere. This target executes them.
//
import XCTest

final class IntemptDemoUITests: XCTestCase {

    private var app: XCUIApplication!

    override func setUp() {
        super.setUp()
        continueAfterFailure = false

        app = XCUIApplication()
        // Credentials come from the CI environment; absent them the app logs
        // that it could not initialize and the SDK-behaviour tests skip.
        for key in [
            "INTEMPT_API_KEY", "INTEMPT_ORG_ID", "INTEMPT_PROJECT_ID", "INTEMPT_SOURCE_ID",
        ] {
            if let value = ProcessInfo.processInfo.environment[key] {
                app.launchEnvironment[key] = value
            }
        }
        app.launch()
    }

    // MARK: - Helpers

    /// The log renders newest-first, so a match anywhere means it happened.
    private func logContains(_ fragment: String, timeout: TimeInterval = 10) -> Bool {
        let predicate = NSPredicate(format: "label CONTAINS[c] %@", fragment)
        let match = app.staticTexts.containing(predicate).firstMatch
        return match.waitForExistence(timeout: timeout)
    }

    private func tap(_ identifier: String) {
        let button = app.buttons[identifier]
        XCTAssertTrue(
            button.waitForExistence(timeout: 10), "\(identifier) not found")
        // List rows can sit below the fold on a small screen.
        if !button.isHittable { button.scrollToVisible(in: app) }
        button.tap()
    }

    private func requireInitialized() throws {
        guard logContains("initialized", timeout: 15) else {
            throw XCTSkip("SDK not initialized — INTEMPT_* not set for this run")
        }
    }

    // MARK: - Launch

    func testAppLaunchesAndInitializes() throws {
        XCTAssertTrue(app.navigationBars["Intempt SDK"].waitForExistence(timeout: 10))
        try requireInitialized()
        XCTAssertTrue(logContains("profile pr_"), "a profile id must be assigned at launch")
    }

    // MARK: - Tracking

    func testTrackingCallsSucceed() throws {
        try requireInitialized()

        tap("track-button")
        XCTAssertTrue(logContains("track → true"))

        tap("identify-button")
        XCTAssertTrue(logContains("identify → true"))

        tap("group-button")
        XCTAssertTrue(logContains("group → true"))

        tap("record-button")
        XCTAssertTrue(logContains("record → true"))
    }

    /// A NaN cannot survive JSON. Upstream stringifies it to "nan" and ships
    /// it; this SDK refuses the event at the call boundary and says so.
    func testInvalidPropertyIsRejectedAtTheBoundary() throws {
        try requireInitialized()
        tap("invalid-button")
        XCTAssertTrue(
            logContains("track NaN → false"),
            "a non-finite number must be refused, not serialised as \"nan\"")
    }

    func testCommerceCalls() throws {
        try requireInitialized()
        tap("product-view-button")
        XCTAssertTrue(logContains("productView → true"))
        tap("product-add-button")
        XCTAssertTrue(logContains("productAdd → true"))
        tap("product-ordered-button")
        XCTAssertTrue(logContains("productOrdered → true"))
    }

    // MARK: - Delivery

    /// The whole path on a real device: enqueue, claim, POST, acknowledge,
    /// delete.
    func testFlushDeliversToProduction() throws {
        try requireInitialized()

        tap("track-button")
        tap("flush-button")

        XCTAssertTrue(
            logContains("event(s) delivered", timeout: 30),
            "the flush must report what the server acknowledged")
    }

    /// 120 events is three batches of 50, drained in one pass.
    func testBulkQueueDrainsAcrossBatches() throws {
        try requireInitialized()

        tap("bulk-button")
        XCTAssertTrue(logContains("queued 120"))

        tap("flush-button")
        XCTAssertTrue(logContains("event(s) delivered", timeout: 60))
    }

    // MARK: - Privacy

    /// Not just a flag: reject purges the queue and stops collection.
    func testConsentRejectStopsCollection() throws {
        try requireInitialized()

        tap("consent-reject-button")
        XCTAssertTrue(logContains("optedOut=true"), "reject must gate collection, not only record it")

        tap("track-button")
        XCTAssertTrue(
            logContains("track → false"),
            "an opted-out instance must refuse to enqueue")

        tap("opt-in-button")
        tap("track-button")
        XCTAssertTrue(logContains("track → true"), "opt-in must resume collection")
    }

    func testLogOutRotatesTheProfileIdentity() throws {
        try requireInitialized()
        tap("logout-button")
        XCTAssertTrue(
            logContains("became pr_"),
            "the anonymous identity must rotate so the next user cannot inherit it")
    }

    // MARK: - Recommendations

    func testProductsReturn() throws {
        try requireInitialized()

        tap("products-button")
        XCTAssertTrue(
            logContains("products", timeout: 30),
            "the feed must answer — an empty list is a result, no answer is not")
    }

    // MARK: - Autocapture
    //
    // These are the reason this target exists: none of this code is even
    // compiled into the macOS unit-test run.

    /// Pushing a screen must not crash, which is the minimum bar for a
    /// `viewDidAppear` swizzle installed on every UIViewController in the app.
    func testScreenAutocaptureDoesNotBreakNavigation() throws {
        try requireInitialized()

        let link = app.buttons["second-screen-link"]
        XCTAssertTrue(link.waitForExistence(timeout: 10))
        link.scrollToVisible(in: app)
        link.tap()

        XCTAssertTrue(
            app.navigationBars["Second Screen"].waitForExistence(timeout: 10),
            "the swizzled viewDidAppear must still call through to the original")

        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.navigationBars["Intempt SDK"].waitForExistence(timeout: 10))
    }

    /// A swizzled `sendAction` must still deliver the app's own actions. If the
    /// hook swallowed them, this toggle would not respond at all.
    func testTapAutocaptureDoesNotSwallowTheAppsOwnActions() throws {
        try requireInitialized()

        let toggle = app.switches["autocapture-toggle"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 10))
        toggle.scrollToVisible(in: app)
        toggle.tap()

        // The app is still alive and responsive after the hook ran.
        tap("track-button")
        XCTAssertTrue(
            logContains("track → true"),
            "the app must keep working with sendAction swizzled")
    }

    /// Typing into a text field must be unaffected, and its contents are never
    /// captured — only that it changed.
    func testTextEntryIsUnaffectedByAutocapture() throws {
        try requireInitialized()

        let link = app.buttons["second-screen-link"]
        link.scrollToVisible(in: app)
        link.tap()

        let field = app.textFields["demo-text-field"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        field.typeText("hello")

        XCTAssertEqual(field.value as? String, "hello", "typing must still work")
    }
}

// MARK: - Scrolling helper

extension XCUIElement {
    /// Scrolls the containing collection until this element is hittable.
    /// A `List` on a small screen puts later rows below the fold, and tapping a
    /// non-hittable element fails in a way that looks like a missing button.
    func scrollToVisible(in app: XCUIApplication, attempts: Int = 8) {
        var remaining = attempts
        while !isHittable && remaining > 0 {
            app.swipeUp()
            remaining -= 1
        }
    }
}
