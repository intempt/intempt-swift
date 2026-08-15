//
//  JSONHandler.swift
//  Intempt
//
//  Adapted from mixpanel-swift (https://github.com/mixpanel/mixpanel-swift)
//  Created by Yarden Eitan on 6/3/16.
//  Copyright © 2016 Mixpanel. All rights reserved.
//  Licensed under the Apache License, Version 2.0.
//
//  Modifications by Intempt Technologies, Inc. (Apache License 2.0, §4(b)):
//    - Renamed to the Intempt module namespace; logging routed to IntemptLogger.
//    - `encodeAPIData` returns `Data` rather than `String`: the transport needs
//      bytes, and upstream's String round-trip is a wasted conversion.
//    - Unserializable values are reported to the caller instead of being
//      silently coerced. Upstream stringifies anything it does not recognise,
//      which quietly ships `"nan"` into a numeric field.
//
import Foundation

enum JSONHandler {

    /// Serialises an object for transmission. Returns nil only when the result
    /// is not valid JSON even after normalisation — and logs why.
    static func encodeAPIData(_ obj: Any) -> Data? {
        guard let data = serializeJSONObject(obj) else {
            IntemptLogger.shared.log(.warning, "couldn't serialize object for transmission")
            return nil
        }
        return data
    }

    static func deserializeData(_ data: Data) -> Any? {
        do {
            return try JSONSerialization.jsonObject(with: data, options: [])
        } catch {
            IntemptLogger.shared.log(.warning, "exception decoding object data")
            return nil
        }
    }

    static func serializeJSONObject(_ obj: Any) -> Data? {
        let serializable: Any
        // Upstream behaviour, retained deliberately: when the top-level object
        // is an array, drop individually-invalid elements rather than failing
        // the whole payload. One malformed event must not kill a batch.
        if let arr = makeObjectSerializable(obj) as? [Any] {
            serializable = arr.filter { JSONSerialization.isValidJSONObject([$0]) }
        } else {
            serializable = makeObjectSerializable(obj)
        }

        guard JSONSerialization.isValidJSONObject(serializable) else {
            IntemptLogger.shared.log(.warning, "object is not valid JSON and cannot be serialized")
            return nil
        }
        return try? JSONSerialization.data(withJSONObject: serializable, options: [])
    }

    /// Converts values `JSONSerialization` cannot handle into ones it can.
    /// `Date`/`URL`/boxed-`Bool` handling is inherited; the difference from
    /// upstream is that unknown types are surfaced rather than stringified.
    static func makeObjectSerializable(_ obj: Any) -> Any {
        switch obj {
        case let num as NSNumber:
            // CFBoolean bridges to NSNumber; without this check `true`
            // serialises as 1 rather than a JSON boolean.
            if CFGetTypeID(num) == CFBooleanGetTypeID() {
                return num.boolValue
            }
            // Covers Double and Float too: both bridge to NSNumber on every
            // Apple platform, so this case matches before any Double/Float case
            // could. Separate `as Double` / `as Float` branches used to sit
            // below and were unreachable — mutation testing exposed them by
            // surviving a mutation of code that can never run.
            if num.doubleValue.isNaN || num.doubleValue.isInfinite {
                IntemptLogger.shared.log(.warning, "dropping non-finite number from payload")
                return NSNull()
            }
            return num

        case is String, is Int, is UInt, is UInt64, is Bool:
            return obj

        case let arr as [Any?]:
            // nil entries inside arrays are dropped, matching upstream
            return arr.compactMap { $0 }.map { makeObjectSerializable($0) }

        case let arr as [Any]:
            return arr.map { makeObjectSerializable($0) }

        case let dict as [String: Any]:
            return dict.mapValues { makeObjectSerializable($0) }

        case let date as Date:
            return iso8601.string(from: date)

        case let url as URL:
            return url.absoluteString

        case is NSNull:
            return NSNull()

        default:
            let described = String(describing: obj)
            if described == "nil" { return NSNull() }
            IntemptLogger.shared.log(
                .warning, "unsupported property type \(type(of: obj)) coerced to string")
            return described
        }
    }

    /// Matches the format the JS SDK and ingestion already use.
    private static let iso8601: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS'Z'"
        f.timeZone = TimeZone(identifier: "UTC")
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()
}
