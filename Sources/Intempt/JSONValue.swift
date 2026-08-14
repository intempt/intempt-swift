//
//  JSONValue.swift
//  Intempt
//
//  Copyright © 2026 Intempt Technologies, Inc.
//  Licensed under the Apache License, Version 2.0.
//
//  No mixpanel-swift equivalent.
//
//  Exists because `[String: Any]` cannot be `Sendable`. An experiment's
//  `changes` are arbitrary JSON authored in the web editor, so the SDK cannot
//  model them as a fixed struct without going stale the moment the editor gains
//  a field — but handing back `Any` means `ExperimentChoice` cannot cross a
//  concurrency boundary, and under the Swift 6 language mode declaring it
//  `Sendable` anyway is a hard error, not a warning.
//
import Foundation

/// A decoded JSON value. Sendable, so it can be handed to a caller on any
/// queue, while still representing a shape the SDK does not control.
public enum JSONValue: Equatable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    // MARK: Convenience accessors

    public var stringValue: String? {
        switch self {
        case .string(let s): return s
        case .number(let n): return Personalization.plain(NSNumber(value: n))
        case .bool(let b): return b ? "true" : "false"
        default: return nil
        }
    }

    public var doubleValue: Double? {
        switch self {
        case .number(let n): return n
        case .string(let s): return Double(s)
        default: return nil
        }
    }

    public var intValue: Int? { doubleValue.map(Int.init) }

    public var boolValue: Bool? {
        switch self {
        case .bool(let b): return b
        case .number(let n): return n != 0
        default: return nil
        }
    }

    public var objectValue: [String: JSONValue]? {
        if case .object(let o) = self { return o }
        return nil
    }

    public var arrayValue: [JSONValue]? {
        if case .array(let a) = self { return a }
        return nil
    }

    public var isNull: Bool { self == .null }

    /// Keyed access, so `choice.changes[0]["selector"]?.stringValue` reads
    /// naturally without unwrapping the object at every step.
    public subscript(key: String) -> JSONValue? { objectValue?[key] }
    public subscript(index: Int) -> JSONValue? {
        guard let array = arrayValue, array.indices.contains(index) else { return nil }
        return array[index]
    }

    // MARK: Bridging

    /// Converts a `JSONSerialization` output tree.
    ///
    /// Booleans are checked before numbers: `CFBoolean` bridges to `NSNumber`,
    /// so a plain `as? Double` cast turns `true` into `1` and loses the type.
    static func from(_ any: Any) -> JSONValue {
        switch any {
        case is NSNull:
            return .null
        case let n as NSNumber:
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return .bool(n.boolValue) }
            return .number(n.doubleValue)
        case let s as String:
            return .string(s)
        case let d as [String: Any]:
            return .object(d.mapValues { from($0) })
        case let a as [Any]:
            return .array(a.map { from($0) })
        case let b as Bool:
            return .bool(b)
        case let d as Double:
            return .number(d)
        case let i as Int:
            return .number(Double(i))
        default:
            return .string(String(describing: any))
        }
    }

    /// Back to a `JSONSerialization`-compatible tree.
    var rawValue: Any {
        switch self {
        case .string(let s): return s
        case .number(let n): return n
        case .bool(let b): return b
        case .object(let o): return o.mapValues { $0.rawValue }
        case .array(let a): return a.map { $0.rawValue }
        case .null: return NSNull()
        }
    }
}
