import Foundation

/// What `allFlags` returns: every flag served to this person, key to value.
///
/// `/flags/all` records no exposure (F32 hybrid exposure): counting the prefetch would mark every
/// screen load as exposed and dilute the experiment. Instead the FIRST read of each served key
/// through `subscript` or `dictionary` sends `/flags/expose` once for this map. `keys`, `count`
/// and `isEmpty` read nothing and expose nothing. A reference type because the exposure is state
/// the map carries; a plain dictionary cannot notice being read.
///
/// A bridge that must copy the values out (React Native cannot hand JS a map that notices being
/// read) uses `snapshot()` or `peek(_:)`, which record NO exposure, and then calls `expose(_:)`
/// for each key it actually uses. Skipping `expose(_:)` loses those exposures for good.
public final class FlagValues: @unchecked Sendable {

    static let empty = FlagValues(values: [:], served: [:]) { _, _ in }

    private let values: [String: JSONValue]
    private let lock = NSLock()
    private var unexposed: [String: Int]
    private let send: (String, Int) -> Void

    init(
        values: [String: JSONValue],
        served: [String: Int],
        expose: @escaping (_ key: String, _ variationId: Int) -> Void
    ) {
        self.values = values
        self.unexposed = served
        self.send = expose
    }

    public var keys: [String] { Array(values.keys) }
    public var count: Int { values.count }
    public var isEmpty: Bool { values.isEmpty }

    /// The served value, or nil when nothing was served. Reports the exposure on first read.
    public subscript(key: String) -> JSONValue? {
        report(key)
        return values[key]
    }

    /// Every value at once. Exposes EVERY served key, as reading each one would: use it only
    /// where every value is shown.
    public var dictionary: [String: JSONValue] {
        values.keys.forEach(report)
        return values
    }

    /// The served value WITHOUT recording an exposure. Call `expose(_:)` for the key if the value
    /// is used, or the exposure is never recorded.
    public func peek(_ key: String) -> JSONValue? {
        values[key]
    }

    /// Every served value WITHOUT recording any exposure. Call `expose(_:)` for each key whose
    /// value is used, or those exposures are never recorded.
    public func snapshot() -> [String: JSONValue] {
        values
    }

    /// Records the exposure of a served key, as its first read would: once per map, shared with
    /// `subscript` and `dictionary`, so a key already read sends nothing. A key served without a
    /// variation, or not served at all, sends nothing.
    public func expose(_ key: String) {
        report(key)
    }

    private func report(_ key: String) {
        lock.lock()
        let variationId = unexposed.removeValue(forKey: key)
        lock.unlock()
        if let variationId { send(key, variationId) }
    }
}
