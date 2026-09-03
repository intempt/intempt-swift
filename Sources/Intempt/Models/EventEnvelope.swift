//
//  EventEnvelope.swift
//  Intempt
//
//  Copyright © 2026 Intempt Technologies, Inc.
//  Licensed under the Apache License, Version 2.0.
//
//  No mixpanel-swift equivalent — this is Intempt's wire shape, verified
//  field-for-field against intemptjs (autoTracker.types.ts:118-177) and the
//  ingestion contract (push-source-service DataRequest.java).
//
import Foundation

/// Fields carried by every model.
struct EventEnvelope: Equatable {
    let eventId: String
    let profileId: String
    let sessionId: String
    let pageId: String

    init(eventId: String, profileId: String, sessionId: String, pageId: String) {
        self.eventId = eventId
        self.profileId = profileId
        self.sessionId = sessionId
        self.pageId = pageId
    }

    /// `ev_`-prefixed, matching intemptjs's `generateId('ev')`. Ingestion
    /// generates one server-side when absent, but the client needs a stable
    /// id for local dedup across retries.
    static func generate(profileId: String, sessionId: String, pageId: String) -> EventEnvelope {
        EventEnvelope(
            eventId: EventConstants.eventIdPrefix + UUID().uuidString,
            profileId: profileId,
            sessionId: sessionId,
            pageId: pageId)
    }

    /// Merged into every payload dictionary.
    var fields: [String: Any] {
        [
            "eventId": eventId,
            "profileId": profileId,
            "sessionId": sessionId,
            "pageId": pageId,
        ]
    }
}

/// Every model serialises to one payload dictionary and declares the `type`
/// discriminator ingestion routes on.
protocol IntemptModel {
    /// `identify` · `group` · `record` · `track` · `product` ·
    /// `consent` — matches intemptjs's model `type` field exactly.
    ///
    /// Empty means "omit the field", which only `SessionModel` does: intemptjs's
    /// `SessionEventModel` carries no `type` at all.
    var type: String { get }
    /// Event title. intemptjs defaults several of these to "Identify".
    var name: String { get }
    func toPayload() -> [String: Any]

    /// Declared here, not only in the extension below, so that a conforming
    /// type can replace it and be honoured through an `IntemptModel`
    /// existential. A method that exists ONLY in a protocol extension is
    /// statically dispatched: `SessionModel`'s own version would be silently
    /// ignored everywhere the SDK holds models as `IntemptModel`, which is
    /// everywhere. Covered by a test.
    func toEnvelopeEntry() -> [String: Any]
}

extension IntemptModel {
    /// Wraps the model as one entry of the batched `{"track":[...]}` envelope.
    /// Shape verified at intemptjs autoTracker.module.ts:161-183 and against
    /// push-source-service's DataRequests/DataRequest parsing.
    func toEnvelopeEntry() -> [String: Any] {
        var entry: [String: Any] = [
            "name": name,
            "payload": [toPayload()],
        ]
        if !type.isEmpty { entry["type"] = type }
        return entry
    }
}

/// Ingestion rejects any payload item lacking all four of these
/// (`DataRequest.java` throws `IntemptException`). Validating client-side
/// turns a silent server-side drop into a caller-visible error.
enum PayloadValidator {
    static let identityKeys = ["userId", "profileId", "accountId", "productId"]

    static func validate(_ payload: [String: Any]) throws {
        let hasIdentity = identityKeys.contains { key in
            guard let value = payload[key] else { return false }
            if let s = value as? String { return !s.isEmpty }
            return true
        }
        guard hasIdentity else { throw IntemptError.missingIdentity }
    }
}
