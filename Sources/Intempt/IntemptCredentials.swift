//
//  IntemptCredentials.swift
//  Intempt
//
//  Copyright © 2026 Intempt Technologies, Inc.
//  Licensed under the Apache License, Version 2.0.
//
//  No mixpanel-swift equivalent: Mixpanel authenticates with a flat project
//  token. Intempt issues `prefix.secret` keys (auth/ApiKeyService.java:389-392,
//  ApiKeyEntity.java:41) presented as HTTP Basic, matching intemptjs
//  (autoTracker.module.ts:177-179).
//
import Foundation

/// Parsed API key. The wire form is literally `prefix.secret`; the prefix is
/// the lookup key server-side and the secret is hashed for comparison.
struct IntemptCredentials: Equatable {
    let prefix: String
    let secret: String

    /// Splits on the FIRST dot only — a secret may itself contain dots, and
    /// truncating it would authenticate with a partial credential.
    ///
    /// Throws rather than crashing. The old Obj-C SDK called
    /// `objectAtIndex:1` unguarded, so any key without a dot raised
    /// NSRangeException and took the host app down (audit finding F-02).
    init(apiKey: String) throws {
        let parts = apiKey.split(
            separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2,
            !parts[0].isEmpty,
            !parts[1].isEmpty
        else {
            // Length only — never key material. An Error carrying the raw key
            // ends up in integrator logs and crash reporters.
            throw IntemptError.malformedAPIKey(length: apiKey.count)
        }
        prefix = String(parts[0])
        secret = String(parts[1])
    }

    /// `Authorization: Basic base64(prefix:secret)`.
    var basicAuthHeader: String {
        let raw = "\(prefix):\(secret)"
        return "Basic " + Data(raw.utf8).base64EncodedString()
    }
}

// Redacted on purpose: `String(describing:)`, `dump()` and Mirror-based
// logging would otherwise print the secret in plaintext.
extension IntemptCredentials: CustomStringConvertible, CustomDebugStringConvertible {
    var description: String {
        "IntemptCredentials(prefix: \(prefix), secret: <redacted>)"
    }
    var debugDescription: String { description }
}

// CustomStringConvertible alone is NOT enough: `dump()` and any Mirror-based
// logger walk stored properties directly and would print the secret. A test
// caught this. Supplying a custom Mirror closes the reflection path too.
extension IntemptCredentials: CustomReflectable {
    var customMirror: Mirror {
        Mirror(
            self,
            children: ["prefix": prefix, "secret": "<redacted>"],
            displayStyle: .struct)
    }
}
