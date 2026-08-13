//
//  IntemptType.swift
//  Intempt
//
//  Adapted from mixpanel-swift's MixpanelType.swift
//  (https://github.com/mixpanel/mixpanel-swift)
//  Created by Yarden Eitan on 8/19/16.
//  Copyright © 2016 Mixpanel. All rights reserved.
//  Licensed under the Apache License, Version 2.0.
//
//  Modifications by Intempt Technologies, Inc. (Apache License 2.0, §4(b)):
//    - Renamed to the Intempt module namespace.
//    - Dropped upstream's `equals(rhs:)` requirement: it exists to support
//      `registerSuperPropertiesOnce`, and Intempt does not ship super
//      properties. Removing it keeps the protocol to one job.
//    - Array/Dictionary validation is RECURSIVE. Upstream checks only that
//      each element casts to the protocol (one level deep), so a NaN nested
//      two levels down passes upstream and fails here. This is deliberate:
//      an invalid leaf must poison the whole payload before it reaches the
//      wire, not after the server rejects it.
//
import Foundation

/// Property keys must be `String`. Values must conform to `IntemptType`:
/// `String`, `Int`, `UInt`, `Double`, `Float`, `Bool`, `Date`, `URL`,
/// `NSNull`, `[IntemptType]`, or `[String: IntemptType]`.
/// Numbers must be finite — NaN and infinity are rejected.
public protocol IntemptType: Any {
    /// True when this value, and everything nested inside it, is a type and
    /// value Intempt can transmit.
    func isValidNestedTypeAndValue() -> Bool
}

extension String: IntemptType {
    public func isValidNestedTypeAndValue() -> Bool { true }
}

extension NSString: IntemptType {
    public func isValidNestedTypeAndValue() -> Bool { true }
}

extension Int: IntemptType {
    public func isValidNestedTypeAndValue() -> Bool { true }
}

extension UInt: IntemptType {
    public func isValidNestedTypeAndValue() -> Bool { true }
}

extension Bool: IntemptType {
    public func isValidNestedTypeAndValue() -> Bool { true }
}

extension Date: IntemptType {
    public func isValidNestedTypeAndValue() -> Bool { true }
}

extension URL: IntemptType {
    public func isValidNestedTypeAndValue() -> Bool { true }
}

extension NSNull: IntemptType {
    public func isValidNestedTypeAndValue() -> Bool { true }
}

extension Double: IntemptType {
    public func isValidNestedTypeAndValue() -> Bool { isFinite && !isNaN }
}

extension Float: IntemptType {
    public func isValidNestedTypeAndValue() -> Bool { isFinite && !isNaN }
}

extension NSNumber: IntemptType {
    public func isValidNestedTypeAndValue() -> Bool {
        !doubleValue.isInfinite && !doubleValue.isNaN
    }
}

// Unconstrained conformance with a runtime cast, matching upstream. A
// constrained form (`where Element: IntemptType`) does not compile, because
// the existential `IntemptType` cannot satisfy its own generic requirement —
// and `[String: IntemptType]` is exactly the type every model uses.
extension Array: IntemptType {
    public func isValidNestedTypeAndValue() -> Bool {
        allSatisfy { ($0 as? IntemptType)?.isValidNestedTypeAndValue() ?? false }
    }
}

extension NSArray: IntemptType {
    public func isValidNestedTypeAndValue() -> Bool {
        allSatisfy { ($0 as? IntemptType)?.isValidNestedTypeAndValue() ?? false }
    }
}

extension Dictionary: IntemptType {
    public func isValidNestedTypeAndValue() -> Bool {
        for (key, value) in self {
            guard key as? String != nil,
                let typed = value as? IntemptType,
                typed.isValidNestedTypeAndValue()
            else { return false }
        }
        return true
    }
}
