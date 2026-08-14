//
//  Models.swift
//  Intempt
//
//  Copyright © 2026 Intempt Technologies, Inc.
//  Licensed under the Apache License, Version 2.0.
//
//  The seven wire models. Every field verified against intemptjs:
//    IdentifyModelPayload  autoTracker.types.ts:118-127  identify.model.ts
//    GroupModelPayload     autoTracker.types.ts:129-137  group.model.ts
//    AliasModelPayload     autoTracker.types.ts:161-168  alias.model.ts
//    RecordModelPayload    autoTracker.types.ts:148-159  record.model.ts
//    TrackModelPayload     autoTracker.types.ts:139-146  track.model.ts
//    ProductModelPayload   autoTracker.types.ts:170-177
//    ConsentModel          consent.model.ts
//
//  Mixpanel has no equivalent: its People/Group are operator-based
//  ($set/$set_once/$union) while Intempt sends flat attribute dictionaries.
//
import Foundation

// MARK: - Track

/// Plain custom event. No user or account attributes.
struct TrackModel: IntemptModel {
    let envelope: EventEnvelope
    let name: String
    let data: [String: IntemptType]?

    var type: String { "track" }

    func toPayload() -> [String: Any] {
        var payload = envelope.fields
        if let data { payload["data"] = data }
        return payload
    }
}

// MARK: - Identify (Intempt's "user"; Mixpanel's "people")

struct IdentifyModel: IntemptModel {
    let envelope: EventEnvelope
    let name: String
    let userId: String
    let userAttributes: [String: IntemptType]?
    let data: [String: IntemptType]?

    var type: String { "identify" }

    func toPayload() -> [String: Any] {
        var payload = envelope.fields
        payload["userId"] = userId
        if let userAttributes { payload["userAttributes"] = userAttributes }
        if let data { payload["data"] = data }
        return payload
    }
}

// MARK: - Group (Intempt's "account"; Mixpanel's "group")

/// The old Obj-C SDK named this parameter `userAttributes` while carrying an
/// account concept (IntemptTracker.h:157) — a naming defect. It is
/// `accountAttributes` here, matching intemptjs and ingestion.
struct GroupModel: IntemptModel {
    let envelope: EventEnvelope
    let name: String
    let accountId: String
    let accountAttributes: [String: IntemptType]?

    var type: String { "group" }

    func toPayload() -> [String: Any] {
        var payload = envelope.fields
        payload["accountId"] = accountId
        if let accountAttributes { payload["accountAttributes"] = accountAttributes }
        return payload
    }
}

// MARK: - Alias

/// Deliberately thinner than every other model: no `sessionId`, no `pageId`.
/// intemptjs comments both out in AliasModelPayload; adding them would
/// diverge from the shape ingestion expects.
struct AliasModel: IntemptModel {
    let eventId: String
    let profileId: String
    let userId: String
    let anotherUserId: String

    var type: String { "alias" }
    /// intemptjs hardcodes "Identify" for alias events.
    var name: String { "Identify" }

    func toPayload() -> [String: Any] {
        [
            "eventId": eventId,
            "profileId": profileId,
            "userId": userId,
            "anotherUserId": anotherUserId,
        ]
    }
}

// MARK: - Record

/// Combined identify + group in one call. Everything past the envelope is
/// optional, so a caller can send user attributes, account attributes, or both.
struct RecordModel: IntemptModel {
    let envelope: EventEnvelope
    let name: String
    let userId: String?
    let accountId: String?
    let data: [String: IntemptType]?
    let userAttributes: [String: IntemptType]?
    let accountAttributes: [String: IntemptType]?

    var type: String { "record" }

    func toPayload() -> [String: Any] {
        var payload = envelope.fields
        if let userId { payload["userId"] = userId }
        if let accountId { payload["accountId"] = accountId }
        if let data { payload["data"] = data }
        if let userAttributes { payload["userAttributes"] = userAttributes }
        if let accountAttributes { payload["accountAttributes"] = accountAttributes }
        return payload
    }
}

// MARK: - Product

/// Fixed `data` shape — `{productId, quantity?}` — not a generic bag like
/// every other model's `data` field.
struct ProductModel: IntemptModel {
    let envelope: EventEnvelope
    let name: String
    let productId: String
    let quantity: Int?

    var type: String { "product" }

    func toPayload() -> [String: Any] {
        var inner: [String: Any] = ["productId": productId]
        if let quantity { inner["quantity"] = quantity }
        var payload = envelope.fields
        payload["data"] = inner
        return payload
    }
}

// MARK: - Session

/// Session start. Shaped to match intemptjs's `SessionEventModel`
/// (session.model.ts) exactly, and it is deliberately unlike every other model:
///
///   - **No `type` field.** `SessionEventModel` declares only `name` and
///     `payload`. Verified against production that a typeless entry is accepted
///     (201). Also verified that ingestion does not validate `type` at all — a
///     bogus value returns 201 too — so matching the shape the JS SDK has run in
///     production is the safer choice than inventing one that merely looks
///     tidier.
///   - **`eventId` IS the `sessionId`.** Not an `ev_`-prefixed UUID. This makes
///     the event naturally idempotent per session: a retry cannot create a
///     second session-start.
///   - **No `pageId`.**
///
/// Device facts travel in `userAttributes`, so they land on the profile rather
/// than being stamped onto every event the way Mixpanel does.
struct SessionModel: IntemptModel {
    let sessionId: String
    let profileId: String
    let name: String
    let data: [String: IntemptType]?
    let userAttributes: [String: IntemptType]?

    /// Empty on purpose — see the type note above. `toEnvelopeEntry()` omits
    /// the field entirely rather than sending `"type":""`.
    var type: String { "" }

    func toPayload() -> [String: Any] {
        var payload: [String: Any] = [
            "eventId": sessionId,
            "sessionId": sessionId,
            "profileId": profileId,
        ]
        if let data { payload["data"] = data }
        if let userAttributes { payload["userAttributes"] = userAttributes }
        return payload
    }
}

// MARK: - Consent

/// Binary accept/reject, at parity with intemptjs's `ConsentAction`
/// (intemptJs.types.ts:47). The eight-type audit taxonomy
/// (audit/EventTypes.java:282-290) is a tracked fast-follow needing a backend
/// endpoint that does not exist; neither existing SDK speaks it today.
public enum ConsentAction: String, CaseIterable, Sendable {
    case accept
    case reject
}

/// Sent to `/consents/data` — separate, unbatched and immediate. It does NOT
/// travel through the `/track` envelope.
struct ConsentModel {
    let action: ConsentAction
    let profileId: String
    let sourceId: String
    /// Platform identifier. intemptjs hardcodes "web"; native reports the
    /// actual platform.
    let source: String
    let validUntil: TimeInterval
    let email: String?
    let message: String?
    let category: String?

    func toPayload() -> [String: Any] {
        var payload: [String: Any] = [
            "action": action.rawValue,
            "profileId": profileId,
            "sourceId": sourceId,
            "source": source,
            "validUntil": validUntil,
        ]
        if let email { payload["email"] = email }
        if let message { payload["message"] = message }
        if let category { payload["category"] = category }
        return payload
    }
}

// MARK: - Batch envelope

enum TrackEnvelope {
    /// `{"track":[ {name,type,payload:[…]}, … ]}` — one request carries a
    /// MIXED batch: identify, group, alias, record, track and product all
    /// funnel through the same endpoint (verified at
    /// intemptjs autoTracker.module.ts:328-334, where every type except
    /// consent falls through to the batcher).
    static func wrap(_ entries: [[String: Any]]) -> [String: Any] {
        ["track": entries]
    }

    static func wrap(models: [IntemptModel]) -> [String: Any] {
        wrap(models.map { $0.toEnvelopeEntry() })
    }
}
