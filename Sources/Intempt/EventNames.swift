//
//  EventNames.swift
//  Intempt
//
//  Copyright © 2026 Intempt Technologies, Inc.
//  Licensed under the Apache License, Version 2.0.
//
//  No mixpanel-swift equivalent: upstream's automatic events are `$ae_`-prefixed
//  names of its own invention. Intempt's names must match what the JS SDK
//  already writes, or a funnel built on web data silently excludes iOS.
//
//  Every value below is copied from intemptjs, not chosen:
//    IntemptEventName          constants.types.ts:1-11
//    session event name        sessionTracker.module.ts:11
//
import Foundation

/// Event titles shared with the JS SDK.
///
/// These are wire values. Changing one splits a funnel in two — an analyst
/// filtering on "Added to cart" would stop seeing iOS carts — so each is
/// pinned by a parity test against the JS source.
enum EventNames {

    // MARK: Commerce — intemptjs IntemptEventName

    /// intemptjs `PRODUCT_VIEW`. Note it is NOT "Product View": the JS value is
    /// past tense and lowercase-v.
    static let productView = "Product viewed"

    /// intemptjs `PRODUCT_ADD`. Note it is NOT "Product Add" — the JS value
    /// does not mention the word "product" at all.
    static let productAdd = "Added to cart"

    /// intemptjs `PRODUCT_ORDER`. Lowercase "ordered".
    static let productOrdered = "Product ordered"

    // MARK: Interaction — intemptjs IntemptEventName

    /// intemptjs `PAGE_VIEW`. A `UIViewController` appearing is the native
    /// analogue of a page view, so screen autocapture reuses this name and a
    /// web funnel keeps working across platforms.
    static let viewPage = "View Page"

    /// intemptjs `PAGE_LEAVE`.
    static let leavePage = "Leave Page"

    /// intemptjs `CLICK_ON`. Used by touch autocapture.
    static let clickOn = "Click On"

    /// intemptjs `CHANGE_ON`. Used by control autocapture.
    static let changeOn = "Change On"

    /// intemptjs `SUBMIT_ON`.
    static let submitOn = "Submit On"

    // MARK: Session

    /// The value intemptjs actually sends, from `sessionTracker._eventName`.
    ///
    /// intemptjs is internally inconsistent here: its `IntemptEventName`
    /// enum declares `SESSION_START = "Session Start"` with a capital S, but
    /// the session tracker never reads that case and hardcodes
    /// `'Session start'` instead. The lowercase form is what reaches ingestion,
    /// so it is what we send. Matching the enum instead would look more correct
    /// and produce a name no existing report filters on.
    static let sessionStart = "Session start"

    // MARK: Native-only lifecycle

    /// No JS counterpart — a browser has no install or update moment.
    static let applicationInstalled = "Application Installed"
    static let applicationUpdated = "Application Updated"
    static let applicationOpened = "Application Opened"
    static let applicationBackgrounded = "Application Backgrounded"

    /// Push, also native-only.
    static let pushReceived = "Push Received"
    static let pushOpened = "Push Opened"
}

/// Keys used by automatic events. camelCase, matching intemptjs.
enum EventKeys {
    static let sessionStartEventName = "sessionStartEventName"
    static let source = "source"
    static let screenName = "screenName"
    static let previousVersion = "previousVersion"
    static let currentVersion = "currentVersion"
    static let elementType = "elementType"
    static let elementLabel = "elementLabel"
    static let elementIdentifier = "elementIdentifier"
    static let viewHierarchy = "viewHierarchy"
    static let campaignId = "campaignId"
    static let notificationTitle = "notificationTitle"
}

/// Public mirror of `AutomaticEvents.Options`.
///
/// A separate public type rather than making the internal one public: the
/// internal struct is free to grow fields that are not part of the supported
/// surface, and a public struct's memberwise initialiser is API.
public struct AutomaticEventOptions: Equatable, Sendable {
    /// "Session start", carrying device facts as user attributes. On by default.
    public var sessions: Bool
    /// "Application Installed" / "Application Updated", once per version.
    public var versionChanges: Bool
    /// "Application Opened" / "Application Backgrounded" on every transition.
    public var appStateChanges: Bool

    public init(
        sessions: Bool = true,
        versionChanges: Bool = false,
        appStateChanges: Bool = false
    ) {
        self.sessions = sessions
        self.versionChanges = versionChanges
        self.appStateChanges = appStateChanges
    }
}
