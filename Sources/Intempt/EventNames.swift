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

    // MARK: Autocapture — the iOS SOURCE schema, not intemptjs
    //
    // These deliberately DIVERGE from the web SDK, and that is not an
    // oversight. The backend provisions a different set of collections for an
    // iOS source than for a web source
    // (single-metadata IosSourceInitialization.java:38-46). An iOS source gets
    // exactly nine: Identify, SessionStart, SessionEnd, LeaveScreen,
    // ViewScreen, Touch, Action, EditField, AppInstallUpgrade — each with its
    // own typed Avro schema under `com.intempt.data.source.ios.`.
    //
    // Sending intemptjs's "Click On" to an iOS source would match no
    // collection, leaving the provisioned `Touch` collection permanently
    // empty. Cross-SDK consistency is the rule everywhere the two agree; where
    // the backend defines a platform-specific contract, the backend wins.
    //
    // Session start is the happy case: both agree on "Session start".

    /// iOS `ViewScreen` collection. The web SDK's equivalent is "View Page".
    static let viewScreen = "View screen"

    /// iOS `LeaveScreen` collection.
    static let leaveScreen = "Leave screen"

    /// iOS `Touch` collection. The web SDK's equivalent is "Click On".
    static let touch = "Touch"

    /// iOS `EditField` collection. The web SDK's equivalent is "Change On".
    static let editField = "Edit Field"

    /// iOS `Action` collection — a control action that is not a value edit.
    static let action = "Action"

    /// iOS `SessionEnd` collection.
    static let sessionEnd = "Session end"

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

    /// iOS `AppInstallUpgrade` collection. One title covers both, matching the
    /// backend: the collection is "App Install/Upgrade", not two collections.
    /// `data.installType` distinguishes them.
    static let appInstallUpgrade = "App Install/Upgrade"

    /// No collection provisioned for these; they are emitted only when the
    /// integrator opts in to `appStateChanges`.
    static let applicationOpened = "Application Opened"
    static let applicationBackgrounded = "Application Backgrounded"

    /// Push, also native-only.
    static let pushReceived = "Push Received"
    static let pushOpened = "Push Opened"
}

/// Payload field names, taken from the iOS source Avro schemas.
///
/// These are NOT free choices. `single-metadata/src/main/resources/schema/
/// com.intempt.data.source.ios/*.json` defines the record shape for every iOS
/// collection, and a field that is not in the schema has no column to land in.
/// The HTTP layer accepts it — ingestion returns 201 for arbitrary payloads —
/// so a wrong name here is SILENT data loss: the event is stored, the property
/// is gone, and nothing anywhere reports a problem.
///
/// An earlier version of this file invented `screenName`, `elementType`,
/// `elementLabel`, `elementIdentifier` and `viewHierarchy`. None of those
/// exists in any iOS schema.
enum EventKeys {

    // MARK: ViewScreen.json → data

    /// The view controller's class name. NOT "screenName".
    static let viewController = "viewController"
    static let viewControllerAccessibilityIdentifier = "viewControllerAccessibilityIdentifier"
    static let viewControllerAccessibilityLabel = "viewControllerAccessibilityLabel"

    // MARK: Touch.json / EditField.json → data
    //
    // Both collections share one record shape.

    static let actionMethod = "actionMethod"
    /// Developer-authored control copy (a button title). Never a text field's
    /// contents — see Autocapture.
    static let targetText = "targetText"
    static let targetViewClass = "targetViewClass"
    static let targetViewName = "targetViewName"
    static let targetAccessibilityIdentifier = "targetAccessibilityIdentifier"
    static let targetAccessibilityLabel = "targetAccessibilityLabel"
    /// NOT "viewHierarchy".
    static let hierarchy = "hierarchy"
    static let appVisibilityState = "appVisibilityState"

    // MARK: AppInstallUpgrade.json → data
    //
    // The schema has no string "version" fields: it carries a boolean and two
    // DOUBLES. `installType: "install"` had no column at all.

    static let isUpgrade = "isUpgrade"
    static let previousVersionCode = "previousVersionCode"
    static let currentVersionCode = "currentVersionCode"
    static let previousBuildType = "previousBuildType"
    static let currentBuildType = "currentBuildType"

    // MARK: SessionStart.json
    //
    // Session start has NO `data` field. It has `userAttributes` and
    // `sessionAttributes`, and each accepts a fixed set of names.

    /// SessionStart.userAttributes — exactly these, plus server-derived geo
    /// (country / region / city).
    enum SessionUserAttributes {
        static let deviceType = "deviceType"
        static let platform = "platform"
    }

    /// SessionEnd.data. Note the schema puts these under `data`, NOT under
    /// `sessionAttributes` the way SessionStart does — the two events are shaped
    /// differently and matching each one exactly is the only option.
    enum SessionEndData {
        static let sessionEndEventName = "sessionEndEventName"
        static let sessionDuration = "sessionDuration"
        static let sessionEventCount = "sessionEventCount"
    }

    /// LeaveScreen.data adds this to the ViewScreen field set.
    static let timeOnScreen = "timeOnScreen"

    /// SessionStart.sessionAttributes.
    enum SessionAttributes {
        static let source = "source"
        static let device = "device"
        static let iosVendorId = "iosVendorId"
        static let iosAdvertiserId = "iosAdvertiserId"
        static let appName = "appName"
        static let appIdentifier = "appIdentifier"
        static let appVersion = "appVersion"
        static let sessionStartEventName = "sessionStartEventName"
    }

    // MARK: Not in any iOS schema

    /// The APNs device-token attribute name, which is PER SOURCE.
    ///
    /// Mirrors the Android SDK exactly: `InstallOrUpgradeEvent.kt:45` builds
    /// `"fcm_token_" + config.sourceId`, because `AndroidSourceInitialization`
    /// renames the schema's placeholder `device_token` field to
    /// `fcm_token_<sourceId>`. The name has to be constructed client-side or it
    /// matches no column.
    ///
    /// A flat `pushToken` — which an earlier version sent — matches nothing at
    /// all, and `destinations-processor` finds the attribute by the
    /// `apns_token_` prefix.
    static func apnsToken(sourceId: String) -> String {
        "apns_token_\(sourceId)"
    }

    /// Push attribution. No iOS collection is provisioned for push events, so
    /// these names are ours until one exists.
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
