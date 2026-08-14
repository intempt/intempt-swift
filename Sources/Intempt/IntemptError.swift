//
//  IntemptError.swift
//  Intempt
//
//  Adapted from mixpanel-swift's Error.swift
//  (https://github.com/mixpanel/mixpanel-swift)
//  Created by Yarden Eitan on 6/10/16.
//  Copyright © 2016 Mixpanel. All rights reserved.
//  Licensed under the Apache License, Version 2.0.
//
//  Modifications by Intempt Technologies, Inc. (Apache License 2.0, §4(b)):
//    - Replaced upstream's single `PropertyError` with a public, exhaustive
//      error enum. Upstream reports most failures via Bool returns and logs,
//      so integrators cannot distinguish a bad credential from a network
//      fault; every failure mode here is nameable and matchable.
//    - Dropped upstream's `MPAssert`/`Assertions` indirection and the
//      `ErrorHandler.wrap` catch-and-swallow helper: silently converting a
//      thrown error to nil is how failures become invisible.
//
import Foundation

/// Every way an Intempt SDK call can fail. Public and exhaustive so callers
/// can branch on cause rather than parse a log line.
public enum IntemptError: Error, Equatable {

    // MARK: Credentials

    /// The API key was not in `prefix.secret` form. Carries only a length
    /// hint — never key material, which would leak into crash reports.
    case malformedAPIKey(length: Int)

    /// A required identifier was empty at initialize time.
    case missingConfiguration(field: String)

    // MARK: Payload

    /// A property value was not an `IntemptType`, or was NaN/infinite.
    case invalidPropertyValue(key: String)

    /// Ingestion requires at least one of userId / profileId / accountId /
    /// productId on every payload item.
    case missingIdentity

    /// The payload could not be encoded as JSON.
    case encodingFailed

    // MARK: Transport

    /// Server responded with a status that will not succeed on retry
    /// (401, 403, 402, 4xx other than 408/429).
    case terminal(status: Int)

    /// Server responded with a status worth retrying (408, 429, 5xx).
    case retryable(status: Int, retryAfter: TimeInterval?)

    /// Transport-level failure — no HTTP response at all.
    case transport(description: String)

    // MARK: Storage

    /// The local event store could not be opened or written.
    case storageUnavailable(reason: String)

    /// Server rejected the request and said why. Carries the server's own
    /// wording so an integrator sees "Invalid feed id: nonexistent" rather
    /// than a bare 400.
    case server(status: Int, messages: [String])
}

extension IntemptError {
    /// Every Intempt endpoint reports failures as
    /// `{"errors":[{"message":"…"}]}` (verified across /track, /consents/data,
    /// /optimization/choose-api and /feeds/{id}/data — docs/CONTRACT.md).
    /// Returns nil when the body is not in that shape, so a caller can fall
    /// back to the bare status rather than invent a message.
    static func serverMessages(from data: Data?) -> [String]? {
        guard let data,
            let json = JSONHandler.deserializeData(data) as? [String: Any],
            let errors = json["errors"] as? [[String: Any]]
        else { return nil }

        let messages = errors.compactMap { $0["message"] as? String }.filter { !$0.isEmpty }
        return messages.isEmpty ? nil : messages
    }
}

extension IntemptError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .malformedAPIKey(let length):
            return "API key must be in prefix.secret form (received \(length) characters)"
        case .missingConfiguration(let field):
            return "missing required configuration: \(field)"
        case .invalidPropertyValue(let key):
            return "property '\(key)' is not a supported type or is a non-finite number"
        case .missingIdentity:
            return "payload requires one of userId, profileId, accountId or productId"
        case .encodingFailed:
            return "payload could not be encoded as JSON"
        case .terminal(let status):
            return "request failed permanently with status \(status)"
        case .retryable(let status, let after):
            let suffix = after.map { ", retry after \($0)s" } ?? ""
            return "request failed with status \(status), retryable\(suffix)"
        case .transport(let description):
            return "transport failure: \(description)"
        case .storageUnavailable(let reason):
            return "local event store unavailable: \(reason)"
        case .server(let status, let messages):
            return "server rejected request (\(status)): \(messages.joined(separator: "; "))"
        }
    }
}
