//
//  Push.swift
//  Intempt
//
//  Copyright © 2026 Intempt Technologies, Inc.
//  Licensed under the Apache License, Version 2.0.
//
//  No mixpanel-swift equivalent worth inheriting: upstream's push handling is
//  entangled with its own notification product.
//
//  APNs ONLY. There is no Firebase or FCM dependency at any layer of this SDK,
//  and none may be added. `setPushToken` takes the raw `Data` that
//  `application(_:didRegisterForRemoteNotificationsWithDeviceToken:)` hands
//  you — nothing else.
//
//  ── KNOWN BACKEND GAP ───────────────────────────────────────────────────────
//  The iOS source schema has no field for a device token. The Android source
//  initialisation injects one — `AndroidSourceInitialization.java:85-91` builds
//  its App Install/Upgrade collection with an `fcm_token_<sourceId>` field —
//  but `IosSourceInitialization.java:38-46` provisions its AppInstallUpgrade
//  collection with the plain builder and no token field at all.
//
//  So the token is sent as a profile `userAttribute` named `pushToken`, which
//  is the only place it can currently land. Making the iOS token a first-class
//  schema field, and wiring `destinations-processor` (which still carries a
//  `//todo: implement for ios`), is a backend change this SDK cannot make.
//  Until then treat delivery of the token as unverified: it is sent, and
//  whether it is retained is not something the client can observe.
//  ────────────────────────────────────────────────────────────────────────────
//
import Foundation

/// Formats and reports APNs tokens and push interactions.
enum Push {

    /// Lowercase hex, which is the form APNs itself and every push provider
    /// expects.
    ///
    /// The historically common implementation —
    /// `token.description.trimmingCharacters(in: CharacterSet(charactersIn: "<>"))`
    /// — has been broken since iOS 13: `Data.description` changed from
    /// `<a1b2 c3d4>` to `32 bytes`, so apps that shipped it silently registered
    /// the literal string "32 bytes" as their device token and every push
    /// stopped arriving. Formatting each byte is the only correct way.
    static func hexString(from token: Data) -> String {
        token.map { String(format: "%02x", $0) }.joined()
    }

    /// A valid APNs token is 32 bytes, or 100+ for some newer formats. Anything
    /// tiny is a caller mistake — usually a string that was UTF-8 encoded
    /// instead of the raw `Data` from the registration callback.
    static func isPlausible(_ token: Data) -> Bool {
        token.count >= 32
    }

    /// Extracts what is safe to report from an APNs payload.
    ///
    /// The notification BODY is never read. It is content written for that one
    /// user and frequently contains their own data — "Your test results are
    /// ready", a message preview, an order total. Only the campaign identifier
    /// the sender attached, so a send can be attributed without copying its
    /// contents into analytics.
    static func attribution(from userInfo: [AnyHashable: Any]) -> [String: IntemptType] {
        var properties: [String: IntemptType] = [:]

        // Intempt's own identifiers, checked in order of specificity.
        for key in ["intempt_campaign_id", "campaignId", "campaign_id"] {
            if let value = userInfo[key] as? String, !value.isEmpty {
                properties[EventKeys.campaignId] = value
                break
            }
        }

        // A developer-authored title is campaign copy, not user content, so it
        // is useful for reporting. The body is not read at all.
        if let aps = userInfo["aps"] as? [String: Any],
            let alert = aps["alert"] as? [String: Any],
            let title = alert["title"] as? String,
            !title.isEmpty
        {
            properties[EventKeys.notificationTitle] = title
        }

        return properties
    }
}
